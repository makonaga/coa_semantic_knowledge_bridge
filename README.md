# COA Self-Host on AWS(オントロジー+GraphRAG ナレッジ基盤)

AWS [Context Ontology Accelerator(COA)](https://github.com/aws/context-ontology-accelerator) v0.1.0 を
自分の AWS アカウント(オレゴンまたは東京リージョン)にセルフホストし、
RAG(ベクター検索)を置き換える「オントロジー+GraphRAG」ナレッジ基盤として、
Web UI・REST API・MCP(エージェント連携)の3経路から利用できるようにするためのガイドとサンプル一式です。

## プロジェクト概要

通常の RAG は「文書を割って埋め込み、似た断片を返す」仕組みのため、集計・結合を要する質問や
「どのデータを見てよいか」の統制が苦手です。COA は、人間が承認したオントロジー
(テーブル・カラム・外部キー・用語の知識)を土台に、質問を3層カスケード
(①メトリクス完全一致 → ②自然言語→SQL → ③GraphRAG)で解決します。
確定値は SQL で正確に返り、利用者ごとの行・列レベルのアクセス制御も効きます。

本リポジトリは、COA v0.1.0 の実構築(全16スタック、テストデータ投入、3層の回答検証、
MCP 6ツール接続)を完走した実測記録に基づき、**コピー&ペーストで再現できる導入手順**として
整理したものです。構築過程で発見した COA 本体のバグ(us-east-1 以外で MCP 実行系が
全滅するリージョンバグ)への修正パッチ、コスト削減パッチ、埋め込みモデルの
コンプライアンス切り替え(Cohere → Amazon Titan)手順を含みます。

## アーキテクチャ概要

CDK スタック16個(メインリージョン15個+us-east-1 に CloudFront 用 WAF)で構成されます。
入口は CloudFront + S3 の Web UI と AgentCore Runtime の HTTPS エンドポイント(API/MCP)、
認証は Cognito(外部 IdP のフェデレーション対応)、知識ストアは Neptune(ナレッジグラフ)+
OpenSearch Serverless(ベクター)+ Glue/Athena(構造化データ)+ DynamoDB(メタデータ・権限)、
推論は Bedrock(Claude 系 + 埋め込みモデル)です。
詳細は **[install_guide/guide_00_overview.md](install_guide/guide_00_overview.md)** を参照してください。

## 前提条件

- AWS アカウント(管理者相当の IAM ユーザー/ロール。ルートユーザー不可)
- Bedrock で Claude 系モデルと埋め込みモデルのモデルアクセスを有効化できること
- ローカル環境: Python 3.12 / Node.js 22+ / pnpm / uv / Java 17+ / Docker
- 目安コスト(オレゴン実測): フル稼働 約$1.9/時、停止運用時 約$0.44/時($10.6/日)

## クイックスタート

新規に構築する場合は **[install_guide/guide_00_overview.md](install_guide/guide_00_overview.md)** から
順に読み進めてください。ガイド01(事前チェック)→ ガイド02(デプロイ)→ ガイド03(コスト運用)→
ガイド04(ナレッジ構築)で、サンプルナレッジへの質問応答まで到達します。

構築済みの COA にプログラムからアクセスしたいだけの場合は
**[install_guide/guide_05_api_and_mcp.md](install_guide/guide_05_api_and_mcp.md)** と
`notebooks/coa_query_sample.ipynb` を参照してください。

## ディレクトリ構成

```
install_guide/     導入手順(00〜07。ここから読む)
scripts/           環境チェック・停止/起動・データ準備・MCP 検証クライアント
notebooks/         API アクセスの Jupyter Notebook サンプル
datasets/          検証用の合成データセット(変化点管理票100件+機種マスタ+規程文書)
docs/build-log/    実構築の記録(トラブルシューティングの経緯と実測値)
docs/              構築前の検証済み作業計画(記録)
```

## ガイド一覧

| ガイド | 内容 |
|---|---|
| [guide_00_overview](install_guide/guide_00_overview.md) | 全体像、アーキテクチャ、リージョン選択(オレゴン/東京)、コスト概要 |
| [guide_01_prerequisites](install_guide/guide_01_prerequisites.md) | ツールチェーン、AWS 側チェック、東京リージョンの事前確認(モデル提供状況) |
| [guide_02_deployment](install_guide/guide_02_deployment.md) | COA 取得、必須パッチ4種、CDK デプロイ、管理ユーザー作成 |
| [guide_03_cost_operation](install_guide/guide_03_cost_operation.md) | 停止/起動スクリプト、予算アラート、コスト実測 |
| [guide_04_knowledge_onboarding](install_guide/guide_04_knowledge_onboarding.md) | データ投入、Scan → FK 承認 → オントロジー生成 → メトリクス登録 |
| [guide_05_api_and_mcp](install_guide/guide_05_api_and_mcp.md) | 必要な ID・URL の確認方法、トークン取得、MCP、Notebook |
| [guide_06_application_integration](install_guide/guide_06_application_integration.md) | 認証・認可の仕組みと本番アプリの認証パターン(IdP フェデレーション) |
| [guide_07_troubleshooting](install_guide/guide_07_troubleshooting.md) | 実際に遭遇した全18事象の症状・原因・対処 |

## 重要な注意事項

**認証はナレッジ開発用ではなく、API の認可基盤そのものです。** COA の API は JWT 必須で、
検証済みトークンの身元から利用者ごとの見せてよいテーブル・列を強制します。
アプリケーションに組み込む際も「認証を外す」のではなく「トークンの取り方を自動化する」
のが正解です(リフレッシュトークンによる自動更新、社内 IdP のフェデレーション)。
詳細は [ガイド06](install_guide/guide_06_application_integration.md) を参照してください。
なお本ガイドの検証で使う `USER_PASSWORD_AUTH` は開発環境(env=dev)のみで有効です。

**コストは停止運用が前提です。** アイドルでも約 $10.6/日かかります。作業終了時の
`scripts/ops/stop-coa.sh` を習慣化し、Neptune が停止から7日で自動再開される仕様に
注意してください。1週間以上使わない場合はフル削除(再デプロイ62分)を推奨します。

**埋め込みモデルは選択制です。** COA の既定はサードパーティの Cohere Embed v4 です。
組織のポリシーで利用できない場合は、Amazon Titan Text Embeddings V2 への切り替えパッチ
([ガイド02 ステップ4-3](install_guide/guide_02_deployment.md))を適用してください。
検索精度が同等以上であることを実測で確認済みです。

**データセットはすべて架空の合成データです。** 機種名は実在する電子レンジの型番を
識別子として借用していますが、変更内容・評価内容はすべて創作であり、実際の製品開発・
品質情報とは一切関係ありません(`datasets/change-point-management/README.md`)。

## サポートとコントリビューション

手順の誤り・改善提案は Issue / Pull Request で歓迎します。特に、東京リージョンでの
構築実績(モデル ID の組み合わせ、遭遇した差分)の報告は歓迎です。

## ライセンスと参照

- COA 本体: [aws/context-ontology-accelerator](https://github.com/aws/context-ontology-accelerator)(Apache-2.0)
- 本リポジトリのガイド・スクリプトは COA v0.1.0 タグを対象に検証しています。
  COA のタグを更新した場合、ローカルパッチ([ガイド02 ステップ4](install_guide/guide_02_deployment.md))の
  再適用が必要です

## バージョン履歴

### v1.0.0(2026-08-17)

- 初版公開
- COA v0.1.0 の実構築(オレゴン)に基づく導入ガイド 00〜07
- リージョンバグ修正パッチ / Neptune 縮小パッチ / Titan 切り替えパッチ
- 検証用合成データセット(変化点管理票100件+機種マスタ+規程文書)と投入手順
- MCP 検証クライアントと Jupyter Notebook サンプル(設定値の自動発見つき)
