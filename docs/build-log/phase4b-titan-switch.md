# 埋め込みモデル切り替え記録: Cohere Embed v4 → Amazon Titan Text Embeddings V2

背景: 社内で Cohere Embed v4 の利用申請が未了のため、Amazon 純正の
**Titan Text Embeddings V2**(`amazon.titan-embed-text-v2:0`、1024次元)へ切り替える。
なお切り替え前の Embed v4 呼び出しは**すべて架空の合成テストデータのみ**
(Bedrock ホストのためデータは自アカウントの us-west-2 内で処理、Cohere 社への送信・学習利用なし)。

## 結果: 切り替え完了(2026-08-16)

| ステップ | 状態 |
|---|---|
| B-1: Titan 疎通確認(1024次元応答) | ✅ 完了 |
| B-2: モデル ID 一括置換(TS/Python 定数ほか9ファイル)+ `pnpm nx run @coa/shared:build` | ✅ 完了 |
| B-3: 4スタック再デプロイ(sources / serve / ontology / metric-service)| ✅ 完了(全て UPDATE_COMPLETE、8/15 00:51-01:01 UTC)|
| B-4-1: 旧 namespace `change-mgmt` の削除(旧 Cohere ベクター全削除) | ✅ 完了 |
| B-4-2: namespace 再作成〜再オンボード | ✅ 完了(新 namespace ID: `<namespace ID>`)|
| B-5: 動作確認(Playground + MCP rag_retrieval) | ✅ **全項目合格** |

**B-3 完了以降、COA から Cohere への呼び出しは発生しない。旧 Cohere 生成ベクターも B-4-1 で全削除済み。**

## B-5 検証結果(Titan での3層動作)

| 検証 | 結果 |
|---|---|
| Tier 1: `不合格件数` | ✅ Metric Match(synonym, confidence 1)発火・確定的実行(100%)・値 4 |
| Tier 2: 機種ごとの変化点件数 | ✅ 10機種×10件(FK JOIN 含む)。クエリ埋め込み 1024次元(Titan)・confidence 90% |
| Tier 3: MCP `rag_retrieval` | ✅ **POLICY-001 の該当条文がスコア1位(0.535)** — Cohere 時(0.518)と同等以上。DR1 条項が2位、関連実例(CP-061/081)も上位 |

### 実測メモ

- 100文書の再取り込み(前処理+抽出+Titan 埋め込み+グラフ格納)は**約7分**。
  懸念していた「Titan のバッチ API 非対応による遅延」は実運用上問題にならなかった。
- チャンク数は Cohere 時と完全一致(100文書/198チャンク)— 分割はモデル非依存で再現。
- FK 推論も再現(`model_name → models.model_name` の1件のみ、confidence 90%)。
- HermiT 検証も同一結果(0 error・CONSISTENT)。

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

### トラブル14(小): Glue ソース登録時のリージョン入力ミス

**症状**: Scan failed —
`Could not connect to the endpoint URL: "https://glue.us-west-2-1.amazonaws.com/"`。
**原因**: 登録フォームの Region 欄に `us-west-2-1` と入力してしまった(不正なリージョン名が
そのままエンドポイント URL に組み込まれる)。接続テストのエラーメッセージに実際の接続先が
出るため、URL 中のリージョン文字列を見れば即座に切り分けられる。
**対処**: ソースを Delete して正しい Region(`us-west-2`)で再登録。

### 再構築時の小さな注意点(UI 操作)

- namespace 作り直し直後は Create metric の Data source ドロップダウンが空のことがある → **ページ再読み込み**で解消。
- メトリクス作成は **Description が必須**(未入力だと「Description is required」)。
- メトリクス作成が「Endpoint request timed out」(API Gateway 29秒制限)になっても、
  **サーバー側では作成が完了していることがある**。一覧を確認し、重複作成前に既存を Edit する。
- テーブル承認は詳細画面右上の「**Approve table & all columns**」ボタンが最短(FK・PK 込みで一括承認)。
