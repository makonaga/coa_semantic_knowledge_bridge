#!/usr/bin/env bash
# 停止中の COA を再開する。Neptune の起動完了まで5〜10分かかる。
# 使い方: bash scripts/ops/start-coa.sh
set -uo pipefail

REGION="us-west-2"
PREFIX="coa-dev"

echo "=== COA 起動 (region: $REGION, prefix: $PREFIX) ==="

echo "--- Neptune クラスタ起動 ---"
if aws neptune start-db-cluster --db-cluster-identifier "${PREFIX}-neptune" \
     --region "$REGION" >/dev/null 2>&1; then
  echo "  起動要求 OK: ${PREFIX}-neptune(利用可能まで5〜10分)"
else
  echo "  スキップ(既に起動中か存在しない)"
fi

echo "--- ECS サービスを desired-count 1 に ---"
FOUND=0
for CLUSTER in $(aws ecs list-clusters --region "$REGION" \
                   --query "clusterArns[?contains(@,'${PREFIX}')]" --output text); do
  for SVC in $(aws ecs list-services --cluster "$CLUSTER" --region "$REGION" \
                 --query serviceArns --output text); do
    aws ecs update-service --cluster "$CLUSTER" --service "$SVC" \
      --desired-count 1 --region "$REGION" >/dev/null \
      && echo "  desired=1: ${SVC##*/}" && FOUND=1
  done
done
[ "$FOUND" -eq 0 ] && echo "  対象 ECS サービスなし"

echo ""
echo "完了。Neptune のステータス確認:"
echo "  aws neptune describe-db-clusters --db-cluster-identifier ${PREFIX}-neptune --region ${REGION} --query 'DBClusters[0].Status' --output text"
