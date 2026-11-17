#!/usr/bin/env bash
# Roll an ECS service back to the previous task definition revision.
# Safe because migrations are expand-only: the previous app version still
# works against the current schema (see docs/runbooks/db-migrations.md).
set -euo pipefail
ENV_NAME="${1:?env}"; SERVICE="${2:-intake-api}"
CLUSTER="meridian-${ENV_NAME}"

current=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)
family="${current%:*}"; rev="${current##*:}"
previous="${family}:$((rev - 1))"

echo "Rolling $CLUSTER/$SERVICE: $current -> $previous"
read -r -p "Proceed? [y/N] " ok; [[ "$ok" == "y" ]] || exit 1
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$previous" >/dev/null
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
echo "Rollback complete. Terraform will show drift on next plan; pin the image in prod.tfvars or revert the commit."
