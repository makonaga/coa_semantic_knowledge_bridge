# コスト監視(予算アラート)運用手順

最終更新: 2026-08-14

## 現在の構成(2層設計)

| 層 | 予算名 | 監視範囲 | しきい値 | 状態 | 役割 |
|---|---|---|---|---|---|
| 1 | `coa-daily` | **アカウント全体** | **$100/日** | 稼働中 | 暴走級の異常の最終防衛線 |
| 2 | `coa-tagged-daily`(予定) | `Project=semantic-context` タグ限定 | $15/日 | **管理者対応待ち** | COA の停止忘れ検知(本命) |

- 通知条件: 実績コスト(ACTUAL)がしきい値の100%超過
- 宛先: nagakura.makoto@jp.panasonic.com(差出人は AWS Budgets の no-reply)

### この構成になった経緯

1. 当初はアカウント全体 $5/日 で作成 → **COA と無関係な既存ワークロード(約$15/日)だけで毎日発火**する設計ミスと判明。
2. タグフィルタ付き予算に変更しようとしたが、本アカウントは AWS Organizations の
   **メンバーアカウントのためコスト配分タグの有効化ができない**
   (`AccessDeniedException: Linked account doesn't have access to cost allocation tags`)。
   有効化は Organization 管理アカウントでのみ可能。
3. 暫定として全体監視のしきい値を $100/日(通常時 約$26/日 の約4倍)に引き上げ。
   **注意: この設定では COA の停止忘れ(約$45/日)は検知されない。**
   停止忘れの検知は、タグ有効化後の第2層予算と、セッション終了時の `stop-coa.sh` 習慣で担保する。

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

## 第2層(タグ限定予算)の有効化手順 — 管理者対応後に実施

### 前提: 社内 AWS 管理者への依頼(依頼文)

> アカウント 290918126236 で使用しているリソースタグ **`Project`** を、Organization
> 管理アカウントの Billing コンソール(「請求とコスト管理」→「コスト配分タグ」)で
> **コスト配分タグとして有効化**してください。目的は、タグ値 `semantic-context` が付いた
> 検証環境(Context Ontology Accelerator)のコストだけを AWS Budgets で監視するためです。
> 有効化による課金や既存環境への影響はありません。

### 有効化から24時間以降に実行

```bash
cat > /tmp/budget-tagged.json <<'EOF'
{
  "BudgetName": "coa-tagged-daily",
  "BudgetLimit": {"Amount": "15", "Unit": "USD"},
  "TimeUnit": "DAILY",
  "BudgetType": "COST",
  "CostFilters": {"TagKeyValue": ["user:Project$semantic-context"]}
}
EOF
cat > /tmp/budget-notify.json <<'EOF'
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [
      {"SubscriptionType": "EMAIL", "Address": "nagakura.makoto@jp.panasonic.com"}
    ]
  }
]
EOF
aws budgets create-budget --account-id 290918126236 \
  --budget file:///tmp/budget-tagged.json \
  --notifications-with-subscribers file:///tmp/budget-notify.json
```

しきい値 $15/日 の根拠: COA アイドル実測 $10.6/日 では鳴らず、
丸一日フル稼働($45/日)や停止忘れの時だけ鳴る。

- タグ有効化は**有効化後に発生したコストにのみ**適用される(過去分は集計されない)。
- 第2層が稼働したら、第1層 `coa-daily` は $100/日 のまま最終防衛線として残す。

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
