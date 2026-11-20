#!/usr/bin/env bash
# Destroy everything the demo created. Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
REGION="${AWS_REGION:-us-east-1}"
TF=(terraform -chdir=terraform/envs/demo)

# A failed drill can leave its throwaway cluster behind; remove it first so
# the subnet group / security group can be destroyed.
if CLUSTER_ID=$("${TF[@]}" output -raw aurora_cluster_id 2>/dev/null); then
  DRILL="${CLUSTER_ID}-drill"
  if aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$DRILL" >/dev/null 2>&1; then
    echo "Removing leftover drill cluster $DRILL"
    aws rds delete-db-instance --region "$REGION" --db-instance-identifier "${DRILL}-0" --skip-final-snapshot >/dev/null 2>&1 || true
    aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "${DRILL}-0" 2>/dev/null || true
    aws rds delete-db-cluster --region "$REGION" --db-cluster-identifier "$DRILL" --skip-final-snapshot >/dev/null
  fi
fi

"${TF[@]}" destroy -input=false -auto-approve \
  -var "region=$REGION" -var "allowed_cidr=127.0.0.1/32" -var image=unused

rm -f .demo.env
docker rm -f meridian-demo-grafana >/dev/null 2>&1 || true
cat <<EOF

Demo destroyed. Notes:
  - KMS keys are scheduled for deletion (7-day minimum window). This is normal.
  - Check Billing > Cost Explorer tomorrow to confirm spend stopped.
EOF
