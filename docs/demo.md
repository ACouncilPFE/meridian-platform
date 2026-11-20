# Running the demo on AWS

The demo deploys the **same Terraform modules as prod** with cost-minimizing inputs, so you can show the platform actually running, then tear it down. Budget about **$0.10–0.30/hour** while it's up. An afternoon costs a few dollars.

> Synthetic data only. The demo API is plain HTTP and reachable only from your own IP address.

## 1. One-time setup (≈15 min)

1. **AWS account.** Use a personal or sandbox account, never an employer's. Turn on MFA for the root user and create an admin user (or IAM Identity Center user) to work as.
2. **Set a budget alert first.** `make demo-up BUDGET_EMAIL=you@example.com` creates a $25/month AWS Budget with email alerts. You can also set one up in the Billing console.
3. **Install the tools:** AWS CLI v2, Terraform ≥ 1.7, Docker Desktop (buildx included), `jq`, Python 3.12.
4. **Log in:** run `aws configure sso` (or `aws configure`), then confirm `aws sts get-caller-identity` shows your account.

## 2. Deploy (≈20 min)

```bash
make demo-up BUDGET_EMAIL=you@example.com
```

The script:

1. Bundles the DR Lambda.
2. Creates the ECR repo and KMS keys.
3. Builds and pushes the arm64 image.
4. Applies the stack.
5. Runs the **db-admin task**: creates IAM-auth roles, runs migrations as the schema owner, and applies least-privilege grants.
6. Rolls the API, smoke-tests it, and seeds 200 synthetic patients.

## 3. Capture the evidence

| Screenshot | How |
|---|---|
| API docs + a request round-trip | Open `$API_URL/docs` (printed at the end of `up.sh`) |
| SLO / golden-signals dashboard | `make demo-grafana`, open http://localhost:3000, choose **env = demo**. Generate traffic first with `python3 scripts/seed_synthetic.py --url $API_URL --count 500` |
| Passing restore drill | `make demo-drill` (~30–40 min), then screenshot the Step Functions execution graph (link printed) and the **Data platform** dashboard |
| Traces | AWS console → X-Ray → Trace map (or the X-Ray datasource in local Grafana) |
| Alerts loaded | AWS console → Amazon Managed Service for Prometheus → workspace → Rules management |
| Least privilege | IAM → the `intake-api-task-*` role policy (one DB user, one table, one key) |

Save the images as `docs/demo/*.png` using the names referenced in the README, then commit.

## 4. Tear down

```bash
make demo-down
```

KMS keys enter a 7-day pending-deletion window (that's normal). Check Cost Explorer the next day to confirm spending has stopped.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `db-admin task failed` | `aws logs tail /ecs/demo/intake-api-db-admin`. Usually Aurora was still resuming; re-run `make demo-up` (every step is idempotent). |
| API returns 503 / unhealthy targets | Check that the db-admin step succeeded, then `aws ecs update-service --force-new-deployment` |
| Can't reach the API | Your IP changed. Re-run `make demo-up`, which updates the ALB allow-list. |
| Grafana panels show auth errors | Your temporary credentials expired. Re-run `make demo-grafana`. |
| Drill fails at Verify | Open the execution and read the Lambda's output. A `migration_head` mismatch right after a deploy is expected, so re-run the drill. |
| `terraform destroy` stuck on a subnet group | A leftover `-drill` cluster. `down.sh` removes it; re-run `down.sh`. |
