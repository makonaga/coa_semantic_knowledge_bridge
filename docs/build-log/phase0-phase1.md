# COA セルフホスト構築記録: Phase 0 / Phase 1

実施日: 2026-08-11
実施者: nagakura.makoto
リージョン: **us-west-2**(メイン)+ us-east-1(CloudFront WAF 用、AWS 仕様による固定)
COA バージョン: v0.1.0 タグ(https://github.com/aws/context-ontology-accelerator)
実行環境: Ubuntu Linux(ホスト名 loreley)、AWS アカウント 290918126236

---

## Phase 0: 事前確認 — 結果サマリ

チェックは `scripts/phase0-check.sh` で一括実行(PASS/WARN/FAIL 判定付き)。

### AWS 側(初回から全 PASS)

| 項目 | 結果 |
|---|---|
| 認証プリンシパル | IAM ユーザー `arn:aws:iam::290918126236:user/nagakura.makoto`(root でない)。この ARN を Phase 2 の `smus_admin_principal_arns` に使用 |
| CDK bootstrap | us-west-2(version 29)/ us-east-1(version 27)とも実施済み |
| Lambda 同時実行クォータ | 1000(必要値 110 以上)|
| Bedrock 実呼び出し | 4モデル全て成功: `us.anthropic.claude-sonnet-5` / `us.anthropic.claude-sonnet-4-6` / `us.anthropic.claude-haiku-4-5-20251001-v1:0` / `us.cohere.embed-v4:0` |
| DataZone ドメイン残骸 | なし |
| CloudTrail | 証跡あり(2本)|
| ディスク空き | 1619GB |

**判断メモ**: serve 既定モデルの Sonnet 5 が呼べたため、当初計画にあった
「SSM `/coa/config` でのモデル差し替え(Phase 2-6)」は**不要**と確定。

### ローカルツールチェーン(初回 4 FAIL → 対処して全 PASS)

| ツール | 初回 | 対処 |
|---|---|---|
| Python 3.12 | PASS(3.12.7)| — |
| Node 22+ | FAIL(v18.19.1 = Ubuntu apt 版)| NodeSource で Node 22 に置き換え: `curl -fsSL https://deb.nodesource.com/setup_22.x \| sudo -E bash -` → `sudo apt-get install -y nodejs` |
| pnpm | FAIL | `sudo npm install -g pnpm`(※これが後で Phase 1 のトラブル1を誘発。下記参照)|
| uv | FAIL | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Java 17+ | FAIL | `sudo apt-get install -y openjdk-17-jdk` |
| Docker | PASS(29.6.1、デーモン起動中)| — |

### us-west-2 化に伴う注意(計画からの変更点)

- COA の EdgeWafStack(CloudFront 用 WAF)は `infra/bin/app.ts:404` で **us-east-1 固定**。
  そのため CDK bootstrap は**メインリージョンと us-east-1 の両方**に必要。
- Bedrock のモデル ID はすべて `us.` プレフィックスのクロスリージョン推論プロファイルのため、
  us-west-2 からそのまま利用可能。
- デプロイ時は `AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2` を明示すること
  (preflight スクリプトは環境変数のみを見て、未設定だと us-east-1 にフォールバックする)。

---

## Phase 1: リポジトリ準備とビルド確認 — 結果サマリ

### 実施した手順(最終形)

```bash
cd ~/Desktop/work
git clone --branch v0.1.0 https://github.com/aws/context-ontology-accelerator.git
cd context-ontology-accelerator

# トラブル1対策: npm グローバルをユーザー領域へ
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
echo 'export PATH=$HOME/.npm-global/bin:$PATH' >> ~/.bashrc
export PATH=$HOME/.npm-global/bin:$PATH

# トラブル3対策: hooksPath を明示
git config core.hooksPath .git/hooks

make setup                    # uv sync + pnpm install + Smithy codegen

# トラブル4対策: make lint / make test は使わず nx を直接実行
pnpm nx run-many -t lint      # 12プロジェクト全成功
pnpm nx run-many -t test      # 16タスク全成功(make test の nx 部分と同一)
```

### 結果

- **テスト: 16タスク全成功**(context-manager 2m、infra 2m、ontology-engine 46s ほか)
- **lint: 12プロジェクト全成功**
- AWS 未使用・課金ゼロで完了

---

## トラブルシューティング(Phase 1 で発生した4件)

### トラブル1: `make setup` が pnpm インストールで EACCES

**症状**:
```
npm error code EACCES
npm error Error: EACCES: permission denied, rename '/usr/lib/node_modules/pnpm' -> ...
make: *** [Makefile:4: setup] Error 243
```

**原因**: 2つの要因の組み合わせ。
1. Phase 0 で pnpm を `sudo npm install -g pnpm` で入れたため、グローバル領域
   `/usr/lib/node_modules` が root 所有になっていた。
2. COA の `scripts/setup-dev.sh` は pnpm を **sudo なしで** `npm install -g` する
   (しかも下記トラブル2のバグで、pnpm が既に在っても毎回インストールを試みる)。

**対処**: npm のグローバル先をユーザー領域に切り替える(COA 側の編集不要)。
```bash
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
echo 'export PATH=$HOME/.npm-global/bin:$PATH' >> ~/.bashrc
export PATH=$HOME/.npm-global/bin:$PATH
```

**教訓**: Linux で COA をセットアップする場合、最初から npm prefix をユーザー領域に
しておく(sudo で npm -g を使わない)。

### トラブル2: setup-dev.sh がインストール済みツールを「未インストール」と誤判定

**症状**: `make setup` のたびに「Installing UV...」「Installing pnpm...」が実行される
(uv は導入済みでも再ダウンロードされる)。

**原因**: `scripts/setup-dev.sh` は shebang が `#!/usr/bin/env sh`(Ubuntu では dash)なのに、
bash 専用構文 `&>` で存在チェックをしている:
```sh
if ! command -v pnpm &> /dev/null; then   # dash では「& (バックグラウンド実行)」+「> /dev/null」に分解される
```
dash ではこの条件が常に真になり、必ずインストール分岐に入る。
macOS(bash/zsh)では発生しない、**Linux 固有の COA 側バグ**。

**対処**: uv の再インストールは実害なし(同じ場所に上書き)。pnpm はトラブル1の対処で
解消。スクリプト自体は編集しない(タグ更新時の差分を避けるため)。

### トラブル3: `make setup` が「Installing pre-commit hooks...」で無言のまま Error 1

**症状**:
```
Installing pre-commit hooks...
make: *** [Makefile:4: setup] Error 1
```
(エラーメッセージ表示なし)

**原因**: トラブル2と同じ `&>` バグの3箇所目。`git config --get core.hooksPath` の存在
チェックが dash で常に真となり、hooksPath が未設定の環境では直後の
`HOOKS_PATH=$(git config --get core.hooksPath)` が exit 1 → `set -eu` によりスクリプトが
その場で死ぬ(メッセージが出ないのはこのため)。

**対処**: hooksPath を Git の既定値と同じ場所に明示設定(副作用なし):
```bash
git config core.hooksPath .git/hooks
```
以後 `make setup` は「⚠ Skipping pre-commit install...」の警告を出して正常完了する。
pre-commit フックは COA へコミットする開発者向けの仕組みなので、デプロイ利用では不要。

### トラブル4: `make lint` / `make test` が v0.1.0 タグの梱包不備で失敗

**症状**:
```
error: .../VERSION not found          ← make lint(version-check)
ERROR: file or directory not found: tests/unit   ← make test の最終ステップ
```

**原因**: v0.1.0 タグに `VERSION` ファイルと リポジトリ直下の `tests/` ディレクトリが
含まれていない(main には存在する)のに、Makefile が両方を参照している。
タグの梱包不備であり、環境・コードの問題ではない。ルート package.json も `0.0.0` の
ままタグが切られている。

**対処**: この2つは「バージョン表記の整合」「NOTICE 生成」「ドキュメント整合」を見る
リポジトリ管理用チェックのため、デプロイ利用ではスキップし、実体のチェックを直接実行:
```bash
pnpm nx run-many -t lint    # 本体の lint(12プロジェクト)
pnpm nx run-many -t test    # 本体のテスト(16タスク)
```
※ `scripts/deploy.sh` は VERSION を参照しないことを確認済み。Phase 2 には影響しない。

---

## 次工程(Phase 2)への引き継ぎ事項

1. `infra/cdk.json` の context に設定する値(確定済み):
   `env=dev` / `smus_admin_principal_arns=arn:aws:iam::290918126236:user/nagakura.makoto` /
   `aoss_min_ocu=0` / `aoss_max_ocu=16`
2. Neptune は `db.t4g.medium` への縮小パッチを予定(us-west-2 での提供可否を
   `describe-orderable-db-instance-options` で確認してから適用)。
3. デプロイコマンドは環境変数付きで: `AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 make deploy-dev`
4. serve モデルの SSM 差し替えは不要(Sonnet 5 呼び出し可を確認済み)。
5. デプロイ完走後、ただちに停止/起動スクリプト(`stop-coa.sh` / `start-coa.sh`)を整備する。
