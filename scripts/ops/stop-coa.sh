#!/usr/bin/env bash
# COA を停止してアイドルコスト(~$0.45/時 = VPCエンドポイント+NATのみ)まで下げる。
# 使い方: bash scripts/ops/stop-coa.sh
#   リージョンは環境変数 COA_REGION で指定(未設定時は us-west-2)
set -uo pipefail

REGION="${COA_REGION:-us-west-2}"
PREFIX="coa-dev"

echo "=== COA 停止 (region: $REGION, prefix: $PREFIX) ==="

echo "--- Neptune クラスタ停止 ---"
if aws neptune stop-db-cluster --db-cluster-identifier "${PREFIX}-neptune" \
     --region "$REGION" >/dev/null 2>&1; then
  echo "  停止要求 OK: ${PREFIX}-neptune"
else
  echo "  スキップ(既に停止中・存在しない・または停止不可の状態)"
fi

echo "--- ECS サービスを desired-count 0 に ---"
FOUND=0
for CLUSTER in $(aws ecs list-clusters --region "$REGION" \
                   --query "clusterArns[?contains(@,'${PREFIX}')]" --output text); do
  for SVC in $(aws ecs list-services --cluster "$CLUSTER" --region "$REGION" \
                 --query serviceArns --output text); do
    aws ecs update-service --cluster "$CLUSTER" --service "$SVC" \
      --desired-count 0 --region "$REGION" >/dev/null \
      && echo "  desired=0: ${SVC##*/}" && FOUND=1
  done
done
[ "$FOUND" -eq 0 ] && echo "  対象 ECS サービスなし"

echo ""
echo "完了。OpenSearch は aoss_min_ocu=0 設定によりアイドル時 OCU が自動で下がる。"
echo "注意1: Neptune は停止から7日後に AWS 仕様で自動再開される。長期停止中は週1で本スクリプトを再実行すること。"
echo "注意2: 1週間以上使わない場合はフル削除(再デプロイ1.5時間)の方が安い(アイドルでも ~\$10.7/日)。"
