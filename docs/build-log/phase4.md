# COA セルフホスト構築記録: Phase 4(MCP 接続と Tier 3 最終検証)

実施日: 2026-08-14
結果: **完了** — MCP 経由で6ツール接続、Tier 3 を含む3層すべての機能検証を達成
(過程で COA v0.1.0 の非 us-east-1 デプロイを壊すバグを発見・修正)

---

## MCP 接続手順(確立済み・再利用可)

```bash
# 1) トークン取得(有効期限 約1時間。パスワードは Web UI と同じ)
read -s -p "Cognitoパスワード: " COA_PW; echo
export TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH --client-id <MCPクライアントID> \
  --auth-parameters "USERNAME=<管理者メールアドレス>,PASSWORD=$COA_PW" \
  --region us-west-2 --query 'AuthenticationResult.IdToken' --output text)
unset COA_PW

# 2) エンドポイント URL(SSM から解決)
MCP_RUNTIME_ARN=$(aws ssm get-parameter --name /coa/mcp/runtime-arn \
  --region us-west-2 --query Parameter.Value --output text)
export MCP_URL="https://bedrock-agentcore.us-west-2.amazonaws.com/runtimes/$(python3 -c "from urllib.parse import quote;print(quote('$MCP_RUNTIME_ARN', safe=''))")/invocations?qualifier=DEFAULT"

# 3) 検証クライアント(scripts/mcp/coa_mcp_client.py)
uv run scripts/mcp/coa_mcp_client.py list      # 6ツール一覧
uv run scripts/mcp/coa_mcp_client.py rag "質問"
uv run scripts/mcp/coa_mcp_client.py query --tier 3 "質問"
```

主要な値: MCP 用 Cognito クライアント `<MCPクライアントID>` / MCP ランタイム
`coa_dev_mcp_server-<ランダムID>` / CM ランタイム `coa_dev_context_manager-<ランダムID>`。
接続終了時の「Session termination failed: 404」は AgentCore がセッション削除 API を
持たないための**無害なメッセージ**。

## 検証結果

| 検証 | 結果 |
|---|---|
| `tools/list` | ✅ 6ツールすべて認識(list_metrics / describe_schema / query / translate_sparql / rag_retrieval / graph_traversal) |
| `rag_retrieval`(ベクター検索) | ✅ **POLICY-001 の該当条文がスコア1位**(0.518)。規程+関連実例(CP-047等)を的確に取得。trace で `t3.vector_search`(OpenSearch)を確認 |
| `query --tier 3`(検索+合成) | ✅ 実行完走(topic_beam 検索 → Sonnet 5 合成 → ガードレール)。ただし下記の発見あり |
| CM 直接呼び出し(curl) | ✅ Tier 1 メトリクスが synonym マッチで発火(トラブル10の切り分けで実施) |

### 発見1: Tier 3 合成パスの検索リコール限界(記事の指摘を実機で再現)

`tierOverride=3` の合成パスは `topic_beam`(グラフ topic 探索)で検索するため、
**ベクター検索ならトップヒットする POLICY-001 を拾えなかった**。合成回答は
「文書に取り扱いルールの記載が見つからない」と**捏造せず正直に回答**(confidence 0.3)。
ハルシネーションしない設計は確認できたが、リコールは検索戦略に依存する。

### 発見2(運用指針): エージェント統合の推奨パターン

> **エージェントには `rag_retrieval`(ベクター検索)を呼ばせ、回答の合成はエージェント自身に
> やらせる。** ベクター検索の精度は高く(規程文書を正確に1位で取得)、MCP 経由の利用では
> エージェントが合成役を担うのが自然。COA 内蔵の Tier 3 合成は補助と位置づける。
> 構造化の質問は `query`(Tier 1/2 が自動選択)、確定値は Tier 1 メトリクスに寄せる。

### 補足観測

- AOSS コールドスタート: `aoss_min_ocu=0` のため初回ベクター検索は約17秒。以降は高速化。
- Tier 3 合成の総時間: 約24秒(検索12秒+合成10秒)。

---

## トラブルシューティング

### トラブル10: MCP 実行系ツールが一律 404(COA v0.1.0 のバグを発見)

**症状**: `rag_retrieval` 等の実行系ツールがすべて
`Context Manager returned 404: No endpoint or agent found with qualifier 'DEFAULT'`。
discovery(tools/list)は正常。CM ランタイムと DEFAULT エンドポイントは存在・READY。

**切り分けの経過**(記録価値があるため残す):
1. ラップトップから CM を直接 curl(同じトークン・同じ URL)→ **成功** → CM は健全
2. JWT オーソライザーの許可 audience 確認 → MCP クライアント ID を含む → 認可は正常
3. セッションヘッダー有無・VPC エンドポイントのプライベート DNS 無効化を試行 → 変化なし(棄却)
4. **MCP ランタイムのログで確定**: `cm_client_initialized` に `"region": "us-east-1"` —
   **us-east-1 のエンドポイントへ us-west-2 の ARN を投げていた**

**根本原因**: 環境変数名の不一致。MCP サーバーの設定(config.py)はリージョンを
`SCL_AWS_REGION` から読み(無ければ us-east-1 にフォールバック)、インフラ(mcp-stack.ts)は
`AWS_REGION` を設定している。**us-east-1 デプロイでは偶然一致して動くため、参考記事
(全て us-east-1)では顕在化しなかった**。非 us-east-1 デプロイで MCP 実行系が全滅する。

**対処**(1行パッチ+単一スタック再デプロイ、計約5分):
```bash
# infra/lib/stacks/services/mcp-stack.ts の environmentVariables に追加
#   SCL_AWS_REGION: region,
pnpm --filter coa-infra exec cdk deploy coa-dev-mcp --require-approval=never
```

**教訓**: AgentCore ランタイムのアプリログ(/aws/bedrock-agentcore/runtimes/...)には
クライアント初期化時の実効設定が出る。「どの設定で動いているか」はログが最速の一次情報。

---

## ローカルパッチ一覧(タグ更新時に再適用が必要)

| ファイル | 変更 | 理由 |
|---|---|---|
| `infra/lib/stacks/foundation/storage-stack.ts:118` | `db.r8g.large` → `db.r6g.large` | コスト削減(KG 構築の下限クラス) |
| `infra/lib/stacks/services/mcp-stack.ts` | `SCL_AWS_REGION: region,` を environmentVariables に追加 | 非 us-east-1 デプロイのバグ修正(トラブル10) |

いずれも上流(aws/context-ontology-accelerator)へ報告する価値あり
(特にトラブル10は再現条件・原因・修正が明確)。

## 全フェーズ総括(セルフホスト完了)

| 目的 | 達成状況 |
|---|---|
| ① AWS セルフホスト(コスト最小) | ✅ us-west-2、稼働 ~$1.9/時・アイドル $0.44/時(実測)、stop/start 運用確立 |
| ② RAG 代替ナレッジ構築 | ✅ 変化点管理票100件+機種マスタ+規程文書を Glue/GraphRAG 両系統に搭載、FK・オントロジー承認済み |
| ③ COA ナレッジシステム(エージェント利用) | ✅ MCP 6ツール接続、3層すべて検証済み、エージェント統合の推奨パターン確立 |
