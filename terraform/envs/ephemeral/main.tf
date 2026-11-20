# -----------------------------------------------------------------------------
# ephemeral: a full, isolated stack per pull request.
#
#   terraform workspace select -or-create pr-123
#   terraform apply -var pr_number=123 -var image=...@sha256:...
#
# Reuses the long-lived dev VPC, ECS cluster and AMP workspace (looked up via
# remote state) and creates per-PR: its own Aurora Serverless v2 cluster
# (synthetic data only, never PHI), its own intake-api service, and its own
# DynamoDB table. Destroyed automatically when the PR closes, and a nightly
# reaper destroys anything older than `ttl_hours` (see .github/workflows).
# -----------------------------------------------------------------------------

locals {
  name = "pr-${var.pr_number}"
  tags = {
    "env"                 = "ephemeral"
    "pr"                  = tostring(var.pr_number)
    "expires-at"          = timeadd(plantimestamp(), "${var.ttl_hours}h")
    "data:classification" = "synthetic"
    "managed-by"          = "terraform"
  }
  dev = data.terraform_remote_state.dev.outputs
}

data "terraform_remote_state" "dev" {
  backend = "s3"
  config = {
    bucket = "meridian-tfstate-dev"
    key    = "envs/dev/terraform.tfstate"
    region = "us-east-1"
  }
}

module "aurora" {
  source                     = "../../modules/aurora-postgres"
  name                       = local.name
  vpc_id                     = local.dev.vpc_id
  subnet_ids                 = local.dev.data_subnet_ids
  allowed_security_group_ids = [module.intake_api.security_group_id]
  instance_count             = 1
  serverless_min_acu         = 0 # scales to zero when idle
  serverless_max_acu         = 2
  kms_key_arn                = local.dev.kms_key_arns["phi"]
  backup_retention_days      = 1
  long_term_retention_days   = 7
  enable_vault_lock          = false
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
  kms_key_arn         = local.dev.kms_key_arns["phi"]
  deletion_protection = false
  data_classification = "synthetic"
  tags                = local.tags
}

module "intake_api" {
  source = "../../modules/ecs-fargate-service"

  name                      = "${local.name}-intake"
  image                     = var.image
  environment               = "ephemeral"
  cluster_arn               = local.dev.ecs_cluster_arn
  vpc_id                    = local.dev.vpc_id
  vpc_cidr                  = local.dev.vpc_cidr
  private_subnet_ids        = local.dev.private_subnet_ids
  certificate_arn           = local.dev.wildcard_certificate_arn
  amp_workspace_arn         = local.dev.amp_workspace_arn
  amp_remote_write_endpoint = local.dev.amp_remote_write_endpoint
  traces_otlp_endpoint      = local.dev.tempo_otlp_endpoint
  logs_kms_key_arn          = local.dev.kms_key_arns["ops"]
  log_retention_days        = 7
  min_count                 = 1
  max_count                 = 2
  cpu                       = 256
  memory                    = 512
  data_classification       = "synthetic"
  alb_deletion_protection   = false

  environment_variables = {
    DB_HOST           = module.aurora.writer_endpoint
    DB_NAME           = "app"
    DB_USER           = "intake_api"
    DB_IAM_AUTH       = "true"
    IDEMPOTENCY_TABLE = module.idempotency_table.table_name
    SEED_SYNTHETIC    = "true"
  }
  tags = local.tags
}

module "db_admin" {
  source                    = "../../modules/db-admin-task"
  name                      = "${local.name}-intake"
  environment               = "ephemeral"
  image                     = var.image
  db_host                   = module.aurora.writer_endpoint
  master_secret_arn         = module.aurora.master_user_secret_arn
  master_secret_kms_key_arn = local.dev.kms_key_arns["phi"]
  logs_kms_key_arn          = local.dev.kms_key_arns["ops"]
  log_retention_days        = 7
  tags                      = local.tags
}

output "url" {
  value = module.intake_api.url
}
