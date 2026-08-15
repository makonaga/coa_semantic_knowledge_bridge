# 埋め込みモデル切り替え記録: Cohere Embed v4 → Amazon Titan Text Embeddings V2

背景: 社内で Cohere Embed v4 の利用申請が未了のため、Amazon 純正の
**Titan Text Embeddings V2**(`amazon.titan-embed-text-v2:0`、1024次元)へ切り替える。
なお切り替え前の Embed v4 呼び出しは**すべて架空の合成テストデータのみ**
(Bedrock ホストのためデータは自アカウントの us-west-2 内で処理、Cohere 社への送信・学習利用なし)。

## 進捗チェックポイント(2026-08-15 中断時点)

| ステップ | 状態 |
|---|---|
| B-1: Titan 疎通確認(1024次元応答) | ✅ 完了 |
| B-2: モデル ID 一括置換(TS/Python 定数ほか9ファイル)+ `pnpm nx run @coa/shared:build` | ✅ 完了 |
| B-3: 4スタック再デプロイ(sources / serve / ontology / metric-service)| ✅ 完了(全て UPDATE_COMPLETE、8/15 00:51-01:01 UTC)|
| B-4-1: 旧 namespace `change-mgmt` の削除(旧 Cohere ベクター全削除) | ✅ 完了(一覧が空になったことを確認)|
| **B-4-2以降: namespace 再作成〜再オンボード** | ⬜ **未実施(再開はここから)** |
| B-5: 動作確認(Playground + MCP rag_retrieval) | ⬜ 未実施 |

**これ以降、COA から Cohere への呼び出しは発生しない**(B-3 完了時点で確定)。

## 再開手順(次回セッション)

1. `bash scripts/ops/start-coa.sh` → Neptune available まで待機
2. Web UI で namespace `change-mgmt` を再作成 → 新 namespace ID を控える
3. Glue ソース `coa_testdata` 登録 → スキャン → FK レビュー承認 → Approve source
4. S3 ソース `change-docs`(documents/)と `policy-docs`(policy/)を登録
   (Titan はバッチ埋め込み API 非対応のため取り込みは前回比で長め: 20〜40分見込み)
5. Induction → Validate → Accept
6. メトリクス `failed_count` 再登録(SQL・Synonym は phase3.md 記載どおり)
7. B-5 検証: Playground で `不合格件数`→4、MCP で `rag_retrieval`(要 `export NAMESPACE_ID=新ID`)
   → POLICY-001 がヒットすれば切り替え完了。**完了後にドキュメント一式を Titan ベースへ更新する。**

## 技術メモ(切り替えの設計根拠)

- COA の埋め込み実装(`libs/common/src/coa_common/embeddings.py`)はモデル ID でリクエスト形式を
  自動判別(Cohere / Titan 両対応)。**非 Cohere-v4 はバッチ経路を自動回避**(:409)するためコード改修不要。
- 次元は両モデルとも 1024 で OpenSearch インデックス設定と互換。
- IAM は各スタックが `foundation-model/*` を許可済みのため Titan 用の権限追加不要。
- 置換対象は `us.cohere.embed-v4:0` の文字列 9ファイル(TS 定数 / Python 定数 / 実装 / 監視 / スタック2 / テスト3)。
  infra は `libs/ts-shared/dist` を参照するため、**置換後に `pnpm nx run @coa/shared:build` が必須**。

## トラブルシューティング(このセッションで発生した3件)

### トラブル11: ARM64 イメージビルドが再び exec format error

**原因**: QEMU binfmt 登録(トラブル6の対処)は**マシン再起動で消える**。
**対処(恒久化)**: `sudo apt-get install -y qemu-user-static`(パッケージ導入なら再起動後も維持)。

### トラブル12: namespace 削除が DELETE_FAILED

**原因**: **Neptune 停止中に削除を実行**したため。削除パイプラインは Neptune 上のグラフデータ削除に
接続が必要(ログ: `No route to host` → kg-build クリーンアップタスクが exit 1)。
**対処**: `start-coa.sh` で Neptune を available にしてから、DELETE_FAILED の namespace を再度 Delete
(リトライは正式サポート。実測30秒で SUCCEEDED)。
**教訓**: **削除・取り込み等のパイプライン操作は COA 起動中にのみ実行する**(停止運用との組み合わせの落とし穴)。
なお UI 上の「explicit deny」表示は ARCHIVED 状態のソース直接削除に対する内部認可の拒否で、本筋ではない。

### トラブル13(小): 削除完了後も UI が DELETING 表示のまま

Step Functions 実行は30秒で SUCCEEDED していたが、UI の一覧表示が更新されず約1時間 DELETING に見えた。
**対処**: ブラウザのページ再読み込み。長引いて見えたら
`aws stepfunctions list-executions --state-machine-arn <coa-dev-namespace-deletion-pipeline>` で実状態を確認する。
