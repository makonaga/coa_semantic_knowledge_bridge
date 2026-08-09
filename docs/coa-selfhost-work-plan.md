# COA セルフホスト構築 — 検証済み詳細作業計画

作成日: 2026-08-09
検証対象: [aws/context-ontology-accelerator](https://github.com/aws/context-ontology-accelerator)
(v0.1.0 タグ / main `631e152` Mirror sync 2026-08-05 の両方でコード検証済み)

元の作業計画書(アップロード版)の記載内容を COA 実コードと突き合わせて検証した結果と、
それを反映した詳細作業リスト。

---

## 1. 妥当性検証の結果

### 1-1. 実コードで確認できた項目(計画書の記載どおり)

| 計画書の記載 | 検証結果 |
|---|---|
| `aoss_min_ocu` コンテキスト(既定 2)| ✅ `storage-stack.ts:223`。コードコメントに「有効値 0, 2, 4, 8, 16, or multiples of 16」と明記。**OCU=0 は公式サポート値** |
| `aoss_max_ocu` 既定 96 | ✅ `storage-stack.ts:221` |
| Neptune `db.r8g.large` ハードコード | ✅ `storage-stack.ts:118`(v0.1.0 でも同一行)。縮小には CDK パッチが必要 |
| Neptune クラスタ識別子 `coa-dev-neptune` | ✅ `prefixed("neptune")`、stackPrefix は `coa-dev`(env=dev 時) |
| `smus_admin_principal_arns` 未設定時に `role/Admin` を信頼 | ✅ `namespace-stack.ts:929` に `arn:aws:iam::<account>:role/Admin` が既定値としてハードコード。コンテキスト設定は必須 |
| Lambda `reservedConcurrentExecutions: 5` が2箇所 | ✅ `vkg-stack.ts:236` と `sources-stack.ts:1241`。同時実行上限 10 のアカウントでは失敗する |
| serve の既定モデル `us.anthropic.claude-sonnet-5` | ✅ ただし現 main では `bedrock.py:119`(計画書の :85 から行番号が移動)。環境変数 `BEDROCK_MODEL_ID` でも上書き可 |
| `make deploy-dev` / `preflight` / destroy | ✅ Makefile に存在(`preflight` → `scripts/preflight-deploy.sh`) |
| ontology-engine Fargate 8vCPU/32GB 常駐 | ✅ `ontology-stack.ts:110-113` に既定値 cpu 8192 / memory 32768 / desiredCount 1 |
| MCP ツール6種 | ✅ `list_metrics` / `describe_schema` / `query` / `translate_sparql` / `rag_retrieval` / `graph_traversal`(discovery.py + execution.py) |
| `onboard-demo.sh` は `demo/` 未同梱で動かない | ✅ スクリプト自身のコメントに「demo/<industry>/manifest.yaml … not included」と明記。リポジトリに `demo/` は存在しない |
| `insurance.obda` の URI テンプレート不整合バグ | ✅ 現 main でも `:forPolicy :policy{customer_id}` のまま未修正(15行目の正は `:customer{customer_id}`) |
| `coa-dev-integ-test-user` シークレットの作成コードが無い | ✅ `scripts/serve/doctor.py:40` 等が参照するが、infra 側に作成コードは無い。使うなら手動作成 |
| AOSS は NEXTGEN + standbyReplicas ENABLED 固定 | ✅ `storage-stack.ts:232`。standby 無効化によるコスト削減は不可(OCU=0 が唯一のレバー) |
| NAT Gateway 1台 / Interface VPC エンドポイント約40 | ✅ `network-stack.ts`(natGateways: 1、Interface エンドポイント 40 箇所)。アイドル時 ~$0.45/時(40 ENI × $0.01 + NAT $0.045)の見積りと整合 |
| README は「main ではなくリリースタグを使え」 | ✅ README 26-32行目に明記 |

### 1-2. 計画書からの修正・補足点

1. **スタック数は 16 ではなく 18**。`infra/bin/app.ts` は v0.1.0 / main とも 18 スタックをインスタンス化している(参考記事執筆時点から増えた)。デプロイ時間 1〜1.5h の見積り自体は据え置きで妥当。
2. **リリースタグは現時点で `v0.1.0` のみ**(2026-08-09 時点)。「最新タグを checkout」は実質 v0.1.0 一択。コスト削減レバー(`aoss_min_ocu`)・行番号は v0.1.0 でも main と同一であることを確認済みなので、**README 推奨どおり v0.1.0 を使う**。
3. **ontology-engine の縮小は stack コードのパッチ不要**。`OntologyStackProps` に `cpu` / `memoryLimitMiB` / `desiredCount` が定義済みで、`infra/bin/app.ts:437` のインスタンス化箇所では渡していないだけ。app.ts に props を1行足すだけで縮小・初期停止(desiredCount: 0)が可能。ただし HermiT 推論はメモリ集約なので、縮小は induction が通ることを確認しながら段階的に。
4. **bedrock.py の行番号は :85 → :119**(現 main)。行番号はタグ更新で動くため、作業時は行番号でなくシンボル(`BEDROCK_MODEL_ID` 既定値)で探すこと。
5. Neptune 縮小パッチ(db.r6g.large 等)は、Neptune エンジンバージョンごとの対応インスタンスクラスを要確認。停止スクリプト運用が主レバーであり、**縮小パッチは優先度低**(差額 ~$0.1/時程度)。

### 1-3. 結論

**計画は妥当。そのまま進めてよい。** コスト構造の分析(基盤インフラが9割・Bedrock は誤差)、
「常時稼働しない+停止/削除スクリプトを先に整備」という方針、FK 推論の人間レビュー必須化は
いずれもコード・実測記事と整合している。上記 1-2 の5点だけ計画に反映する。

---

## 2. 詳細作業リスト

各タスクに完了条件(DoD)を付す。時間見積りは参考記事の実測ベース。

### Phase 0: 事前確認(AWS 環境チェック)— 約0.5h

すべて us-east-1。

- [ ] **0-1. CDK bootstrap 確認**
  `aws ssm get-parameter --name /cdk-bootstrap/hnb659fds/version --region us-east-1`
  無ければ `npx cdk bootstrap aws://<ACCOUNT_ID>/us-east-1`
  DoD: パラメータが取得できる。
- [ ] **0-2. Lambda 同時実行クォータ確認**
  `aws lambda get-account-settings --query AccountLimit.ConcurrentExecutions`
  DoD: 実効値 ≥ 100(reservedConcurrentExecutions: 5 × 2 + unreserved 最小値の余裕)。10 なら引き上げ申請し、**実効値反映まで待つ**。
- [ ] **0-3. Bedrock モデル実呼び出しテスト**
  Sonnet 5(serve 既定)/ Sonnet 4.6(フォールバック)/ Haiku 4.5 / Cohere Embed v4 を `bedrock-runtime invoke-model` で実テスト。agreement AVAILABLE でも TPM クォータ未割当のケースがあるため必ず invoke で確認。
  DoD: 少なくとも Sonnet 4.6 と埋め込みモデルが呼べる。Sonnet 5 不可なら Phase 2-5 の SSM 差し替えを実施予定に組み込む。
- [ ] **0-4. ローカルツールチェーン**: Python 3.12 / Node 22+ / pnpm / uv / Java 17+(Smithy codegen 必須)/ Gradle / Docker。
  DoD: 全コマンドがバージョン応答する。
- [ ] **0-5. ディスク空き 60GB 以上**確認。
- [ ] **0-6. DataZone ドメイン残骸確認**: `aws datazone list-domains --region us-east-1`
  DoD: 残骸ゼロ、または削除済み。

### Phase 1: リポジトリ準備とローカル動作確認 — 約1h(AWS 不要・任意)

- [ ] **1-1. v0.1.0 タグで clone**
  `git clone --branch v0.1.0 https://github.com/aws/context-ontology-accelerator.git`
  (タグは現時点で v0.1.0 のみ。作業開始時に releases ページで新タグの有無を再確認)
- [ ] **1-2. `make setup`**(uv sync + pnpm install + Smithy codegen)→ `make lint && make test`
  DoD: テストがグリーン。
  既知: pip 手動インストールに流れる場合は `mcp>=1.9.0,<2.0.0` を明示(uv sync なら不要)。
- [ ] **1-3.(任意)ローカル単体検証**: ontology-engine(HermiT)/ vkg(Ontop CLI 5.5.0 直接 DL)/ Tier 1 MetricResolver(in-memory)。
  既知: `packages/vkg/tests/fixtures/insurance.obda` の `:forPolicy :policy{customer_id}` は `:customer{customer_id}` の誤り(main でも未修正)。fixture を触る検証をする場合のみ手元で修正。

### Phase 2: CDK デプロイ(コスト最適化込み)— デプロイ正味 1〜1.5h

- [ ] **2-1. `infra/cdk.json` にコンテキスト設定**
  ```jsonc
  {
    "context": {
      "env": "dev",
      "smus_admin_principal_arns": "arn:aws:iam::<ACCOUNT_ID>:user/<YOUR_USER>",  // 必須。未設定だと存在しない role/Admin を信頼して失敗
      "aoss_min_ocu": 0,    // 最大のコスト削減レバー(有効値: 0,2,4,8,16,16の倍数)
      "aoss_max_ocu": 16    // 既定96は検証用途に過剰
    }
  }
  ```
- [ ] **2-2. ontology-engine 縮小/初期停止パッチ(app.ts、任意)**
  `infra/bin/app.ts` の `new OntologyStack(...)` に props を追加(stack 本体の改変不要):
  - 保守的: `desiredCount: 0`(induction 実行時のみ 1 に上げる)
  - 積極的: `cpu: 2048, memoryLimitMiB: 8192` — ただし HermiT のメモリ不足リスクがあるため、induction が失敗したら戻す前提で
  パッチは `patches/` に diff 保存し、タグ更新時に再適用できるようにする。
- [ ] **2-3.(優先度低・任意)Neptune 縮小パッチ**
  `storage-stack.ts:118` の `db.r8g.large` → 小クラス。エンジンバージョン対応クラスを AWS ドキュメントで確認の上。停止運用が主レバーなので省略可。
- [ ] **2-4. `make deploy-dev`**(preflight → build → cdk deploy --all、18スタック)
  失敗時リカバリ:
  - DataZone 409: `aws datazone delete-domain --identifier <dzd-xxxx> --skip-deletion-check` → リトライ
  - `DELETE_FAILED` スタックは依存順に個別削除 → 再実行
  DoD: 全スタック CREATE_COMPLETE、Web UI にアクセス可。
- [ ] **2-5. 停止/起動/削除スクリプト整備(デプロイ直後に必ず)** — `scripts/ops/` に:
  - `stop-coa.sh`: Neptune 停止(`coa-dev-neptune`)+ 全 ECS サービス desiredCount 0。アイドル ~$0.45/時まで削減。
  - `start-coa.sh`: 逆操作(Neptune start、desiredCount 1)。
  - `destroy-coa.sh`: 付属 `scripts/destroy.sh` ベース。注意: AgentCore ENI デタッチ最大8h → `--retain-resources <SG論理ID>` で抜ける場合は孤児 SG を必ず手動削除 / `coa-dev-storage` は6スタックのエクスポート参照が消えるまで削除不可 / ECS は `delete-service --force` が必要。
  - Neptune 7日自動再開への再停止(EventBridge Scheduler)。
  DoD: stop → start の一往復が実際に動くことを確認済み。
- [ ] **2-6. デプロイ後の初期設定**
  - Sonnet 5 が呼べないアカウントの場合: `aws ssm put-parameter --name /coa/config --value '{"bedrockLlmModelId":"us.anthropic.claude-sonnet-4-6"}' --overwrite` → `cdk deploy coa-dev-serve`
  - Cognito ユーザー作成(UsernameAttributes: email のため --username はメールアドレス)。
  - `scripts/serve/doctor.py` 等を使うなら `coa-dev-integ-test-user` シークレットを手動作成(リポジトリに作成コード無し)。
- [ ] **2-7. コスト監視の設定**: Cost Explorer タグフィルタ(`Project=semantic-context`)+ 日次 Budget アラート($5/日)。

### Phase 3: サンプルデータで E2E 検証 — 約2〜3h

`onboard-demo.sh` は `demo/` 未同梱のため自作データで実施。

- [ ] **3-1. 構造化データ準備**: CSV 5〜6テーブル(日本語カラムコメント付き)→ S3 → Glue テーブル作成。**「onboard 時点で Athena からクエリ可能」が要件**(S3 CSV 直接は不可)。
  DoD: Athena から全テーブルに SELECT が通る。
- [ ] **3-2. ドキュメント準備**: 日本語 Markdown 2〜3本(用語集・ポリシー文書)。
- [ ] **3-3. Web UI で namespace 作成 → Sources 登録 → スキャン**。
- [ ] **3-4. FK 推論レビュー(必須工程)**: `scl:fkProvenance = AI_INFERRED` の FK を全件目視。誤 FK を承認すると R2RML JOIN に焼き込まれ**エラーなしで NULL が返る**(confidence 足切り無し)。
  DoD: AI 推論 FK 全件に承認/却下の判断記録がある。
- [ ] **3-5. Induction 実行**(既定戦略 `table_to_ontology`)→ Turtle/R2RML 確認 → Validate(HermiT)→ 承認。
- [ ] **3-6. Playground で3層検証**:
  - Tier 1: メトリクス定義(完全な SELECT 文必須。**名前は利用者が実際に打つ語彙に**—日本語同義語 `\b` マッチは効かない)
  - Tier 2: 日本語集計質問 → 生成 SQL を Athena 手書き結果と突き合わせ
  - Tier 3: ドキュメント質問 → 引用元確認
  - Show trace で Tier 判定根拠を確認。0行→リトライで LEFT JOIN に書き換わる「見かけ上正常な NULL 回答」に注意。
  DoD: 3 Tier すべてで期待回答が得られ、trace を確認済み。
- [ ] **3-7. 検証セッション終了時に `stop-coa.sh`**。

### Phase 4: 本命ナレッジシステム構築(目的②③)— 数日規模

設計前提(コードで裏付け済み):
- ドキュメントのみでは Tier 2(NL→SQL)は使えない(`is_mapped` は R2RML 持ち構造化ソース由来のみ)。RAG 代替の本体は Tier 3 GraphRAG。
- 検索リコールの限界は残るため、**既存ベクトル RAG との併存比較を前提**にする。
- namespace 単位でソース・オントロジー・権限が分離。ドメインごとに切る。

- [ ] **4-1. 対象ナレッジ選定**: PDF/DOCX/TXT/MD(1ファイル200MBまで、日本語可)。ドメインごとに namespace 設計。
- [ ] **4-2. 構造化データがあれば Glue 化して同一 namespace に登録**(Tier 2 有効化+テーブル×文書クロス質問対応)。
- [ ] **4-3. ドキュメントソース登録 → GraphRAG KG 構築**(ECS タスク。Neptune: openCypher プロパティグラフ、OpenSearch: `chunk_{ns}` / `topic_{ns}`)。
- [ ] **4-4. 頻出質問をメトリクス化して Tier 1 に固定**(回答の決定性確保)。
- [ ] **4-5. 評価**: RAGAS/RAGChecker 等で、ベクトル RAG ベースラインと Tier 3 を同一質問セット比較。マルチホップ・定義参照質問での差分に注目。
  DoD: 比較レポート(質問セット・スコア・所見)がある。
- [ ] **4-6. MCP 接続(目的③)**:
  - AgentCore Runtime 上の Streamable HTTP(port 8000 固定・`/mcp`)。ツール6種は検証済み: `list_metrics` / `describe_schema` / `query` / `translate_sparql` / `rag_retrieval` / `graph_traversal`。
  - Claude Desktop / Claude Code からは `mcp-proxy` で stdio ブリッジ(`packages/mcp-server/README.md` 手順。uvx / SSM / Secrets Manager / jq)。
  - REST 経由は Cognito **アクセストークン**(ID トークン不可)+ API Gateway 29秒制限。重い質問はストリーミングで。
  - `mode="agentic"` は当面使わない(7.3s→96.7s 劣化・正答率低下の実測あり)。
  DoD: Claude Code から6ツールが呼べ、Tier 1/2/3 相当の質問に回答が返る。

### Phase 5: 運用ルール(常設)

- セッション終了時に必ず `stop-coa.sh`。**1週間以上使わないならフル削除**(アイドルでも ~$10.7/日。再デプロイ 1.5h の方が安い)。削除は ENI 待ち込みで1〜2h を見込む。
- Neptune 7日自動再開への再停止を EventBridge Scheduler で自動化。
- FK 推論・オントロジー proposal は必ず人間レビュー。自動承認運用にしない。
- タグ更新時: `patches/` のパッチ再適用+cdk.json コンテキスト維持を確認。行番号参照は不可(ドリフトする)、シンボルで探す。

---

## 3. コスト構造(検証済み・us-east-1)

| 項目 | $/時 | 削減策 | コード上の根拠 |
|---|---|---|---|
| OpenSearch Serverless | ~0.96 | `aoss_min_ocu: 0`(公式サポート値) | storage-stack.ts:223 |
| Fargate ontology-engine 8vCPU/32GB | 0.466 | app.ts props で `desiredCount: 0` or 縮小 | ontology-stack.ts:110-113 |
| Interface VPC エンドポイント 40 ENI | 0.400 | 削減困難。長期未使用時はフル削除のみ | network-stack.ts(40箇所) |
| Neptune db.r8g.large | ~0.35 | stop-db-cluster(7日自動再開に注意) | storage-stack.ts:118 |
| Fargate vkg | 0.025 | desiredCount 0 | vkg-stack.ts |
| NAT Gateway ×1 | 0.045 | 削減困難 | network-stack.ts:100 |

- 稼働時 ~$2.2/時、アイドル時(停止スクリプト適用後)~$0.45/時 ≒ $10.7/日。
- Bedrock は誤差($0.69/一連の検証)。モデル選定でケチる必要なし。

## 4. トラブルシュート索引

| 症状 | 対処 |
|---|---|
| `SSM parameter /cdk-bootstrap/... not found` | CDK bootstrap 未実施 |
| `ReservedConcurrentExecutions ... below its minimum value of [10]` | Lambda クォータ不足。実効値を確認して申請 |
| `Invalid principal ... role/Admin` | `smus_admin_principal_arns` 未設定 |
| `Domain name already exists` (409) | DataZone 残骸。`delete-domain --skip-deletion-check` |
| `AccessDeniedException: ...claude-sonnet-5 is not available` | SSM `/coa/config` でモデル差し替え |
| 行は返るが結合先が全部 NULL | 誤 FK が R2RML に焼き込み。FK レビューに戻る |
| REST API タイムアウト | API Gateway 29秒制限。Playground/ストリーミングを使う |
| メトリクスの日本語同義語が効かない | Tier 1 `\b` 正規表現の仕様。メトリクス名を利用語彙に寄せる |
| 削除が ENI で止まる | AgentCore ENI 最大8h。`--retain-resources` + 孤児 SG 後始末 |
| ECS クラスタが消せない | `delete-service --force` が必要 |
| `ModuleNotFoundError: mcp.server.fastmcp` | mcp 2.x 混入。`mcp>=1.9.0,<2.0.0` |

## 5. 参考リンク

- リポジトリ: https://github.com/aws/context-ontology-accelerator(v0.1.0 タグを使用)
- 公式ドキュメント: https://aws.github.io/context-ontology-accelerator/
- AWS Japan 解説: https://zenn.dev/aws_japan/articles/context-ontology-accelerator-deploy
- 概念整理: https://blog.serverworks.co.jp/what-is-context-ontology-accelerator
- ローカル検証: https://zenn.dev/mskbhd/articles/lab-225-aws-context-ontology-accelerat
- デプロイ実録+FK 推論+コスト実測: https://zenn.dev/mskbhd/articles/lab-231-aws-coa-deploy-fk-inference
