#!/usr/bin/env bash
# COA デプロイ前の環境チェック(install_guide/guide_01_prerequisites.md ステップ5)
#
# 使い方:
#   COA_REGION=us-west-2 bash scripts/phase0-check.sh
#   (COA_REGION 未設定時は us-west-2。東京の場合は ap-northeast-1 を指定。
#    事前に aws configure で認証設定済みであること)
#
# チェック対象の Bedrock モデルは環境変数で差し替え可能(東京など us. プロファイル圏外向け):
#   COA_CHAT_MODELS="ID1 ID2 ..."   スペース区切りの Claude 系モデル/プロファイル ID
#   COA_EMBED_MODEL="モデルID"      埋め込みモデル ID(Titan 系は 1024 次元で疎通確認)
#
# 注意: COA の CloudFront 用 WAF スタック(EdgeWafStack)は AWS の仕様上
# 必ず us-east-1 に作られる(infra/bin/app.ts:404)。そのため CDK bootstrap は
# メインリージョンと us-east-1 の両方で必要。
#
# 各チェックは PASS / WARN / FAIL を表示する。FAIL が残った状態で
# Phase 2 (make deploy-dev) に進んではいけない。

set -uo pipefail

REGION="${COA_REGION:-us-west-2}"
WAF_REGION="us-east-1"
PASS=0; WARN=0; FAIL=0

ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
ng()   { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== Phase 0 環境チェック (region: $REGION) ==="

# ---------------------------------------------------------------------------
echo
echo "--- 0-1. AWS 認証とデプロイ実行者の確認 ---"
if ! command -v aws >/dev/null 2>&1; then
  ng "AWS CLI が見つからない。v2 をインストールすること"
  echo "チェックを継続できないため終了します。"
  exit 1
fi

CALLER_JSON=$(aws sts get-caller-identity --output json 2>&1) || {
  ng "認証情報が無効: $CALLER_JSON"
  exit 1
}
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -o '"Account": *"[0-9]*"' | grep -o '[0-9]*')
CALLER_ARN=$(echo "$CALLER_JSON" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
echo "  Account: $ACCOUNT_ID"
echo "  Caller : $CALLER_ARN"
case "$CALLER_ARN" in
  *:root) ng "ルートユーザーで実行している。IAM ユーザー/ロール(MFA 付き)に切り替えること" ;;
  *)      ok "IAM プリンシパルで実行中" ;;
esac
echo "  メモ: この ARN(または assumed-role の元ロール ARN)を Phase 2 の"
echo "        smus_admin_principal_arns に設定する(user/role の ARN のみ有効)。"

# ---------------------------------------------------------------------------
echo
echo "--- 0-2. CDK bootstrap 確認(メイン: $REGION / CloudFront WAF 用: $WAF_REGION)---"
BOOTSTRAP_REGIONS="$REGION"
[ "$REGION" != "$WAF_REGION" ] && BOOTSTRAP_REGIONS="$REGION $WAF_REGION"
for R in $BOOTSTRAP_REGIONS; do
  if VER=$(aws ssm get-parameter --name /cdk-bootstrap/hnb659fds/version \
             --region "$R" --query Parameter.Value --output text 2>/dev/null); then
    ok "CDK bootstrap 済み ($R, version: $VER)"
  else
    ng "CDK bootstrap 未実施 ($R)。対処: npx cdk bootstrap aws://$ACCOUNT_ID/$R (Node 22+ が必要)"
  fi
done

# ---------------------------------------------------------------------------
echo
echo "--- 0-3. Lambda 同時実行クォータ(実効値)---"
CONC=$(aws lambda get-account-settings --region "$REGION" \
         --query AccountLimit.ConcurrentExecutions --output text 2>/dev/null || echo 0)
echo "  ConcurrentExecutions: $CONC"
# COA は reservedConcurrentExecutions:5 を2箇所で使う。予約後もアカウントに
# 非予約枠 100 が必須のため、110 未満ではデプロイが失敗する。
if [ "$CONC" -ge 110 ] 2>/dev/null; then
  ok "クォータ十分 (>= 110)"
else
  ng "クォータ不足。引き上げ申請: aws service-quotas request-service-quota-increase \
--service-code lambda --quota-code L-B99A9384 --desired-value 1000 --region $REGION"
  echo "  注意: 申請クローズ後も実効値反映にラグあり。本スクリプトの再実行で実効値を確認すること。"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 0-4. Bedrock モデル実呼び出しテスト ---"
# COA が実際に参照するモデル ID(v0.1.0 の既定。COA_CHAT_MODELS で差し替え可)
#   serve 既定 LLM         : us.anthropic.claude-sonnet-5
#   ontology-engine LLM    : us.anthropic.claude-sonnet-4-6
#   rerank/抽出用          : us.anthropic.claude-haiku-4-5-20251001-v1:0
#   埋め込み               : amazon.titan-embed-text-v2:0(ガイド02 ステップ4-3 の Titan 切替前提。
#                            Cohere のまま使う場合は COA_EMBED_MODEL=us.cohere.embed-v4:0)
CHAT_MODELS="${COA_CHAT_MODELS:-us.anthropic.claude-sonnet-5 us.anthropic.claude-sonnet-4-6 us.anthropic.claude-haiku-4-5-20251001-v1:0}"
for MODEL in $CHAT_MODELS
do
  ERR=$(aws bedrock-runtime converse --region "$REGION" --model-id "$MODEL" \
          --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
          --inference-config '{"maxTokens":10}' \
          --query 'output.message.content[0].text' --output text 2>&1 >/dev/null) \
    && ok "converse OK: $MODEL" \
    || {
         if [ "$MODEL" = "us.anthropic.claude-sonnet-5" ]; then
           # serve のモデルは SSM /coa/config で 4-6 に差し替え可能なので WARN 扱い
           warn "呼び出し不可: $MODEL — Phase 2-6 で /coa/config を sonnet-4-6 に差し替えること ($(echo "$ERR" | head -1))"
         else
           ng "呼び出し不可: $MODEL — Bedrock コンソールでモデルアクセスを有効化すること ($(echo "$ERR" | head -1))"
         fi
       }
done

# Titan の本文形式は実構築で検証済み。Cohere の本文形式は COA v0.1.0 の
# libs/common/src/coa_common/embeddings.py のリクエスト定義に合わせたもの(実呼び出しは未検証)
EMBED_MODEL="${COA_EMBED_MODEL:-amazon.titan-embed-text-v2:0}"
case "$EMBED_MODEL" in
  *titan*)  EMBED_BODY='{"inputText":"ping","dimensions":1024,"normalize":true}' ;;
  *cohere*) EMBED_BODY='{"texts":["ping"],"input_type":"search_query","output_dimension":1024,"embedding_types":["float"]}' ;;
  *)        EMBED_BODY='{"inputText":"ping"}' ;;
esac
EMBED_OUT=$(mktemp)
ERR=$(aws bedrock-runtime invoke-model --region "$REGION" \
        --model-id "$EMBED_MODEL" \
        --cli-binary-format raw-in-base64-out \
        --body "$EMBED_BODY" \
        "$EMBED_OUT" 2>&1 >/dev/null) \
  && ok "embed OK: $EMBED_MODEL" \
  || ng "呼び出し不可: $EMBED_MODEL ($(echo "$ERR" | head -1))"
rm -f "$EMBED_OUT"

# ---------------------------------------------------------------------------
echo
echo "--- 0-5. ローカルツールチェーン ---"
check_ver() { # $1=表示名 $2=コマンド $3=判定grep(拡張正規表現)
  local out
  if out=$(eval "$2" 2>&1); then
    if echo "$out" | grep -qE "$3"; then
      ok "$1: $(echo "$out" | head -1)"
    else
      ng "$1: バージョン不適合 → $(echo "$out" | head -1)"
    fi
  else
    ng "$1: 未インストール"
  fi
}
check_ver "Python 3.12" "python3.12 --version || python3 --version" "3\.12\."
check_ver "Node 22+"    "node -v"                                    "^v(2[2-9]|[3-9][0-9])\."
check_ver "pnpm"        "pnpm -v"                                    "^[0-9]"
check_ver "uv"          "uv --version"                               "^uv "
check_ver "Java 17+"    "java -version"                              "version \"(1[7-9]|2[0-9])"
check_ver "Docker"      "docker version --format '{{.Client.Version}}' || docker -v" "[0-9]"
if docker info >/dev/null 2>&1; then
  ok "Docker デーモン起動中"
else
  ng "Docker デーモンが起動していない(コンテナイメージのビルド/pushで必須)"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 0-6. ディスク空き容量 (60GB 以上推奨) ---"
AVAIL_GB=$(df -k . | awk 'NR==2 {printf "%d", $4/1024/1024}')
if [ "$AVAIL_GB" -ge 60 ] 2>/dev/null; then
  ok "空き ${AVAIL_GB}GB"
else
  warn "空き ${AVAIL_GB}GB (< 60GB)。Docker イメージビルドで枯渇の恐れ。不要イメージの削除を"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 0-7. DataZone ドメイン残骸(409 衝突の原因)---"
DZ=$(aws datazone list-domains --region "$REGION" --output json 2>&1)
if [ $? -ne 0 ]; then
  warn "list-domains 失敗(権限不足の可能性): $(echo "$DZ" | head -1)"
elif echo "$DZ" | grep -q '"id"'; then
  echo "$DZ" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4 | sed 's/^/  残存ドメイン: /'
  warn "既存 DataZone ドメインあり。COA 以外の用途なら共存可否を要確認。前回 COA の残骸なら削除: aws datazone delete-domain --identifier <dzd-xxxx> --skip-deletion-check --region $REGION"
else
  ok "残存ドメインなし"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 0-8. アカウント基本衛生(参考)---"
TRAILS=$(aws cloudtrail describe-trails --region "$REGION" \
           --query 'length(trailList)' --output text 2>/dev/null || echo "?")
if [ "$TRAILS" != "?" ] && [ "$TRAILS" -ge 1 ] 2>/dev/null; then
  ok "CloudTrail 証跡あり ($TRAILS)"
else
  warn "CloudTrail 証跡が確認できない。操作ログの有効化を推奨"
fi

# ---------------------------------------------------------------------------
echo
echo "=== 結果: PASS=$PASS WARN=$WARN FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL を解消してから再実行してください。"
  exit 1
fi
echo "Phase 0 クリア。Phase 1(リポジトリ準備)へ進めます。"
