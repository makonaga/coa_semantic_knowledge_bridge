# COA namespace 構築手順書(Web UI)

最終更新: 2026-08-16(Titan 再構築時に判明した UI 差分・注意点を反映した確定版)
Web UI: https://dd7zlztjwxgl1.cloudfront.net

namespace の新規構築(および作り直し)の標準手順。2回の実構築(Phase 3 / Titan 再構築)で
検証済みの操作のみを記載する。

## 前提条件

- **COA が起動中であること**(`bash scripts/ops/start-coa.sh` → Neptune が `available`)。
  スキャン・取り込み・削除などのパイプライン操作は**停止中は必ず失敗する**(トラブル12)。
- 構造化データは Glue テーブル化済み(Athena からクエリ可能)であること。
- 文書は S3 のプレフィックス配下に配置済みであること。

## 0. (作り直しの場合)既存 namespace の削除

1. Administration → Namespaces → 対象を選択
2. **Change status → ARCHIVED**(ACTIVE のままでは削除できない。2段階遷移が仕様)
3. ステータスが ARCHIVED になったら、選択して **Delete**
4. DELETING → 一覧から消えるまで待つ(実測30秒程度で完了するが、**UI 表示が更新されず
   DELETING のまま見えることがある → ページ再読み込み(F5)で確認**)
5. DELETE_FAILED になった場合: Neptune が起動しているか確認してから再度 Delete(リトライは正式サポート)

## 1. namespace 作成

1. Administration → Namespaces → **Create namespace** → 名前入力(英数字とハイフン推奨)
2. 作成後、右上の Namespace セレクタが対象になっていることを確認
3. **ブラウザ URL の `namespaces/` の直後に出る namespace ID を控える**(MCP 利用時に必要。
   Induction の Accept バナーの URI にも表示される)

## 2. Glue ソースの登録

1. Scan → Sources → **Connect source** → 種別 **AWS Glue**
2. 入力: Source name / Catalog ID(アカウントID)/ Region / Database name
   - **Region は正確に入力すること(例: `us-west-2`)。** タイプミスすると
     `Could not connect to the endpoint URL: "https://glue.<誤入力>.amazonaws.com/"` で
     Scan failed になる(トラブル14)。エラーメッセージ中の URL を見れば入力ミスと分かる
3. Step 3(Configure enrichment)は既定のまま(AI エンリッチと FK 推論が有効)
4. Review and connect → 接続。スキャン完了(Pending review)まで Refresh で待つ

## 3. FK レビューとテーブル承認(最重要の人間工程)

1. ソースを開き、各テーブルの詳細を開く
2. **Keys & relationships** で AI 推論の PK / FK を確認:
   - FK は「どのカラム → どの参照先か」「confidence」「AI_INFERRED か」を必ず目視
   - 実データでは承認前に Athena で参照整合性を実値確認する(誤承認は「エラーなしで NULL」を生む)
3. 問題なければ画面右上の **「Approve table & all columns」で一括承認**
   (テーブル+全カラム+キーが1クリックで承認される。カラム個別選択より速い)
4. 全テーブルを承認後、ソース画面右上の **Approve source** → Status が Approved になる

## 4. 文書ソースの登録

1. Connect source → 種別 **Documents** → **「S3 bucket」タブ**を選択(Upload files ではない方)
2. 入力:
   - Name: 任意
   - **Source bucket ARN**: `arn:aws:s3:::<バケット名>` 形式(バケット名だけでは不可)
   - S3 prefixes: プレフィックスを入力(確定しない場合は「+ Add prefix」を先に押す)
   - Cross-account access / Advanced options は既定のまま
3. Connect で登録 → 取り込み開始(前処理 → エンティティ抽出 → 埋め込み → グラフ格納)
   - 複数ソースは**完了を待たず連続登録してよい**
   - 実測: 100文書(Titan 埋め込み)で約7分。放置でよい
4. 完了確認: Status = Completed、詳細の Ingestion Statistics で
   Documents Processed / Text Chunks Embeddings / Errored=0 を確認

## 5. Induction(オントロジー生成)

Glue ソース承認後ならいつでも実行可(文書取り込みの完了を待つ必要なし)。

1. Ontology → Induction → **Start induction**
2. ダイアログ: Strategy `Table to Ontology`(既定)/ **Data sources で対象ソースを選択(必須)** /
   Grounding ontologies は初回は空
3. 数分後、proposal を開いて内容確認(この詳細画面がそのまま確認画面):
   - Summary の Novel classes 数、Proposal graph のクラスとリレーション、
     Proposed classes の Relationships / Attributes 数がテーブル構成と整合するか
4. **Validate** をクリック → 緑の「Validation passed(0 error / CONSISTENT / NO_CYCLES / CONNECTED)」
   バナーを確認(HermiT による論理整合性チェック)
5. **Accept proposal** → Accepted バナー(Merged into ontology ...)で発行完了

## 6. メトリクス登録(Tier 1)

Ontology → Metrics → **Create metric**。判明している制約が多いので注意:

| 項目 | 注意点 |
|---|---|
| Name | **英数字とアンダースコアのみ**(日本語不可)。日本語名は Synonym に登録する |
| **Description** | **必須**(未入力だと「Description is required」で作成できない)|
| Data source | ドロップダウンから登録済みソースを選択。**namespace 作成直後は候補が空のことがある → ページ再読み込み(F5)で解消** |
| Dialect | Athena は **Trino** を選択 |
| SQL Expression | **完全な SELECT 文が必須**(プレースホルダーは式の例だが、断片はバリデーションで拒否される)。テーブルは `db名.テーブル名` で修飾 |
| Synonyms | **単語だけ**を入力して Add(文章を貼らない)。日本語同義語は Tier 1 マッチに有効(実証済み)|
| Examples | 「Add example」を押してから質問文を入力 |

**タイムアウトに注意**: 作成時に「Endpoint request timed out」(API Gateway 29秒制限)が出ても
**サーバー側では作成が完了していることがある**。再クリックの前に Metrics 一覧を確認し、
既に存在する場合は開いて内容を確認・必要なら Edit で修正する(重複作成エラーで気づくパターンもある)。

登録後の動作確認: Playground でメトリクス名(または日本語 Synonym)を**その語だけ**入力 →
Rationale の「Tier 1 — Metric Match」が発火し、SQL 生成なしで値が返ればOK。
(語を文章に埋め込むと Tier 2 に落ちる — 値は正しいが確定的実行ではなくなる)

## 7. 完了チェックリスト

- [ ] Glue ソース = Approved(FK レビュー実施済み)
- [ ] 文書ソース = Completed(Errored 0)
- [ ] Induction proposal = Accepted(Validation passed を確認済み)
- [ ] メトリクス登録済み(Playground で Tier 1 発火を確認)
- [ ] namespace ID を控えた(MCP 利用時: `export NAMESPACE_ID=<ID>`。
      `scripts/mcp/coa_mcp_client.py` の既定値も必要に応じて更新)
- [ ] 作業終了時は `bash scripts/ops/stop-coa.sh`

## 関連文書

- 初回構築の記録と評価結果: `docs/build-log/phase3.md`
- 再構築(Titan 切替)の記録: `docs/build-log/phase4b-titan-switch.md`
- MCP 接続手順: `docs/build-log/phase4.md`
- コスト監視: `docs/ops/cost-monitoring.md`
