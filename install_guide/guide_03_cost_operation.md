# ガイド03: コスト運用(停止/起動と予算アラート)

COA はアイドルでも約 $0.44/時(約 $10.6/日、VPC エンドポイント+NAT)かかります。
「使うときだけ起動する」運用と、異常検知の予算アラートをここで確立します。

前提の変数(各ターミナルで):

```bash
export COA_REGION=us-west-2        # 東京の場合: ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## ステップ1: 停止と起動のスクリプト

このリポジトリの2つのスクリプトが、Neptune クラスタと ECS サービス(desired-count)を一括制御します。
リージョンは環境変数 `COA_REGION` に従います(未設定時は us-west-2)。

```bash
# 作業終了時(毎回の習慣にする)
bash scripts/ops/stop-coa.sh

# 作業再開時(Neptune が available になるまで5〜10分)
bash scripts/ops/start-coa.sh

# 起動状態の確認
aws neptune describe-db-clusters --db-cluster-identifier coa-dev-neptune \
  --region $COA_REGION --query 'DBClusters[0].Status' --output text
```

`available` と表示されれば起動完了です(停止中は `stopped`)。

### 停止運用の3つの注意点

1. **Neptune は停止から7日後に AWS の仕様で自動再開されます**。長期間使わない場合は
   週1回 `stop-coa.sh` を再実行するか、フル削除してください。
2. **取り込み・スキャン・namespace 削除などのパイプライン操作は、停止中は必ず失敗します**
   ([トラブル12](guide_07_troubleshooting.md))。ナレッジ操作の前に `start-coa.sh` を実行してください。
3. **1週間以上使わないならフル削除の方が安い**です(アイドルでも約 $75/週)。
   再デプロイは約62分で完了することを実証済みです。削除は COA リポジトリの公式ターゲット
   `make destroy-dev` を使います(※本ガイドの検証ではフル削除は未実施です。
   実行後は CloudFormation コンソールで、メインリージョンと us-east-1 の
   `coa-dev-edge-waf` を含む全スタックが消えたことを確認してください)。

## ステップ2: 予算アラートの作成

暴走級の異常(消し忘れの多重デプロイ、想定外の従量課金)を検知するため、
**アカウント全体の日次予算を1本**作成します。

しきい値は「アカウントの通常日額の3〜4倍」を推奨します。まず通常日額を把握します:

```bash
# 直近7日の日次コスト(Cost Explorer は UTC 日付・数時間の集計遅延あり)
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '7 days ago' +%F),End=$(date -u +%F) \
  --granularity DAILY --metrics UnblendedCost --region us-east-1 \
  --query 'ResultsByTime[].{date:TimePeriod.Start,usd:Total.UnblendedCost.Amount}' --output table
```

しきい値と通知先を決めて作成します:

```bash
export BUDGET_DAILY_USD=【しきい値(ドル/日)。例: 通常日額の3〜4倍】
export BUDGET_EMAIL=【通知を受け取るメールアドレス】

cat > /tmp/budget.json <<EOF
{
  "BudgetName": "coa-daily",
  "BudgetLimit": {"Amount": "$BUDGET_DAILY_USD", "Unit": "USD"},
  "TimeUnit": "DAILY",
  "BudgetType": "COST"
}
EOF
cat > /tmp/budget-notify.json <<EOF
[{
  "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                   "Threshold": 100, "ThresholdType": "PERCENTAGE"},
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "$BUDGET_EMAIL"}]
}]
EOF
aws budgets create-budget --account-id $ACCOUNT_ID \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/budget-notify.json
```

出力なしが成功です。**登録メールに AWS Budgets から確認メールが届くので、リンクを承認**
してください(承認しないと通知されません)。

### この方式の限界と補完(運用上の重要事項)

- アカウント全体予算のため、**COA の停止忘れ(+$35/日程度)はしきい値に届かず検知されません**。
  停止忘れの防止は「セッション終了時に `stop-coa.sh`」の習慣と、Cost Explorer の定期目視で担保します。
- COA だけを対象にしたタグフィルタ予算は、AWS Organizations の**メンバーアカウントでは
  コスト配分タグを有効化できず作成不可**です(管理アカウント側の操作が必要)。
  本ガイドではシンプルさを優先し、アカウント全体1本のみの運用としています。

## ステップ3: 予算の変更・通知先の追加(必要時)

```bash
# しきい値の変更(通知・宛先は引き継がれる)
export BUDGET_DAILY_USD=【新しいしきい値】
cat > /tmp/budget.json <<EOF
{
  "BudgetName": "coa-daily",
  "BudgetLimit": {"Amount": "$BUDGET_DAILY_USD", "Unit": "USD"},
  "TimeUnit": "DAILY",
  "BudgetType": "COST"
}
EOF
aws budgets update-budget --account-id $ACCOUNT_ID --new-budget file:///tmp/budget.json

# 反映確認
aws budgets describe-budget --account-id $ACCOUNT_ID --budget-name coa-daily \
  --query 'Budget.BudgetLimit'

# 通知先の確認
aws budgets describe-subscribers-for-notification \
  --account-id $ACCOUNT_ID --budget-name coa-daily \
  --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE

# 通知先の追加
aws budgets create-subscriber \
  --account-id $ACCOUNT_ID --budget-name coa-daily \
  --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE \
  --subscriber SubscriptionType=EMAIL,Address=【追加したいメールアドレス】
```

多人数配信や Slack 連携が必要になったら、EMAIL ではなく SNS トピックを Subscriber に
指定する方式へ切り替えてください。

## 参考: コスト実測値(オレゴン、db.r6g.large 構成)

| 項目 | 実測 |
|---|---|
| フル稼働 | 約 $1.9/時(約 $45/日) |
| 停止運用時 | 約 $0.44/時(約 $10.6/日) |
| アイドルの内訳 | VPC エンドポイント約40本 + NAT が大半。OpenSearch(min_ocu=0)と停止中 Neptune はほぼゼロ |
| 特定サービスの日次確認 | `aws ce get-cost-and-usage --time-period Start=【日付】,End=【翌日】 --granularity DAILY --metrics UnblendedCost --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Virtual Private Cloud"]}}' --region us-east-1` |

次: [ガイド04: ナレッジ構築](guide_04_knowledge_onboarding.md)
