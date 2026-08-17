# ガイド05: API と MCP(プログラムからのナレッジ利用)

構築したナレッジを、①REST(Context Manager 直接呼び出し)、②MCP(エージェント連携)、
③Jupyter Notebook サンプル、の3経路から利用します。

## ステップ1: 必要な値の確認方法(一覧)

API 利用に必要な値は環境ごとに異なります。すべて次のコマンドで確認できます。

> このステップの確認コマンドは、すべて実構築環境で実行し、構築記録の値と
> 一致することを確認済みです(2026-08-17。COA 停止中でも実行できます)。

前提の変数:

```bash
export COA_REGION=us-west-2        # 東京の場合: ap-northeast-1
```

### Cognito クライアント ID(MCP/CLI 用)

```bash
export MCP_CLIENT_ID=$(aws ssm get-parameter --name /coa/mcp-client-id \
  --region $COA_REGION --query Parameter.Value --output text)
echo $MCP_CLIENT_ID
```

SSM パラメータが見つからない場合は CloudFormation 出力から取得できます:

```bash
aws cloudformation describe-stacks --stack-name coa-dev-auth --region $COA_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='McpClientId'].OutputValue" --output text
```

> COA は Cognito クライアントを2つ作ります。Web UI 用(`coa-dev-client`、トークン有効期限1時間)と
> **MCP/CLI 用(`coa-dev-mcp-client`、ID トークン24時間・リフレッシュトークン30日)**です。
> プログラム利用には MCP/CLI 用を使います。

### MCP サーバーの URL

```bash
MCP_RUNTIME_ARN=$(aws ssm get-parameter --name /coa/mcp/runtime-arn \
  --region $COA_REGION --query Parameter.Value --output text)
export MCP_URL="https://bedrock-agentcore.$COA_REGION.amazonaws.com/runtimes/$(python3 -c "from urllib.parse import quote;print(quote('$MCP_RUNTIME_ARN', safe=''))")/invocations?qualifier=DEFAULT"
echo $MCP_URL
```

### Context Manager(質問応答 API)の URL

```bash
CM_RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region $COA_REGION \
  --query "agentRuntimes[?agentRuntimeName=='coa_dev_context_manager'].agentRuntimeArn" --output text)
export CM_INVOKE_URL="https://bedrock-agentcore.$COA_REGION.amazonaws.com/runtimes/$(python3 -c "from urllib.parse import quote;print(quote('$CM_RUNTIME_ARN', safe=''))")/invocations?qualifier=DEFAULT"
echo $CM_INVOKE_URL
```

### namespace ID

Web UI では「Administration → Namespaces → 対象を開いたときのブラウザ URL の
`namespaces/` の直後」です。CLI では一覧を直接確認できます:

```bash
aws dynamodb scan --table-name coa-dev-namespaces --region $COA_REGION \
  --filter-expression "SK = :m" --expression-attribute-values '{":m":{"S":"METADATA"}}' \
  --query "Items[].{id:namespaceId.S,name:name.S,status:status.S}" --output table
export NAMESPACE_ID=【上の一覧から選んだ id】
```

## ステップ2: 認証トークンの取得

MCP/CLI クライアントは開発環境(env=dev)で `USER_PASSWORD_AUTH` が有効です
(本番想定の認証方式は [ガイド06](guide_06_application_integration.md))。
ユーザーは [ガイド02 ステップ9](guide_02_deployment.md) で作成したものを使います:

```bash
export COA_USERNAME=【ログインメールアドレス】
read -s -p "Cognito パスワード: " COA_PW; echo
export TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH --client-id $MCP_CLIENT_ID \
  --auth-parameters "USERNAME=$COA_USERNAME,PASSWORD=$COA_PW" \
  --region $COA_REGION --query 'AuthenticationResult.IdToken' --output text)
unset COA_PW
echo "トークン長: ${#TOKEN}"   # 数百〜千程度の数字が出れば取得成功(0 や空なら失敗)
```

ID トークンの有効期限は **24時間**(MCP/CLI クライアントの設定値)。期限切れ
(`ExpiredToken` 系エラー)になったら再実行してください。

## ステップ3: MCP クライアントで6ツールを使う

このリポジトリの検証用クライアント(uv があればそのまま動きます)で接続します:

```bash
cd 【このリポジトリのディレクトリ】
uv run scripts/mcp/coa_mcp_client.py list          # 6ツール一覧が出れば接続成功
uv run scripts/mcp/coa_mcp_client.py metrics       # 登録メトリクス一覧
uv run scripts/mcp/coa_mcp_client.py query "不合格件数"
uv run scripts/mcp/coa_mcp_client.py query --tier 3 "質問文"
uv run scripts/mcp/coa_mcp_client.py rag "質問文"   # ベクター検索(Tier 3 の Retrieve 相当)
```

必要な環境変数は `MCP_URL` / `TOKEN` / `NAMESPACE_ID`(ステップ1〜2で設定済み)です。

| ツール | 役割 |
|---|---|
| `list_metrics` / `describe_schema` | メトリクス・スキーマの探索 |
| `query` | 3層カスケードでの質問応答(`tier_override` で 1/2/3 を固定可) |
| `translate_sparql` | 自然言語 → SPARQL 変換 |
| `rag_retrieval` | ベクター検索で文書チャンクを取得 |
| `graph_traversal` | ナレッジグラフの openCypher 探索 |

> 接続終了時に `Session termination failed: 404` と表示されることがありますが、
> AgentCore がセッション削除 API を持たないための**無害なメッセージ**です。

Claude Desktop / Claude Code などの MCP 対応エージェントから使う場合は、
streamable HTTP の URL に `$MCP_URL`、Authorization ヘッダーに `Bearer $TOKEN` を設定します。

## ステップ4: Jupyter Notebook サンプル

`notebooks/coa_query_sample.ipynb` が、Context Manager API を直接呼んで
Tier 1 / Tier 2 / ベクター検索 / Tier 3 を順に試すサンプルです。

- 設定値(リージョン・クライアント ID・namespace)は**セル実行時に自動発見または対話入力**します。
  ハードコードはありません
- 必要ライブラリ: `boto3` / `requests` / `pandas`(Anaconda 標準)
- COA 起動中(`start-coa.sh` 済み)に、上から順にセルを実行してください

## ステップ5: エージェント統合の推奨パターン(検証結果に基づく)

実機検証から得られた指針です:

1. **確定値は Tier 1 メトリクスに寄せる** — 頻出 KPI はメトリクス登録し、
   エージェントには `list_metrics` → `query` を使わせる(SQL 生成なしの確定的回答)
2. **構造化データへの質問は `query` に任せる** — Tier 1/2 が自動選択される
3. **文書知識は `rag_retrieval` で取得し、回答の合成はエージェント自身にやらせる** —
   ベクター検索の精度は高い一方、COA 内蔵の Tier 3 合成(`tier_override=3`)は
   検索戦略(グラフ topic 探索)の特性上、ベクター検索ならトップヒットする文書を
   拾えないことがある。根拠が無い場合に捏造しない設計は確認済みだが、再現率は
   `rag_retrieval` の方が高い
4. **AOSS のコールドスタート** — `aoss_min_ocu=0` 構成では、起動後の初回ベクター検索に
   約17秒かかる(以降は高速)。デモの前に1回ウォームアップしておくとよい

次: [ガイド06: アプリケーション統合](guide_06_application_integration.md)
