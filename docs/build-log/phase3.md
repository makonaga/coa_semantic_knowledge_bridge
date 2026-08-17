# COA セルフホスト構築記録: Phase 3(テストデータ投入と E2E 検証)

実施日: 2026-08-14
結果: **完了** — Scan → FK レビュー → Induction → 3層検証まで全工程を実施
namespace: `change-mgmt`(ID: <namespace ID>)
※この namespace は 2026-08-15 の Titan 切替時に削除・再作成され、現行 ID は
`<namespace ID>`(経緯は phase4b-titan-switch.md)

---

## 投入したデータ

| ソース | 種別 | 内容 | 最終状態 |
|---|---|---|---|
| `coa_testdata` | Glue Database | change_points(100行・8列)+ models(10行・4列、FK 推論用機種マスタ) | Approved |
| `change-docs` | Documents・S3 | 変化点管理票 Markdown 100文書(`documents/`) | Completed(198チャンク) |
| `policy-docs` | Documents・S3 | 変化点管理規程 1文書(`policy/`、表に無い知識の Tier 3 検証用) | Completed |

- データ生成: `scripts/phase3/prepare_data.py`、Glue 定義: `scripts/phase3/glue/*.json`
- S3: `s3://coa-testdata-<ACCOUNT_ID>/`、Glue DB: `coa_testdata`(Athena で事前検証済み)
- メトリクス: `failed_count`(Trino 方言、完全 SELECT 文、Synonym「不合格件数」、Example 付き)

## パイプライン実施結果

1. **Scan**: カラムコメント(日本語)が DETERMINISTIC として取り込まれ、説明・同義語・タグが自動付与された。
2. **FK レビュー**: AI 推論 FK は期待どおり `change_points.model_name → models.model_name`(AI_INFERRED、confidence 92%)の**1件のみ**。誤推論なし。内容確認のうえ承認。
3. **Induction**: `table_to_ontology` 戦略で proposal 生成 → クラス2(change_points / models)、
   オブジェクトプロパティ1(FK 由来)、データタイププロパティ11。
   **HermiT 検証: 0 error / 0 warning(CONSISTENT・NO_CYCLES・CONNECTED)** → Accept・発行。
4. **文書 KG 構築**: 100文書 → 198チャンクを抽出・埋め込み・Neptune/OpenSearch へ格納(下記トラブル7を経て成功)。

## Playground 3層検証の結果

### Tier 2(日本語→SQL): 7問全て正解

| 質問 | 期待 | 結果 |
|---|---|---|
| 機種ごとの変化点の件数 | 10機種×10件 | ✅ |
| 2024年に発生した不合格 | CP-065/081/094 の3件のみ(2022年の CP-020 を除外) | ✅ 日付フィルタ正確 |
| スチームオーブンレンジの機種の変化点件数 | 50件(**FK 経由 JOIN 必須**) | ✅ 承認 FK が実クエリで機能 |
| EPDM 化の事例と注意点 | クラスタA(CP-011/021/062 ほか) | ✅(Tier 2 で行を返答) |
| マグネトロン不合格事例と対策 | CP-081+対策内容 | ✅(横展開先 CP-091 への言及は無し=Tier 2 の限界) |

### Tier 1(メトリクス): 日本語同義語が機能(記事情報を上書きする発見)

| 入力 | Tier 判定 | 結果 |
|---|---|---|
| `failed_count` | **Tier 1 Match**(name, confidence 1)・confidence 100% | 4 ✅ |
| `不合格件数` | **Tier 1 Match(synonym, confidence 1)** | 4 ✅ |
| `不合格件数を教えてください` | Tier 1 Skipped → Tier 2(80%) | 4 ✅ |

> **発見**: 参考記事の「日本語同義語は `\b` 正規表現のためマッチ不可」は v0.1.0 では**当てはまらない**。
> Synonym への日本語登録で Tier 1 が発火する。ただしマッチは語そのものの入力に限られ、
> 文章に埋め込むと Tier 2 へ落ちる(値は正しいが確定的実行ではなくなる)。

### Tier 3(GraphRAG): 今回の検証ではルーター経由で発火せず(評価は Phase 4 で確定)

- **観測事実**: 表と文書に同内容を入れた本テストデータでは、Standard モードの全質問が Tier 2 で解決された。
  規程文書(表に無い知識)への質問でも、SPARQL→Ontop→SQL 経路で 0行 → SQL 再生成リトライ
  (confidence 18% に減点)となり、Tier 3 には到達しなかった。
- **コード裏取り**(orchestrator.py): Tier 3 は「**Tier 2 が結果を返さなかった場合のフォールバック**」として
  実装されている。今回は Tier 2 が「0行」という*結果*を返したためフォールバック条件を満たさなかった。
  つまり「Tier 3 が動かない」のではなく「**0行でも Tier 2 の成功と扱われ、Tier 3 到達を塞ぐ**」が正確な因果
  (記事の言う“見かけ上正常な NULL/空回答”の実体)。
- **API には `tierOverride` が存在**(tierOverride=3 は常に Tier 3 で解決、とコードに明記)。
  Playground UI に露出していないだけで、REST/MCP からは Tier 3 を明示指定できる。
- **Tier 3 本体(KG 198チャンク)の機能・品質の判断は保留とし、Phase 4 で
  ① MCP `rag_retrieval` の直接呼び出し、② `tierOverride=3` 指定、の2手段で検証して確定する。**
- 副産物として観測できたこと: ①Tier 2 の第2経路(NL→SPARQL→**Ontop/R2RML**→SQL)が実動、
  ②記事が警告していた「0行 → リトライ」挙動の実物、③Cedar 認可・SQL Firewall・confidence の trace 可視性。

## トラブルシューティング

### トラブル7: 文書 KG 構築が Neptune のメモリ不足で失敗

**症状**: `change-docs` が Scan failed。Step Functions → ECS タスク(doc-kg-build)が ExitCode 1。
ログに `MemoryLimitExceededException: Operation terminated (out of memory)`(openCypher 書き込みで多発)。

**原因**: コスト削減で Neptune を **db.t4g.medium(4GB)** に縮小していたため、
graphrag-toolkit の並列書き込みクエリがサーバ側メモリ枯渇。前処理(100ファイル)は成功しており S3/形式は無関係。

**対処**: `aws neptune modify-db-instance --db-instance-class db.r6g.large --apply-immediately`(約10分)
→ ローカルの CDK パッチも db.r6g.large に更新(ドリフト防止)→ Re-scan で成功。

**教訓**: **t4g.medium はアイドル用で、KG 構築を伴う運用の下限は db.r6g.large(16GB)**。
稼働時のみ課金のため差額影響は小さく、停止スクリプト運用は従来どおり有効。

### トラブル8: 完了済み文書ソースの Re-scan ボタンが押せない

**症状**: 追加文書を S3 に置いた後、`change-docs`(Completed)の Re-scan がグレーアウト。

**対処**: 追加文書を別プレフィックス(`policy/`)へ `aws s3 mv` し、**小さな新規ソース(`policy-docs`)として登録**。
1文書のみの取り込みで数分で完了。既存ソースにも影響なし。

### トラブル9(小): メトリクス登録の2つの制約

1. **Name は英数字+アンダースコアのみ**(日本語名は登録不可)→ 英語名+Synonym に日本語を登録する運用が正解。
2. **SQL Expression は完全な SELECT 文が必須**(フォームのプレースホルダーは断片例だが、バリデーションで拒否される)。
   例: `SELECT COUNT(CASE WHEN evaluation_result LIKE '不合格%' THEN 1 END) AS failed_count FROM coa_testdata.change_points`

## 運用ノウハウまとめ(Phase 4 以降に効くもの)

- Glue テーブルには**日本語カラムコメントを必ず付ける**(DETERMINISTIC エンリッチになり AI 推測を減らせる)。
- FK 承認前に Athena で参照整合性を実値確認する(今回は合成データのため既知)。
- 頻出質問は Tier 1 メトリクス化し、**Synonym に日本語の呼び名を登録**する。利用者には「その語だけを入力」する使い方を案内。
- 文書にしか無い知識(規程・ノウハウ)を活かすには、Standard ルーター任せにせず **MCP の `rag_retrieval` / `graph_traversal` を明示的に使う**設計にする(Phase 4)。

## 次工程(Phase 4)への引き継ぎ

1. MCP 接続(mcp-proxy 経由で Claude Code から6ツール)→ **`rag_retrieval` 直接呼び出しで Tier 3 を検証**(質問例: 「条件付き合格の変化点はその後どう扱うか」→ POLICY-001 引用を期待)。
2. 検証セッション終了時は `scripts/ops/stop-coa.sh`(Neptune r6g.large 化で稼働単価が上がったため停止の重要性増)。
3. 8/21 頃に Neptune 自動再開 → 未使用なら再停止。
