# ガイド04: ナレッジ構築(データ投入と Web UI オンボーディング)

サンプルデータ(家電メーカーの「変化点管理票」を模した合成データ100件)を投入し、
Web UI で Scan → FK 承認 → オントロジー生成 → メトリクス登録までを行います。
自前のデータを投入する場合も流れは同じです(ステップ1〜2 を自データに置き換え)。

このガイドの Web UI 操作は、2回の実構築で検証済みの手順のみを記載しています。

## 前提

- **COA が起動中であること**(`bash scripts/ops/start-coa.sh` → Neptune が `available`)。
  スキャン・取り込み・削除などのパイプライン操作は**停止中は必ず失敗します**([トラブル12](guide_07_troubleshooting.md))
- Web UI の URL とログイン([ガイド02 ステップ8〜10](guide_02_deployment.md))
- 変数(各ターミナルで):

```bash
export COA_REGION=us-west-2        # 東京の場合: ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## ステップ1: サンプルデータの生成と S3 アップロード

`datasets/change-point-management/` の合成データ(変化点管理票100件+機種マスタ10件)から、
Glue テーブル用 CSV と Tier 3 検証用の文書 Markdown 100件を生成し、S3 に配置します:

```bash
cd ~/work/coa_semantic_knowledge_bridge
export DATA_BUCKET=coa-testdata-$ACCOUNT_ID    # バケット名は任意(グローバル一意)

python3 scripts/phase3/prepare_data.py         # build/phase3/ に CSV と文書を生成
aws s3 mb s3://$DATA_BUCKET --region $COA_REGION
aws s3 sync build/phase3/glue/      s3://$DATA_BUCKET/glue/
aws s3 sync build/phase3/documents/ s3://$DATA_BUCKET/documents/
aws s3 cp "datasets/change-point-management/policy/POLICY-001_変化点管理規程.md" s3://$DATA_BUCKET/policy/
aws s3 ls s3://$DATA_BUCKET/documents/ | wc -l   # 100 なら OK
```

> `policy/` の規程文書は「**表に存在しない知識**」の代表例です(評価結果ごとの事後対応ルール)。
> 変化点管理票とは別プレフィックスに置き、Tier 3(文書検索)が構造化データと独立に
> 機能することの検証に使います([ガイド05](guide_05_api_and_mcp.md) のサンプル質問が参照)。

## ステップ2: Glue テーブルの作成と Athena 検証

テーブル定義テンプレート(日本語カラムコメント付き)のバケット名を差し込んで登録します:

```bash
aws glue create-database --region $COA_REGION \
  --database-input '{"Name":"coa_testdata","Description":"COA 検証用合成データ"}'

mkdir -p build/phase3/glue-defs
for t in change_points models; do
  sed "s/__DATA_BUCKET__/$DATA_BUCKET/" scripts/phase3/glue/${t}-table.json \
    > build/phase3/glue-defs/${t}-table.json
  aws glue create-table --database-name coa_testdata --region $COA_REGION \
    --table-input file://build/phase3/glue-defs/${t}-table.json
done
```

Athena で読めることを確認します(COA も同じ経路でクエリします):

```bash
QID=$(aws athena start-query-execution --region $COA_REGION \
  --query-string "SELECT count(*) AS change_points FROM coa_testdata.change_points" \
  --result-configuration OutputLocation=s3://$DATA_BUCKET/athena-results/ \
  --query QueryExecutionId --output text)
sleep 5
aws athena get-query-results --query-execution-id $QID --region $COA_REGION \
  --query 'ResultSet.Rows[1].Data[0].VarCharValue' --output text   # 100 なら OK
```

> まだ実行中(`QUERY_STATE: RUNNING` エラー)の場合は数秒待って
> `get-query-results` の行だけ再実行してください。

> **日本語カラムコメントは必ず付けてください**(自データの場合も)。コメントは Scan 時に
> DETERMINISTIC なエンリッチとして取り込まれ、AI の推測よりも優先されるため、
> Tier 2 の SQL 生成精度が上がります。

## ステップ3: namespace の作成(Web UI)

1. Web UI → Administration → Namespaces → **Create namespace** → 名前を入力(英数字とハイフン推奨)
2. 作成後、右上の Namespace セレクタが対象になっていることを確認
3. **ブラウザ URL の `namespaces/` の直後に出る namespace ID を控える**
   (API・MCP 利用時に必要。CLI での確認方法は [ガイド05](guide_05_api_and_mcp.md))

### (作り直しの場合)既存 namespace の削除

1. 対象を選択 → **Change status → ARCHIVED**(ACTIVE のままでは削除できない。2段階遷移が仕様)
2. ARCHIVED になったら選択して **Delete**
3. 実測30秒程度で完了するが、**UI 表示が DELETING のまま残ることがある → ページ再読み込み(F5)で確認**
4. DELETE_FAILED になった場合: **Neptune が起動しているかを確認**してから再度 Delete(リトライは正式サポート)

## ステップ4: Glue ソースの登録(Web UI)

1. Scan → Sources → **Connect source** → 種別 **AWS Glue**
2. 入力: Source name(任意)/ Catalog ID = アカウントID / Region / Database name = `coa_testdata`
   - **Region は正確に入力すること(`us-west-2` や `ap-northeast-1`)。** タイプミスすると
     `Could not connect to the endpoint URL: "https://glue.【誤入力】.amazonaws.com/"` で
     Scan failed になります([トラブル14](guide_07_troubleshooting.md))
3. Step 3(Configure enrichment)は既定のまま(AI エンリッチと FK 推論が有効)
4. Review and connect → 接続。スキャン完了(Pending review)まで Refresh で待つ(数分)

## ステップ5: FK レビューとテーブル承認(最重要の人間工程)

1. ソースを開き、各テーブルの詳細を開く
2. **Keys & relationships** で AI 推論の PK / FK を確認:
   - FK は「どのカラム → どの参照先か」「confidence」「AI_INFERRED か」を必ず目視
   - サンプルデータでは `change_points.model_name → models.model_name` の1件のみが正解
   - 実データでは承認前に Athena で参照整合性を実値確認する(誤承認は「エラーなしで NULL」を生む)
3. 問題なければ画面右上の **「Approve table & all columns」で一括承認**
   (テーブル+全カラム+キーが1クリックで承認される。カラム個別選択より速い)
4. 全テーブル承認後、ソース画面右上の **Approve source** → Status が Approved になる

## ステップ6: 文書ソースの登録(Web UI)

1. Connect source → 種別 **Documents** → **「S3 bucket」タブ**を選択(Upload files ではない方)
2. 入力:
   - Name: 任意
   - **Source bucket ARN**: `arn:aws:s3:::` に続けてバケット名(`echo arn:aws:s3:::$DATA_BUCKET` の出力)
   - S3 prefixes: `documents/`(確定しない場合は「+ Add prefix」を先に押す)
   - Cross-account access / Advanced options は既定のまま
3. Connect で登録 → 取り込み開始(前処理 → エンティティ抽出 → 埋め込み → グラフ格納)
   - 実測: 100文書(Titan 埋め込み)で約7分。放置でよい
4. 同じ手順で**規程文書のソースも登録**します(Name: 任意 / prefix: `policy/`)。
   複数ソースは**前のソースの完了を待たず連続登録してよい**
5. 完了確認: 両ソースとも Status = Completed、詳細の Ingestion Statistics で
   Documents Processed / Text Chunks Embeddings / **Errored = 0** を確認

> 完了済み文書ソースの Re-scan ボタンは押せません。文書を追加する場合は、別プレフィックスに
> 置いて**新規ソースとして登録**します([トラブル8](guide_07_troubleshooting.md))。

## ステップ7: Induction(オントロジー生成、Web UI)

Glue ソース承認後ならいつでも実行できます(文書取り込みの完了を待つ必要なし)。

1. Ontology → Induction → **Start induction**
2. ダイアログ: Strategy `Table to Ontology`(既定)/ **Data sources で対象ソースを選択(必須)** /
   Grounding ontologies は初回は空
3. 数分後、proposal を開いて内容確認(この詳細画面がそのまま確認画面):
   Summary の Novel classes 数、Proposal graph のクラスとリレーション、
   Proposed classes の Relationships / Attributes 数がテーブル構成と整合するか
4. **Validate** をクリック → 緑の「Validation passed(0 error / CONSISTENT / NO_CYCLES / CONNECTED)」
   バナーを確認(HermiT 推論器による論理整合性チェック)
5. **Accept proposal** → Accepted バナー(Merged into ontology ...)で発行完了

## ステップ8: メトリクス登録(Tier 1、Web UI)

頻出の集計質問は Tier 1 メトリクスにすると、LLM に SQL を書かせず確定的に回答できます。
Ontology → Metrics → **Create metric**。フォームには判明している制約が多いので注意:

| 項目 | 注意点 |
|---|---|
| Name | **英数字とアンダースコアのみ**(日本語不可)。日本語名は Synonym に登録する |
| **Description** | **必須**(未入力だと「Description is required」で作成できない) |
| Data source | 登録済みソースを選択。**namespace 作成直後は候補が空のことがある → ページ再読み込み(F5)で解消** |
| Dialect | Athena は **Trino** を選択 |
| SQL Expression | **完全な SELECT 文が必須**(断片はバリデーションで拒否される)。テーブルは `db名.テーブル名` で修飾 |
| Synonyms | **単語だけ**を入力して Add(文章を貼らない)。日本語同義語は Tier 1 マッチに有効(実証済み) |
| Examples | 「Add example」を押してから質問文を入力 |

サンプルデータでの登録例:

- Name: `failed_count` / Description: 不合格となった変化点の件数 / Dialect: Trino
- Expression: `SELECT COUNT(CASE WHEN evaluation_result LIKE '不合格%' THEN 1 END) AS failed_count FROM coa_testdata.change_points`
- Synonym: `不合格件数`

**タイムアウトに注意**: 作成時に「Endpoint request timed out」(API Gateway の29秒制限)が出ても
**サーバー側では作成が完了していることがあります**。再クリックの前に Metrics 一覧を確認し、
既に存在する場合は Edit で内容を確認・修正してください。

## ステップ9: Playground での動作確認

| 確認 | 入力 | 期待結果 |
|---|---|---|
| Tier 1 | メトリクスの Synonym を**その語だけ**入力(例: `不合格件数`) | Rationale に「Tier 1 — Metric Match」、SQL 生成なしで値が返る |
| Tier 2 | 集計質問(例: `機種ごとの変化点の件数を教えてください`) | SQL が生成され、承認済み FK 経由の JOIN も動作 |
| Tier 2(日付) | `2024年に発生した不合格の変化点を教えてください` | 日付フィルタが正しく効く |

> Tier 1 は語を文章に埋め込むと Tier 2 に落ちます(値は正しいが確定的実行ではなくなる)。
> 利用者には「メトリクス名・同義語はその語だけを入力する」使い方を案内してください。
>
> 文書にしか無い知識(規程・ノウハウ)への質問は、Playground の標準ルーターでは
> Tier 3 に到達しないことがあります(Tier 2 の「0行」も成功と扱われる仕様)。
> Tier 3 の検索は API / MCP から明示的に呼び出します([ガイド05](guide_05_api_and_mcp.md))。

## 完了チェックリスト

- [ ] Glue ソース = Approved(FK レビュー実施済み)
- [ ] 文書ソース = Completed(Errored 0)
- [ ] Induction proposal = Accepted(Validation passed を確認済み)
- [ ] メトリクス登録済み(Playground で Tier 1 発火を確認)
- [ ] namespace ID を控えた
- [ ] 作業終了時は `bash scripts/ops/stop-coa.sh`

次: [ガイド05: API と MCP](guide_05_api_and_mcp.md)
