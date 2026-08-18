# ガイド07: トラブルシューティング

実際の構築(2回の実構築+埋め込みモデル切り替え)で遭遇した全事象の一覧です。
各事象の詳細な経緯は `docs/build-log/` の構築記録にあります。

## セットアップ・ビルド(ガイド02 ステップ2〜3)

### 1. `make setup` が pnpm インストールで EACCES

- **症状**: `npm error EACCES: permission denied, rename '/usr/lib/node_modules/pnpm' ...`
- **原因**: pnpm を `sudo npm install -g` で入れたため npm グローバル領域が root 所有。
  COA の setup スクリプトは sudo なしで再インストールを試みる
- **対処**: npm の prefix をユーザー領域へ([ガイド01 ステップ2](guide_01_prerequisites.md)の注意どおり)

### 2. `make setup` のたびに uv / pnpm が再インストールされる

- **原因**: COA の `scripts/setup-dev.sh` は shebang が `sh`(Ubuntu では dash)なのに
  bash 専用構文 `&>` で存在チェックしており、dash では常に「未インストール」と誤判定される
  (Linux 固有。macOS では発生しない)
- **対処**: 実害なし(同じ場所へ上書き)。スクリプトは編集しない(タグ更新時の差分を避ける)

### 3. `make setup` が「Installing pre-commit hooks...」で無言のまま Error 1

- **原因**: 上記2と同じ `&>` バグ。hooksPath 未設定の環境では `git config --get core.hooksPath` が
  exit 1 → `set -eu` で即死(メッセージなし)
- **対処**: `git config core.hooksPath .git/hooks`(Git 既定値の明示。副作用なし)

### 4. `make lint` / `make test` が VERSION 不在などで失敗

- **原因**: v0.1.0 タグに `VERSION` ファイルとリポジトリ直下 `tests/` が含まれていない梱包不備
- **対処**: 実体のチェックを直接実行: `pnpm nx run-many -t lint` / `pnpm nx run-many -t test`

## デプロイ(ガイド02 ステップ6〜7)

### 5. preflight が `VPC limit reached: 5/5` で失敗

- **対処**: クォータ引き上げ(実測数分で自動承認)。コマンドは [ガイド01 ステップ6](guide_01_prerequisites.md)

### 6. イメージビルドが `exec /bin/sh: exec format error`

- **原因**: COA のイメージは ARM64 用。x86_64 Linux では QEMU 登録が必要
- **対処**: `sudo apt-get install -y qemu-user-static` → `make deploy-dev` 再実行
  (作成済みスタックはスキップされ続きから進む)

### 7. (関連)binfmt 登録がマシン再起動で消えて再発

- **原因**: `docker run ... tonistiigi/binfmt --install arm64` による登録は揮発性
- **対処**: パッケージ導入(`qemu-user-static`)なら再起動後も維持される

### 8. CDK バンドル中に pip の依存関係エラーが大量表示される

- **判定**: **無害**。ローカル Python 環境の site-packages への競合報告であり、
  アセットのバンドルとデプロイは正常に完了する

## ナレッジ構築(ガイド04)

### 9. 文書取り込み(doc-kg-build)が Scan failed、ログに `MemoryLimitExceededException`

- **原因**: Neptune を小さいインスタンス(db.t4g.medium 等)にしていると、
  グラフ書き込みの並列クエリでサーバ側メモリが枯渇する
- **対処**(約10分)→ その後 Re-scan:
  ```bash
  INSTANCE_ID=$(aws neptune describe-db-clusters --db-cluster-identifier coa-dev-neptune \
    --region $COA_REGION --query 'DBClusters[0].DBClusterMembers[0].DBInstanceIdentifier' --output text)
  aws neptune modify-db-instance --db-instance-identifier $INSTANCE_ID \
    --db-instance-class db.r6g.large --apply-immediately --region $COA_REGION
  ```
  **KG 構築を伴う運用の下限は db.r6g.large(16GB)**。CDK パッチ側も揃えること(ドリフト防止)

### 10. 完了済み文書ソースの Re-scan ボタンが押せない

- **対処**: 追加文書は別プレフィックスに置き、**小さな新規ソースとして登録**する(既存ソースに影響なし)

### 11. Glue ソースが Scan failed、エラーに `https://glue.【文字列】.amazonaws.com/`

- **原因**: 登録フォームの Region 欄のタイプミスがそのままエンドポイント URL に組み込まれる
- **対処**: エラー中の URL でミスを確認 → ソースを Delete して正しいリージョン名で再登録

### 12. namespace が削除できない/DELETE_FAILED になる

- **ACTIVE のまま削除不可**: 仕様。Change status → ARCHIVED → Delete の2段階
- **DELETE_FAILED**: **Neptune 停止中に削除を実行した**のが典型(削除パイプラインはグラフ削除に
  Neptune 接続が必要。ログは `No route to host`)。`start-coa.sh` で起動してから再度 Delete
  (リトライは正式サポート。実測30秒で完了)
- **いつまでも DELETING 表示**: UI の表示が更新されないだけのことがある。ページ再読み込み(F5)。
  実状態は Step Functions(`coa-dev-namespace-deletion-pipeline`)の実行履歴で確認できる

### 13. メトリクス作成フォームの各種エラー

- Name に日本語 → 不可(英数字+アンダースコア)。日本語名は Synonym に登録
- 「Description is required」→ Description は必須
- 「Expression must be a full SELECT」→ 断片ではなく完全な SELECT 文を書く
- Data source ドロップダウンが空 → ページ再読み込み(F5)
- 「Endpoint request timed out」→ API Gateway の29秒制限。**サーバー側では作成済みのことがある**ため、
  一覧を確認してから再操作(重複作成エラーで気づくパターンもある)

## API・MCP(ガイド05)

### 14. MCP の実行系ツールが一律 `404: No endpoint or agent found with qualifier 'DEFAULT'`

- **原因**: **COA v0.1.0 のバグ**。MCP サーバーはリージョンを `SCL_AWS_REGION` から読む
  (無ければ us-east-1 にフォールバック)が、インフラは `AWS_REGION` しか設定しない。
  us-east-1 デプロイでは偶然一致して動くため気づかれにくく、**それ以外のリージョンでは
  実行系ツールが全滅**する
- **対処**: [ガイド02 ステップ4-2](guide_02_deployment.md) の1行パッチ。適用済みならこの事象は起きない。
  デプロイ後に気づいた場合はパッチ後に `pnpm --filter coa-infra exec cdk deploy coa-dev-mcp --require-approval=never`(約5分)
- **教訓**: AgentCore ランタイムのアプリログ(CloudWatch `/aws/bedrock-agentcore/runtimes/...`)に
  クライアント初期化時の実効設定(region 等)が出る。「どの設定で動いているか」はログが最速の一次情報

### 15. 埋め込みモデル切り替えが「no changes」でデプロイされない

- **原因**: モデル ID を置換しても `libs/ts-shared` の**ビルドをしていない**
  (infra は `dist` を参照するため、ソース置換だけでは CDK 差分が出ない)
- **対処**: `pnpm nx run @coa/shared:build` → 再デプロイ([ガイド02 ステップ4-3](guide_02_deployment.md))

### 16. 接続終了時の `Session termination failed: 404`

- **判定**: **無害**。AgentCore がセッション削除 API を持たないためのメッセージ

### 17. 初回のベクター検索だけ十数秒かかる

- **原因**: `aoss_min_ocu=0` 設定による OpenSearch Serverless のコールドスタート(実測約17秒)
- **対処**: 仕様として許容(以降は高速)。気になる場合は `aoss_min_ocu` を 1 以上に(常時課金増)

## 運用(ガイド03)

### 18. 停止したはずの Neptune が勝手に起動している

- **原因**: AWS の仕様(停止から**7日で自動再開**)
- **対処**: 長期停止中は週1で `stop-coa.sh` を再実行。使わないならフル削除
