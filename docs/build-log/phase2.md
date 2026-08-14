# COA セルフホスト構築記録: Phase 2(CDK デプロイ)

実施日: 2026-08-12
結果: **成功** — 全16スタック CREATE_COMPLETE、Web UI ログインまで確認済み
デプロイ所要時間: 62分(cdk deploy 実測 3691秒)+ トラブル対応

---

## 構築されたシステム(主要な値の記録)

| 項目 | 値 |
|---|---|
| Web UI | https://dd7zlztjwxgl1.cloudfront.net(CloudFront: E2YSCY4FL36M78)|
| VPC | vpc-0be3741bc929ba776(10.0.0.0/16、us-west-2)|
| Cognito ユーザープール | us-west-2_JE9iaY4pA |
| ログインユーザー | nagakura.makoto@jp.panasonic.com(Cognito グループ `Admin` = platform-admin ロール)|
| Bedrock ガードレール | fhtyc0s0x50u(生成用)/ yl7b6t3mkttn(検索用)|
| Neptune | `coa-dev-neptune`、**db.t4g.medium(縮小パッチ適用済み、$0.065/時)** |
| スタック | us-west-2 に15個 + us-east-1 に coa-dev-edge-waf(CloudFront 用 WAF)|
| ソースデータ用 S3 | coa-dev-sources-data-290918126236 |

適用した設定(`infra/cdk.json` context):
`env=dev` / `smus_admin_principal_arns=arn:aws:iam::290918126236:user/nagakura.makoto` /
`aoss_min_ocu=0` / `aoss_max_ocu=16`

ローカルパッチ(タグ更新時に再適用が必要):
- `infra/lib/stacks/foundation/storage-stack.ts:118` — `db.r8g.large` → `db.t4g.medium`

既知の状態(問題なし):
- Cognito に初期ダミー管理者 `nobody@amazon.com` が自動作成されている(COA の仕様。
  メール受信不能なためログイン不可であり実害なし。CloudFormation 管理下のため削除しない)。
- 初回に作成した `nagakura54@gmail.com` ユーザーは削除済み(会社アドレスに変更)。

## 実施手順(最終形)

```bash
# 2-1. cdk.json context 設定(python で JSON マージ)
# 2-2. Neptune 縮小可否確認 → db.t4g.medium が us-west-2/engine 1.4.7.0 で提供されていることを
#      describe-orderable-db-instance-options で確認してから sed パッチ
# 2-3. デプロイ
cd ~/Desktop/work/context-ontology-accelerator
export AWS_REGION=us-west-2
export AWS_DEFAULT_REGION=us-west-2
make deploy-dev
# 2-4. Cognito ユーザー作成 + Admin グループ追加(admin-create-user / admin-add-user-to-group)
# 2-5. 予算アラート(aws budgets create-budget、$5/日)
# 2-6. 作業終了時 scripts/ops/stop-coa.sh
```

---

## トラブルシューティング(Phase 2 で発生した2件+無害な警告1件)

### トラブル5: preflight が VPC 上限で失敗

**症状**:
```
ERROR: VPC limit reached: 5/5 VPCs in us-west-2.
PREFLIGHT FAILED: 2 error(s) found.
```

**原因**: us-west-2 の VPC クォータ(既定5)に到達済み。COA は専用 VPC を1つ新規作成する。

**対処**: Service Quotas で引き上げ申請(削除より安全)。
```bash
aws service-quotas request-service-quota-increase \
  --service-code vpc --quota-code L-F678F1CE \
  --desired-value 10 --region us-west-2
```
**実測: 申請から数分で自動承認**(PENDING → 実効値 10.0)。`get-service-quota` で
実効値を確認してから再デプロイ。

### トラブル6: vkg イメージのビルドが `exec format error` で失敗

**症状**:
```
#8 0.187 exec /bin/sh: exec format error
coa-dev-vkg: fail: docker build ... --platform linux/arm64 . exited with error code 1
```
(guardrail / network の2スタック作成後に停止)

**原因**: COA のコンテナイメージは **ARM64(Graviton)用**。x86_64 の Linux ホストでは
QEMU による ARM64 エミュレーションを Docker に登録しないとビルドできない。
macOS の Docker Desktop は標準内蔵のため、**参考記事(macOS)では出ない Linux 固有のハマり**。

**対処**(1回だけの設定):
```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
# 確認(aarch64 と出ればOK)
docker run --rm --platform linux/arm64 public.ecr.aws/amazonlinux/amazonlinux:2023 uname -m
```
その後 `make deploy-dev` を再実行すると**作成済みスタックはスキップされ続きから進む**。

**備考**: エミュレーション下の ARM64 ビルドは遅い(yum/pip を含む vkg イメージで10〜30分)。
止まって見えても待つこと。

### 無害な警告: CDK バンドル中の pip 依存関係エラー

**症状**: `ERROR: pip's dependency resolver ...`(streamlit / mlflow / protobuf 等の
バージョン競合)が Lambda アセットのバンドル中に大量表示される。

**判定**: **無害**。ローカルの Anaconda 環境の site-packages に対する競合報告であり、
アセットのバンドル自体は成功している(デプロイは正常完了)。

---

## コスト状態(Phase 2 完了時点)

- フル稼働: 約 **$1.9/時**(Neptune 縮小により標準構成の $2.2/時から低減)
- `scripts/ops/stop-coa.sh` 実行後のアイドル: 約 **$0.45/時**(VPC エンドポイント40本+NAT)
- 運用ルール: セッション終了時に必ず stop。1週間以上使わないならフル削除(再デプロイ62分で戻せることを実証済み)。

### アイドルコスト実測(2026-08-13、停止状態の丸一日)

| 項目 | 値 |
|---|---|
| VPC サービス日額(Cost Explorer 実測) | $12.43 |
| うち COA 以前からの既存分 | $1.80 |
| **COA アイドル実測** | **$10.6/日 ≒ $0.44/時** — 計画値 $0.45/時とほぼ一致 |

- 懸念していた「エンドポイントの 2AZ 課金で計画の2倍($19/日)」は**発生せず**。1AZ 化パッチは不要と判定。
- デプロイ当日(8/12)の VPC $9.31 は NAT データ転送費(イメージ・依存取得)の上乗せによる一時的なもの。
- OpenSearch・Neptune はコスト上位に現れず、`aoss_min_ocu=0` と t4g.medium 縮小+停止運用が有効に機能。
- 判定に使ったコマンド:
  `aws ce get-cost-and-usage --time-period Start=<日>,End=<翌日> --granularity DAILY --metrics UnblendedCost --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Virtual Private Cloud"]}}' --region us-east-1`
  (Cost Explorer は UTC 日付・数時間の集計遅延あり。確定値は翌日昼以降に確認)

### 予算アラートの見直し(2026-08-14 追記)

- 当初のアカウント全体 $5/日 予算は、既存ワークロード(約$15/日)だけで毎日発火する設計ミスと判明。
- タグフィルタへの変更を試みたが、本アカウントは Organizations のメンバーアカウントであり
  **コスト配分タグの有効化は管理アカウントでのみ可能**(AccessDeniedException)。
- 対応: 全体監視は $100/日(最終防衛線)へ変更し、`Project=semantic-context` タグ限定の
  $15/日 予算(停止忘れ検知)は管理者によるタグ有効化後に追加する2層構成とした。
- しきい値・宛先の変更手順を含む詳細は **`docs/ops/cost-monitoring.md`** を参照。

## 次工程(Phase 3)への引き継ぎ

1. テストデータセットは作成済み: `datasets/change-point-management/`(変化点管理票100件、JSON/CSV)
2. Phase 3 では: CSV を S3 + Glue テーブル化(Tier 2 用)、JSON を文書化して登録(Tier 3 用)、
   namespace 作成 → Scan → FK レビュー → Induction → Playground 3層検証
3. Web UI 上の操作が中心になるため、UI 画面と CLI の併用手順とする
