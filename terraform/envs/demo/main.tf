# -----------------------------------------------------------------------------
# demo: the SAME paved-road modules as prod, with cost-minimizing inputs.
#
# Purpose: deploy for an afternoon, capture evidence (Grafana dashboards, a
# passing restore drill, a working API), then `scripts/demo/down.sh`.
# Approx. $0.10-0.30/hour while up (Aurora pauses when idle). NOT a production configuration; see the
# prod-vs-demo table in README.md for every deliberate difference.
#
# Synthetic data only. The ALB is plain HTTP and reachable only from the
# deployer's IP (allowed_cidr).
# -----------------------------------------------------------------------------

locals {
  name = "meridian-demo"
  tags = {
    "env"                 = "demo"
    "owner"               = "platform"
    "managed-by"          = "terraform"
    "data:classification" = "synthetic"
    "repo"                = "meridian-platform"
  }
  rules_dir = "${path.root}/../../../observability/prometheus/rules"
}

data "aws_caller_identity" "current" {}

# --- Keys: same split as prod (PHI vs ops), shortest deletion window ---------
module "kms" {
  source                  = "../../modules/kms"
  name                    = local.name
  deletion_window_in_days = 7
  keys = {
    phi = {
      description        = "Demo PHI-class key (synthetic data): Aurora, DynamoDB, field encryption"
      classification     = "phi"
      service_principals = ["rds.amazonaws.com", "dynamodb.amazonaws.com"]
    }
    ops = {
      description        = "Demo operational key: logs, metrics, SNS"
      classification     = "internal"
      service_principals = ["logs.${var.region}.amazonaws.com", "aps.amazonaws.com", "sns.amazonaws.com", "states.amazonaws.com"]
    }
  }
  tags = local.tags
}

# --- Network: 2 AZs, one NAT, gateway endpoints only --------------------------
module "network" {
  source                  = "../../modules/network"
  name                    = local.name
  region                  = var.region
  cidr_block              = "10.60.0.0/16"
  az_count                = 2
  single_nat_gateway      = true
  interface_endpoints     = [] # ~$0.24/hr saved; traffic to AWS APIs uses the NAT instead
  kms_key_arn             = module.kms.key_arns["ops"]
  flow_log_retention_days = 7
  tags                    = local.tags
}

# --- Observability: Managed Prometheus; Grafana runs locally against it -------
module "observability" {
  source                 = "../../modules/observability"
  name                   = local.name
  kms_key_arn            = module.kms.key_arns["ops"]
  rules_dir              = local.rules_dir
  vpc_id                 = module.network.vpc_id
  vpc_cidr               = module.network.vpc_cidr
  private_subnet_ids     = module.network.private_subnet_ids
  enable_managed_grafana = var.enable_managed_grafana
  log_retention_days     = 7
  tags                   = local.tags
}

# --- Data tier ----------------------------------------------------------------
module "aurora" {
  source                     = "../../modules/aurora-postgres"
  name                       = "${local.name}-core"
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.data_subnet_ids
  allowed_security_group_ids = [module.intake_api.security_group_id]
  instance_count             = 1 # prod: 3 (writer + 2 readers across AZs)
  serverless_min_acu         = 0 # pauses when idle
  serverless_max_acu         = 2
  kms_key_arn                = module.kms.key_arns["phi"]
  backup_retention_days      = 1     # PITR still on; the restore drill uses it
  enable_aws_backup          = false # prod: daily, 6-year, cross-region, vault-locked
  deletion_protection        = false
  data_classification        = "synthetic"
  tags                       = local.tags
}

module "idempotency_table" {
  source              = "../../modules/dynamodb-table"
  name                = "${local.name}-idempotency"
  hash_key            = "pk"
  attributes          = { pk = "S" }
  ttl_attribute       = "expires_at"
  kms_key_arn         = module.kms.key_arns["phi"]
  deletion_protection = false
  data_classification = "synthetic"
  tags                = local.tags
}

# --- Compute ------------------------------------------------------------------
resource "aws_ecr_repository" "intake_api" {
  name                 = "${local.name}/intake-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo teardown; prod repos are long-lived

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = module.kms.key_arns["ops"]
  }

  tags = local.tags
}

resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "disabled" # metrics come from Prometheus; avoids CloudWatch custom-metric cost
  }
  tags = local.tags
}

module "intake_api" {
  source = "../../modules/ecs-fargate-service"

  name                    = "intake-api"
  environment             = "demo"
  image                   = var.image
  cluster_arn             = aws_ecs_cluster.this.arn
  vpc_id                  = module.network.vpc_id
  vpc_cidr                = module.network.vpc_cidr
  private_subnet_ids      = module.network.private_subnet_ids
  public_subnet_ids       = module.network.public_subnet_ids
  internal                = false
  alb_ingress_cidrs       = [var.allowed_cidr]
  certificate_arn         = null # plain HTTP, deployer's IP only, synthetic data
  alb_deletion_protection = false

  amp_workspace_arn         = module.observability.amp_workspace_arn
  amp_remote_write_endpoint = module.observability.amp_remote_write_endpoint
  traces_otlp_endpoint      = "" # traces -> AWS X-Ray
  logs_kms_key_arn          = module.kms.key_arns["ops"]
  log_retention_days        = 7

  cpu       = 256
  memory    = 512
  min_count = 1 # prod: 3
  max_count = 2

  environment_variables = {
    DB_HOST           = module.aurora.writer_endpoint
    DB_NAME           = "app"
    DB_USER           = "intake_api"
    DB_IAM_AUTH       = "true"
    IDEMPOTENCY_TABLE = module.idempotency_table.table_name
    PHI_KMS_KEY_ID    = module.kms.key_arns["phi"]
  }
  task_policy_json    = data.aws_iam_policy_document.intake_api.json
  data_classification = "synthetic"
  tags                = local.tags
}

data "aws_iam_policy_document" "intake_api" {
  statement {
    sid       = "DbIamAuth"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.aurora.cluster_resource_id}/intake_api"]
  }
  statement {
    sid       = "Idempotency"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [module.idempotency_table.table_arn]
  }
  statement {
    sid       = "EnvelopeEncryption"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [module.kms.key_arns["phi"]]
  }
}

module "db_admin" {
  source                    = "../../modules/db-admin-task"
  name                      = "intake-api"
  environment               = "demo"
  image                     = var.image
  db_host                   = module.aurora.writer_endpoint
  master_secret_arn         = module.aurora.master_user_secret_arn
  master_secret_kms_key_arn = module.kms.key_arns["phi"]
  logs_kms_key_arn          = module.kms.key_arns["ops"]
  log_retention_days        = 7
  tags                      = local.tags
}

# --- DR: the same weekly restore drill as prod --------------------------------
module "dr_drill" {
  source                    = "../../modules/dr-restore-drill"
  source_cluster_id         = module.aurora.cluster_id
  database_name             = "app"
  db_subnet_group_name      = module.aurora.db_subnet_group_name
  drill_security_group_id   = module.aurora.security_group_id
  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = module.network.vpc_cidr
  lambda_subnet_ids         = module.network.private_subnet_ids
  kms_key_arn               = module.kms.key_arns["phi"]
  lambda_source_dir         = "${path.root}/../../../lambdas/dr_verify/build"
  logs_kms_key_arn          = module.kms.key_arns["ops"]
  log_retention_days        = 7
  amp_workspace_arn         = module.observability.amp_workspace_arn
  amp_remote_write_endpoint = module.observability.amp_remote_write_endpoint
  tags                      = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "dr_verify_to_aurora" {
  security_group_id            = module.aurora.security_group_id
  referenced_security_group_id = module.dr_drill.verify_lambda_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "DR verify lambda -> restored drill cluster"
}

# --- Cost guardrail -----------------------------------------------------------
resource "aws_budgets_budget" "demo" {
  count        = var.budget_alert_email == null ? 0 : 1
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Whole-account budget on purpose: in a personal/sandbox account, any
  # unexpected spend is worth an email, not just spend tagged env=demo.

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
