#!/usr/bin/env bash
# Run the Aurora restore drill on demand and print the measured RTO/RPO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/.demo.env"

ARN=$(aws stepfunctions start-execution --region "$REGION" --state-machine-arn "$STATE_MACHINE" \
  --input '{"trigger":"demo"}' --query executionArn --output text)
echo "Started: $ARN"
echo "Console: https://$REGION.console.aws.amazon.com/states/home?region=$REGION#/v2/executions/details/$ARN"

while true; do
  STATUS=$(aws stepfunctions describe-execution --region "$REGION" --execution-arn "$ARN" --query status --output text)
  [[ "$STATUS" == "RUNNING" ]] || break
  printf '.'; sleep 60
done
echo
echo "Status: $STATUS"
aws stepfunctions describe-execution --region "$REGION" --execution-arn "$ARN" --query output --output text \
  | jq '.verification.result // .' 2>/dev/null || true
[[ "$STATUS" == "SUCCEEDED" ]]
