#!/usr/bin/env bash
# Deploy the low-cost demo environment end to end.
#
#   scripts/demo/up.sh [--budget-email you@example.com]
#
# Prereqs: AWS CLI v2 (logged in), Terraform >= 1.7, Docker with buildx,
# jq, python3 + pip. Takes ~20 minutes (Aurora creation dominates).
# Cost while up: roughly $0.10-0.30/hour (depends on DB activity). Tear down with scripts/demo/down.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TF=(terraform -chdir=terraform/envs/demo)
REGION="${AWS_REGION:-us-east-1}"
BUDGET_EMAIL=""
[[ "${1:-}" == "--budget-email" ]] && BUDGET_EMAIL="${2:?email}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

for bin in aws terraform docker jq python3; do
  command -v "$bin" >/dev/null || die "missing prerequisite: $bin"
done
docker buildx version >/dev/null 2>&1 || die "docker buildx is required (arm64 image build)"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || die "AWS CLI not authenticated"
MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
TFVARS=(-var "region=$REGION" -var "allowed_cidr=$MY_IP")
[[ -n "$BUDGET_EMAIL" ]] && TFVARS+=(-var "budget_alert_email=$BUDGET_EMAIL")

step "Deploying demo to account $ACCOUNT ($REGION); ALB restricted to $MY_IP"
read -r -p "Continue? This creates billable resources. [y/N] " ok
[[ "$ok" == "y" ]] || exit 1

step "1/7 Build DR verify Lambda bundle"
make lambda-build

step "2/7 Create ECR repository + KMS keys"
"${TF[@]}" init -input=false -upgrade >/dev/null
"${TF[@]}" apply -input=false -auto-approve "${TFVARS[@]}" -var image=bootstrap \
  -target=aws_ecr_repository.intake_api -target=module.kms
REPO=$("${TF[@]}" output -raw ecr_repository_url)

step "3/7 Build + push intake-api image (linux/arm64)"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%s)-$(date +%H%M%S)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}" >/dev/null
docker buildx build --platform linux/arm64 -t "$REPO:$TAG" --push services/intake-api
DIGEST=$(aws ecr describe-images --region "$REGION" --repository-name "${REPO#*/}" \
  --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text)
IMAGE="$REPO@$DIGEST"
echo "image: $IMAGE"

step "4/7 Apply full demo stack (~15 min, mostly Aurora)"
"${TF[@]}" apply -input=false -auto-approve "${TFVARS[@]}" -var "image=$IMAGE"

CLUSTER=$("${TF[@]}" output -raw ecs_cluster)
SERVICE=$("${TF[@]}" output -raw ecs_service)
SG=$("${TF[@]}" output -raw service_security_group_id)
SUBNETS=$("${TF[@]}" output -json private_subnet_ids | jq -r 'join(",")')
ADMIN_TD=$("${TF[@]}" output -raw db_admin_task_definition)
API_URL=$("${TF[@]}" output -raw api_url)

step "5/7 DB bootstrap: login roles, migrations as owner, least-privilege grants"
TASK=$(aws ecs run-task --region "$REGION" --cluster "$CLUSTER" --launch-type FARGATE \
  --task-definition "$ADMIN_TD" --started-by demo-up \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK"
CODE=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK" \
  --query 'tasks[0].containers[0].exitCode' --output text)
[[ "$CODE" == "0" ]] || die "db-admin task failed (exit $CODE). Logs: aws logs tail /ecs/demo/intake-api-db-admin --region $REGION"

step "6/7 Roll the API now that its DB role exists"
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment >/dev/null
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE"

step "7/7 Smoke test + seed synthetic data"
scripts/ci/smoke.sh "$API_URL"
python3 scripts/seed_synthetic.py --url "$API_URL" --count 200

cat > .demo.env <<EOF
REGION=$REGION
API_URL=$API_URL
AMP_QUERY_URL=$("${TF[@]}" output -raw amp_query_url)
STATE_MACHINE=$("${TF[@]}" output -raw dr_drill_state_machine_arn)
EOF

step "Demo is up"
cat <<EOF
  API (docs):        $API_URL/docs   (reachable from $MY_IP only)
  Grafana:           scripts/demo/grafana.sh     -> http://localhost:3000
  Restore drill:     scripts/demo/drill.sh       (~30-40 min)
  Generate traffic:  python3 scripts/seed_synthetic.py --url $API_URL --count 500
  Tear down:         scripts/demo/down.sh

  Screenshots worth taking: Grafana intake-api SLO dashboard (env=demo),
  Data platform dashboard after the drill, Step Functions execution graph,
  X-Ray service map. Save them under docs/demo/ and they appear in the README.
EOF
