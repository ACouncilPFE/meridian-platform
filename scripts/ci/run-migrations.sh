#!/usr/bin/env bash
# Run the db-admin task (roles + Alembic migrations as schema owner + grants)
# using the SAME image digest that is about to be deployed, before traffic
# shifts. Runtime roles have no DDL rights, so this is the only migration path.
#
#   scripts/ci/run-migrations.sh <prod|pr-N> <image-digest>
set -euo pipefail

ENV_NAME="$1"
IMAGE="$2"
if [[ "$ENV_NAME" == pr-* ]]; then
  CLUSTER="meridian-dev"
  SERVICE="${ENV_NAME}-intake"
  ADMIN_FAMILY="ephemeral-${ENV_NAME}-intake-db-admin"
else
  CLUSTER="meridian-${ENV_NAME}"
  SERVICE="intake-api"
  ADMIN_FAMILY="${ENV_NAME}-intake-api-db-admin"
fi

# Network placement: same subnets + security group as the service (which the
# Aurora security group already admits).
netcfg=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].networkConfiguration' --output json)

# ECS run-task overrides can't change the image, so register a revision of the
# db-admin task definition pointing at the release image.
new_def=$(aws ecs describe-task-definition --task-definition "$ADMIN_FAMILY" --query taskDefinition \
  | jq --arg img "$IMAGE" '
      .containerDefinitions |= map(if .name == "db-admin" then .image = $img else . end)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')
taskdef=$(aws ecs register-task-definition --cli-input-json "$new_def" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "Running db-admin ($taskdef) on $CLUSTER"
task_arn=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$taskdef" \
  --network-configuration "$netcfg" \
  --started-by "migrations-${GITHUB_RUN_ID:-local}" \
  --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"
exit_code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
  --query "tasks[0].containers[?name=='db-admin'].exitCode | [0]" --output text)

if [[ "$exit_code" != "0" ]]; then
  echo "::error::db-admin/migrations failed (exit $exit_code); deploy aborted before any traffic shift"
  exit 1
fi
echo "migrations complete"
