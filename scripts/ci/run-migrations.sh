#!/usr/bin/env bash
# Run Alembic migrations as a one-off Fargate task using the SAME image
# digest that is about to be deployed, in the service's own network/IAM
# context (so it authenticates to Aurora with IAM, no passwords in CI).
#
#   scripts/ci/run-migrations.sh <env|pr-N> <image-digest>
set -euo pipefail

ENV_NAME="$1"
IMAGE="$2"
CLUSTER="${CLUSTER:-meridian-${ENV_NAME%%-*}}"
[[ "$ENV_NAME" == pr-* ]] && CLUSTER="meridian-dev"
SERVICE="${SERVICE:-intake-api}"
[[ "$ENV_NAME" == pr-* ]] && SERVICE="${ENV_NAME}-intake"

# Reuse the live service's network configuration and IAM roles, but register a
# task definition revision pointing at the NEW image (ECS overrides can't change
# the image), so the migrations that run are the ones shipping in this release.
svc_json=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0]')
live_taskdef=$(jq -r '.taskDefinition' <<<"$svc_json")
netcfg=$(jq -c '.networkConfiguration' <<<"$svc_json")

new_def=$(aws ecs describe-task-definition --task-definition "$live_taskdef" --query taskDefinition \
  | jq --arg c "$SERVICE" --arg img "$IMAGE" '
      .family = (.family + "-migrate")
      | .containerDefinitions |= map(if .name == $c then .image = $img else . end)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')
taskdef=$(aws ecs register-task-definition --cli-input-json "$new_def" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

overrides=$(jq -nc --arg c "$SERVICE" '{
  containerOverrides: [{ name: $c, command: ["alembic", "upgrade", "head"] }]
}')

echo "Running migrations on $CLUSTER/$SERVICE with $IMAGE"
task_arn=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$taskdef" \
  --network-configuration "$netcfg" \
  --overrides "$overrides" \
  --started-by "migrations-${GITHUB_RUN_ID:-local}" \
  --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"
exit_code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
  --query "tasks[0].containers[?name=='$SERVICE'].exitCode | [0]" --output text)

if [[ "$exit_code" != "0" ]]; then
  echo "::error::migrations failed (exit $exit_code); deploy aborted before any traffic shift"
  exit 1
fi
echo "migrations complete"
