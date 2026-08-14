# コスト監視(予算アラート)運用手順

最終更新: 2026-08-14

## 現在の構成

| 予算名 | 監視範囲 | しきい値 | 状態 | 役割 |
|---|---|---|---|---|
| `coa-daily` | **アカウント全体** | **$100/日** | 稼働中 | 暴走級の異常の検知 |

- 通知条件: 実績コスト(ACTUAL)がしきい値の100%超過
- 宛先: nagakura.makoto@jp.panasonic.com(差出人は AWS Budgets の no-reply)

### この構成になった経緯(運用決定: 2026-08-14)

1. 当初はアカウント全体 $5/日 で作成 → **COA と無関係な既存ワークロード(約$15/日)だけで毎日発火**する設計ミスと判明。
2. タグフィルタ付き予算も検討したが、本アカウントは AWS Organizations の
   **メンバーアカウントのためコスト配分タグの有効化ができない**
   (`AccessDeniedException: Linked account doesn't have access to cost allocation tags`)。
3. **決定**: 予算はアカウント全体 $100/日(通常時 約$26/日 の約4倍)の1本のみで運用する。
   この設定では COA の停止忘れ(約$45/日)は予算アラートでは検知されないため、
   停止忘れの防止は**セッション終了時の `scripts/ops/stop-coa.sh` 実行の習慣**と
   **Cost Explorer の定期目視**で担保する。

## しきい値の変更手順

`update-budget` を使う(通知・宛先設定はそのまま引き継がれる)。
`"Amount"` の数字を変更したい金額(ドル/日)に書き換えて実行:

```bash
cat > /tmp/budget.json <<'EOF'
{
  "BudgetName": "coa-daily",
  "BudgetLimit": {"Amount": "100", "Unit": "USD"},
  "TimeUnit": "DAILY",
  "BudgetType": "COST"
}
EOF
aws budgets update-budget --account-id 290918126236 --new-budget file:///tmp/budget.json
```

出力なしが成功。反映確認:

```bash
aws budgets describe-budget --account-id 290918126236 --budget-name coa-daily \
  --query 'Budget.BudgetLimit'
```

## 宛先の確認・追加手順

確認:

```bash
aws budgets describe-subscribers-for-notification \
  --account-id 290918126236 --budget-name coa-daily \
  --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE
```

宛先を追加(例として追加したいメールアドレスを Address に指定):

```bash
aws budgets create-subscriber \
  --account-id 290918126236 --budget-name coa-daily \
  --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE \
  --subscriber SubscriptionType=EMAIL,Address=追加したいアドレス
```

多人数への配信や Slack 連携が必要になったら、EMAIL ではなく SNS トピックを
Subscriber に指定する方式へ切り替える。

## 参考: コスト実測の確認コマンド

```bash
# 特定サービスの日次コスト(例: VPC)。Cost Explorer は UTC 日付・数時間の集計遅延あり
aws ce get-cost-and-usage \
  --time-period Start=2026-08-13,End=2026-08-14 \
  --granularity DAILY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Virtual Private Cloud"]}}' \
  --region us-east-1 \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text
```

実測の基準値(2026-08-13 確定):
- 既存ワークロード(COA 以外): 約 $15/日
- COA アイドル(停止状態): 約 $10.6/日($0.44/時)
- COA フル稼働: 約 $1.9/時(丸一日で約 $45/日)
