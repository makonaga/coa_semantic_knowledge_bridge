# ガイド02: ビルドとデプロイ

COA v0.1.0 を取得し、必須パッチを当てて、CDK で全スタックをデプロイします。
所要時間はビルド確認まで約30分、デプロイ本体が約62分(実測)です。

前提: [ガイド01](guide_01_prerequisites.md) の全チェックが完了していること。
各ターミナルで変数が設定されていること:

```bash
export COA_REGION=us-west-2        # 東京の場合: ap-northeast-1
export AWS_REGION=$COA_REGION
export AWS_DEFAULT_REGION=$COA_REGION
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## ステップ1: リポジトリの取得

```bash
cd ~/work   # 任意の作業ディレクトリ
git clone --branch v0.1.0 https://github.com/aws/context-ontology-accelerator.git
cd context-ontology-accelerator
```

以降のステップはすべてこの `context-ontology-accelerator` ディレクトリで実行します。

## ステップ2: セットアップ前の環境対策(Linux)

COA のセットアップスクリプトには Linux(dash)で誤動作する箇所があるため、
先に2つの対策を入れます(詳細: [トラブル1〜3](guide_07_troubleshooting.md))。

```bash
# npm グローバルをユーザー領域へ(ガイド01 ステップ2で実施済みなら不要)
npm config get prefix    # $HOME/.npm-global なら OK

# pre-commit フック検出の誤動作対策(副作用なし)
git config core.hooksPath .git/hooks
```

## ステップ3: ビルドとテスト

```bash
make setup                    # uv sync + pnpm install + Smithy codegen
pnpm nx run-many -t lint      # 12プロジェクト
pnpm nx run-many -t test      # 16タスク
```

> `make lint` / `make test` は v0.1.0 タグの梱包不備(VERSION ファイル欠落)で失敗します。
> 上記の `pnpm nx run-many` が実体のチェックです([トラブル4](guide_07_troubleshooting.md))。

## ステップ4: ローカルパッチの適用

デプロイ前に COA のソースへ最小限のパッチを当てます。
**COA のタグを更新(再取得)した場合は毎回再適用が必要**です。

### 4-1. Neptune インスタンスの縮小(コスト削減、推奨)

既定の `db.r8g.large` を `db.r6g.large` に縮小します(月額換算で約2割減)。
**これ未満(t4g.medium 等)はナレッジグラフ構築がメモリ不足で失敗するため下限です**
([トラブル7](guide_07_troubleshooting.md))。

```bash
sed -i 's/db\.r8g\.large/db.r6g.large/' infra/lib/stacks/foundation/storage-stack.ts
grep -n "db\.r6g\.large" infra/lib/stacks/foundation/storage-stack.ts   # 1行出れば OK
```

適用前に、選択リージョンで提供されているかを確認できます:

```bash
aws neptune describe-orderable-db-instance-options --engine neptune \
  --db-instance-class db.r6g.large --region $COA_REGION \
  --query 'length(OrderableDBInstanceOptions)'   # 1 以上なら提供あり
```

### 4-2. リージョンバグ修正(us-east-1 以外では必須)

COA v0.1.0 には、**us-east-1 以外にデプロイすると MCP の実行系ツールがすべて 404 になる**
バグがあります(環境変数名の不一致。詳細: [トラブル10](guide_07_troubleshooting.md))。1行追加で修正します:

```bash
sed -i 's/AWS_REGION: region,/AWS_REGION: region,\n        SCL_AWS_REGION: region,/' \
  infra/lib/stacks/services/mcp-stack.ts
grep -n "SCL_AWS_REGION\|AWS_REGION" infra/lib/stacks/services/mcp-stack.ts
# AWS_REGION: region, の直後に SCL_AWS_REGION: region, の行が1つ増えていれば OK
```

> この sed は実構築で使用したものです。**2回実行すると行が重複する**ので、
> 適用前に grep で未適用であることを確認してください。

### 4-3. 埋め込みモデルの切り替え(Cohere Embed v4 → Titan Text Embeddings V2)

COA の既定埋め込みモデルは Cohere Embed v4 です。組織のポリシー上サードパーティモデルを
使えない場合や、リージョンで提供が無い場合は、Amazon Titan Text Embeddings V2(同じ1024次元)へ
一括置換します。**検証済み**: 検索精度は Cohere 時と同等以上、チャンク分割・FK 推論・
オントロジー検証の結果も完全一致でした(`docs/build-log/phase4b-titan-switch.md`)。

```bash
grep -rl "us\.cohere\.embed-v4:0" --include="*.ts" --include="*.py" . | grep -v node_modules \
  | xargs sed -i 's/us\.cohere\.embed-v4:0/amazon.titan-embed-text-v2:0/g'

# infra は libs/ts-shared のビルド成果物(dist)を参照するため、置換後のビルドが必須
pnpm nx run @coa/shared:build

# 確認(node_modules 以外に置換漏れゼロ)
grep -rl "us\.cohere\.embed-v4:0" --include="*.ts" --include="*.py" . | grep -v node_modules ; echo "残存: $?"
```

最後の行は「残存: 123」のように **1(= 見つからない)** が出れば成功です。

> Cohere Embed v4 をそのまま使う場合はこのパッチをスキップしてください。その場合
> `scripts/phase0-check.sh` の埋め込みチェックを `COA_EMBED_MODEL=us.cohere.embed-v4:0` で
> 実行して疎通を確認しておきます。

### 4-4. (東京リージョンのみ)Claude モデル ID の置換

[ガイド01 ステップ7-1](guide_01_prerequisites.md) で控えたプロファイル ID に置き換えます。
実行時に使われる既定モデルは次の**3つ**です(このほかテストコード内にも多数の
モデル ID が現れますが、デプロイの動作に影響するのはこの3つです):

| 用途 | v0.1.0 の既定 ID |
|---|---|
| 質問応答(serve) | `us.anthropic.claude-sonnet-5` |
| オントロジー生成 | `us.anthropic.claude-sonnet-4-6` |
| 抽出・rerank | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

それぞれを、確認した東京向け ID(`jp.` / `apac.` / `global.` プレフィックス)へ置換します。
例(**ID は必ずステップ7-1の確認結果に合わせて書き換えてください**):

```bash
grep -rl "us\.anthropic\.claude-sonnet-5" --include="*.ts" --include="*.py" . | grep -v node_modules \
  | xargs sed -i 's/us\.anthropic\.claude-sonnet-5/【確認したプロファイルID】/g'
# 残り2つの ID も同様に置換
```

置換後は 4-3 と同様に `pnpm nx run @coa/shared:build` を実行します。

> **注意**: 東京リージョンでの構築は本ガイドでは**未検証**です(実証済みはオレゴンのみ)。
> このモデル ID 置換もオレゴン構築で検証した Titan 置換(4-3)と同じ仕組みに基づく手順であり、
> 実施時は `scripts/phase0-check.sh`(`COA_CHAT_MODELS` 指定)での実呼び出し確認を必ず先に行ってください。

## ステップ5: デプロイ設定(cdk.json の context)

管理者として登録する IAM プリンシパルの ARN(user または role の ARN のみ有効)と、
OpenSearch Serverless の OCU 設定を書き込みます:

```bash
export ADMIN_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo $ADMIN_ARN   # assumed-role の場合は元のロール ARN (arn:aws:iam::…:role/…) に読み替えて設定すること

python3 - <<EOF
import json, os
p = "infra/cdk.json"
d = json.load(open(p))
d["context"].update({
    "env": "dev",
    "smus_admin_principal_arns": os.environ["ADMIN_ARN"],
    "aoss_min_ocu": 0,    # アイドル時 OCU を 0 に(コスト削減。初回検索が約17秒遅くなる)
    "aoss_max_ocu": 16,
})
json.dump(d, open(p, "w"), indent=2)
print("updated:", d["context"]["smus_admin_principal_arns"])
EOF
```

## ステップ6: (x86_64 Linux のみ)ARM64 ビルド環境の登録

COA のコンテナイメージは ARM64(Graviton)用です。x86_64 の Linux ホストでは
QEMU エミュレーションの登録が必要です([トラブル6](guide_07_troubleshooting.md)):

```bash
sudo apt-get install -y qemu-user-static   # 再起動後も維持される恒久設定
# 確認(aarch64 と出れば OK)
docker run --rm --platform linux/arm64 public.ecr.aws/amazonlinux/amazonlinux:2023 uname -m
```

> `docker run --privileged --rm tonistiigi/binfmt --install arm64` でも登録できますが、
> **マシン再起動で消えます**([トラブル11](guide_07_troubleshooting.md))。パッケージ導入を推奨します。

## ステップ7: デプロイ実行

```bash
make deploy-dev
```

- 実測 62 分。ARM64 エミュレーション下のイメージビルド(特に vkg)は10〜30分かかり、
  止まって見えても待つこと。
- 途中で失敗しても、原因解消後に `make deploy-dev` を再実行すれば
  **作成済みスタックはスキップされ続きから進みます**。
- バンドル中に pip の依存関係エラーが大量表示されることがありますが、ローカル環境への
  警告であり無害です([ガイド07](guide_07_troubleshooting.md))。

完了確認(16スタックすべて `CREATE_COMPLETE`):

```bash
aws cloudformation list-stacks --region $COA_REGION \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName,'coa-dev')].StackName" --output table
aws cloudformation list-stacks --region us-east-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?StackName=='coa-dev-edge-waf'].StackName" --output text
```

## ステップ8: Web UI の URL を確認する

Web UI の URL(CloudFront ドメイン)はデプロイごとに変わります。次のコマンドで確認します:

```bash
DIST_ID=$(aws cloudformation describe-stack-resources --stack-name coa-dev-web --region $COA_REGION \
  --query "StackResources[?ResourceType=='AWS::CloudFront::Distribution'].PhysicalResourceId" --output text)
export COA_WEB_URL="https://$(aws cloudfront get-distribution --id $DIST_ID --query Distribution.DomainName --output text)"
echo $COA_WEB_URL
```

## ステップ9: 管理ユーザーの作成

Web UI にログインするユーザーを Cognito に作成し、`Admin` グループ(platform-admin 相当)に追加します:

```bash
export COA_ADMIN_EMAIL=【ログインに使うメールアドレス】

POOL_ID=$(aws cloudformation describe-stacks --stack-name coa-dev-auth --region $COA_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
echo $POOL_ID

aws cognito-idp admin-create-user --user-pool-id $POOL_ID --region $COA_REGION \
  --username $COA_ADMIN_EMAIL \
  --user-attributes Name=email,Value=$COA_ADMIN_EMAIL Name=email_verified,Value=true

aws cognito-idp admin-add-user-to-group --user-pool-id $POOL_ID --region $COA_REGION \
  --username $COA_ADMIN_EMAIL --group-name Admin
```

仮パスワードが記載された招待メールが届きます。届かない場合は仮パスワードを直接設定できます:

```bash
aws cognito-idp admin-set-user-password --user-pool-id $POOL_ID --region $COA_REGION \
  --username $COA_ADMIN_EMAIL --password '【一時パスワード(8文字以上・大小英数記号)】'
```

> Cognito に `nobody@amazon.com` というダミー管理者が自動作成されていますが、COA の仕様です。
> ログイン不可のため実害はなく、CloudFormation 管理下のため削除しないでください。

## ステップ10: ログイン確認と停止

ステップ8の URL をブラウザで開き、作成したユーザーでログインします。
初回は仮パスワードの変更を求められます。左メニューに Administration / Scan / Ontology /
Playground が表示されれば構築成功です。

**作業を中断する場合は必ず停止スクリプトを実行してください**(以降の運用は [ガイド03](guide_03_cost_operation.md)):

```bash
cd ~/work/coa_semantic_knowledge_bridge
bash scripts/ops/stop-coa.sh
```

次: [ガイド03: コスト運用](guide_03_cost_operation.md) → [ガイド04: ナレッジ構築](guide_04_knowledge_onboarding.md)
