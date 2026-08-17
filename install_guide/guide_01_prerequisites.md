# ガイド01: 事前準備(環境チェック)

デプロイ前に、ローカルのツールチェーンと AWS アカウント側の条件をすべて確認します。
ここで FAIL が残ったままデプロイに進むと、62分のデプロイの途中で失敗して時間を失います。

## ステップ1: 変数の設定

以降のすべてのガイドで使う変数です。新しいターミナルを開くたびに実行してください
(`~/.bashrc` に追記しても構いません)。

```bash
export COA_REGION=us-west-2        # オレゴン。東京に構築する場合は ap-northeast-1
export AWS_REGION=$COA_REGION
export AWS_DEFAULT_REGION=$COA_REGION
```

AWS CLI の認証(`aws configure` など)が済んでいることを確認します:

```bash
aws sts get-caller-identity
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo $ACCOUNT_ID
```

アカウント ID(12桁の数字)が表示されれば OK です。
**ルートユーザーでの実行は不可**です(チェックスクリプトが検出して FAIL にします)。

最後に、本リポジトリ(チェックスクリプト・データセット・ノートブックを含む)を取得します。
以降のガイドでは `~/work/coa_semantic_knowledge_bridge` に置いてある前提でパスを記載します:

```bash
mkdir -p ~/work && cd ~/work
git clone https://github.com/makonaga/coa_semantic_knowledge_bridge.git
cd coa_semantic_knowledge_bridge
```

## ステップ2: ローカルツールチェーンのインストール

COA のビルドに必要なツールと、Ubuntu 系 Linux での導入コマンドです
(macOS は Homebrew で同等のものを導入してください)。

| ツール | 要件 | Ubuntu での導入コマンド |
|---|---|---|
| Python | 3.12 | `sudo apt-get install -y python3.12`(または pyenv 等) |
| Node.js | 22 以上 | `curl -fsSL https://deb.nodesource.com/setup_22.x \| sudo -E bash -` → `sudo apt-get install -y nodejs` |
| pnpm | 最新 | **下記の注意を先に実施してから** `npm install -g pnpm` |
| uv | 最新 | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Java | 17 以上 | `sudo apt-get install -y openjdk-17-jdk` |
| Docker | デーモン起動済み | 公式手順(docs.docker.com)どおり |

> **注意(Linux)**: npm のグローバル領域が root 所有だと、後の `make setup` が
> EACCES で失敗します([トラブル1](guide_07_troubleshooting.md))。
> **`sudo npm install -g` は使わず**、先に npm のグローバル先をユーザー領域へ変更してください:
>
> ```bash
> mkdir -p ~/.npm-global
> npm config set prefix ~/.npm-global
> echo 'export PATH=$HOME/.npm-global/bin:$PATH' >> ~/.bashrc
> export PATH=$HOME/.npm-global/bin:$PATH
> npm install -g pnpm
> ```

## ステップ3: CDK bootstrap(メインリージョン + us-east-1)

CloudFront 用 WAF スタックが必ず us-east-1 に作られるため、**2リージョン分**必要です。

```bash
npx cdk bootstrap aws://$ACCOUNT_ID/$COA_REGION
npx cdk bootstrap aws://$ACCOUNT_ID/us-east-1
```

## ステップ4: Bedrock モデルアクセスの有効化

Bedrock コンソール(選択したリージョン)の **Model access** で、以下を有効化します:

- Anthropic Claude 系(COA 既定: Claude Sonnet 5 / Claude Sonnet 4.6 / Claude Haiku 4.5)
- 埋め込みモデル(本ガイド構成: **Amazon Titan Text Embeddings V2**。
  COA 素の既定は Cohere Embed v4 — どちらを使うかは [ガイド02 ステップ4](guide_02_deployment.md) 参照)

有効化しただけでは実際に呼べるか分からないため、次のステップの一括チェックで実呼び出し確認をします。

## ステップ5: 一括チェックの実行

このリポジトリのチェックスクリプトが、認証・bootstrap・Lambda クォータ・
Bedrock モデル実呼び出し・ツールチェーン・ディスク・DataZone 残骸を一括判定します:

```bash
bash scripts/phase0-check.sh
```

`FAIL` が出た項目には対処コマンドが表示されます。すべて解消してから先に進んでください。

> 東京リージョンなど、既定のモデル ID(`us.` プレフィックス)が使えない環境では、
> チェック対象モデルを環境変数で差し替えられます(ID の調べ方はステップ7):
>
> ```bash
> COA_CHAT_MODELS="【東京で確認した Claude 系プロファイル ID(スペース区切り)】" \
> COA_EMBED_MODEL=amazon.titan-embed-text-v2:0 \
> bash scripts/phase0-check.sh
> ```

## ステップ6: VPC クォータの確認

COA は専用 VPC を1つ新規作成します。リージョンの VPC 数が上限(既定5)に達していると
デプロイの preflight で失敗します([トラブル5](guide_07_troubleshooting.md))。先に確認します:

```bash
echo "現在の VPC 数: $(aws ec2 describe-vpcs --region $COA_REGION --query 'length(Vpcs)')"
echo "クォータ: $(aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE --region $COA_REGION --query Quota.Value --output text)"
```

「現在の VPC 数 + 1」がクォータを超える場合は引き上げを申請します(実測: 数分で自動承認):

```bash
aws service-quotas request-service-quota-increase \
  --service-code vpc --quota-code L-F678F1CE \
  --desired-value 10 --region $COA_REGION
```

## ステップ7: (東京リージョンのみ)モデル提供状況の確認

オレゴン(us-west-2)の場合、このステップは不要です。

### 7-1. Claude 系の推論プロファイル ID を調べる

COA がハードコードしている `us.anthropic.*` プロファイルは米国専用のため、
東京で使えるプロファイル ID を確認します:

```bash
aws bedrock list-inference-profiles --region ap-northeast-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId,'anthropic')].inferenceProfileId" \
  --output table
```

`jp.anthropic.claude-sonnet-4-5-20250929-v1:0` のような **`jp.`(国内完結)**、
`apac.` または `global.` プレフィックスの ID が返ります。COA が参照する3モデル
(Sonnet 5 / Sonnet 4.6 / Haiku 4.5)それぞれに対応する ID を控えてください。
対応するプロファイルが無いモデルは、近い世代(例: Sonnet 5 が無ければ Sonnet 4.6)で
代替します(置換手順は [ガイド02 ステップ4-4](guide_02_deployment.md))。

### 7-2. 埋め込みモデルの提供確認

```bash
aws bedrock list-foundation-models --region ap-northeast-1 \
  --by-output-modality EMBEDDING --query "modelSummaries[].modelId" --output table
```

`amazon.titan-embed-text-v2:0` があれば、実呼び出しでも確認します:

```bash
aws bedrock-runtime invoke-model --region ap-northeast-1 \
  --model-id amazon.titan-embed-text-v2:0 \
  --cli-binary-format raw-in-base64-out \
  --body '{"inputText":"ping","dimensions":1024,"normalize":true}' /tmp/embed-test.json \
  && echo OK
```

一覧に無い/呼べない場合の選択肢は2つです(埋め込みモデルにはクロスリージョン
推論プロファイルが存在しないため、他リージョンのモデルを東京から使うことはできません):

- COA 既定の **Cohere Embed v4**(`cohere.embed-v4:0` 系)を東京で確認して使う
  (組織によってはサードパーティモデルの利用承認が必要)
- **オレゴン(us-west-2)に構築する**(本ガイドの実証構成)

### 7-3. AgentCore の提供確認

```bash
aws bedrock-agentcore-control list-agent-runtimes --region ap-northeast-1
```

エラーなく応答(空リストで正常)すれば AgentCore Runtime が利用可能です。

## 完了チェックリスト

- [ ] `scripts/phase0-check.sh` が FAIL 0 で完走
- [ ] VPC クォータに 1 以上の空きがある
- [ ] (東京の場合)Claude 系プロファイル ID 3つと埋め込みモデルの提供を確認し、ID を控えた

次: [ガイド02: ビルドとデプロイ](guide_02_deployment.md)
