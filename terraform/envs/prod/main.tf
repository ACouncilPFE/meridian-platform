# -----------------------------------------------------------------------------
# prod: composes paved-road modules into the production environment.
# Primary: us-east-1   DR: us-west-2
# -----------------------------------------------------------------------------

locals {
  name = "meridian-prod"
  tags = {
    "env"         = "prod"
    "owner"       = "platform"
    "managed-by"  = "terraform"
    "compliance"  = "hipaa,soc2"
    "cost-center" = "platform"
    "repo"        = "meridian-platform"
  }
  rules_dir = "${path.root}/../../../observability/prometheus/rules"
}

data "aws_caller_identity" "current" {}

# --- Encryption keys ---------------------------------------------------------
module "kms" {
  source = "../../modules/kms"
  name   = local.name
  keys = {
    phi = {
      description        = "PHI at rest: Aurora, DynamoDB, S3 exports"
      classification     = "phi"
      multi_region       = true
      service_principals = ["rds.amazonaws.com", "dynamodb.amazonaws.com", "backup.amazonaws.com", "s3.amazonaws.com"]
    }
    ops = {
      description        = "Operational data: logs, metrics, SNS"
      classification     = "internal"
      service_principals = ["logs.us-east-1.amazonaws.com", "aps.amazonaws.com", "sns.amazonaws.com", "states.amazonaws.com"]
    }
  }
  tags = local.tags
}

module "kms_dr" {
  source    = "../../modules/kms"
  providers = { aws = aws.dr }
  name      = "${local.name}-dr"
  keys = {
    backup = {
      description        = "DR-region backup vault"
      classification     = "phi"
      service_principals = ["backup.amazonaws.com"]
    }
  }
  tags = local.tags
}

resource "aws_backup_vault" "dr" {
  provider    = aws.dr
  name        = "${local.name}-dr"
  kms_key_arn = module.kms_dr.key_arns["backup"]
  tags        = local.tags
}

# --- Network -----------------------------------------------------------------
module "network" {
  source      = "../../modules/network"
  name        = local.name
  region      = var.region
  cidr_block  = "10.40.0.0/16"
  az_count    = 3
  kms_key_arn = module.kms.key_arns["ops"]
  tags        = local.tags
}

# --- Observability -----------------------------------------------------------
module "observability" {
  source                  = "../../modules/observability"
  name                    = local.name
  kms_key_arn             = module.kms.key_arns["ops"]
  rules_dir               = local.rules_dir
  vpc_id                  = module.network.vpc_id
  vpc_cidr                = module.network.vpc_cidr
  private_subnet_ids      = module.network.private_subnet_ids
  pagerduty_endpoint      = var.pagerduty_endpoint
  grafana_admin_group_ids = var.grafana_admin_group_ids
  tags                    = local.tags
}

# --- Data tier ---------------------------------------------------------------
module "aurora" {
  source                     = "../../modules/aurora-postgres"
  name                       = "${local.name}-core"
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.data_subnet_ids
  allowed_security_group_ids = [module.intake_api.security_group_id, module.pipeline_worker.security_group_id]
  instance_count             = 3 # writer + 2 readers across 3 AZs
  serverless_max_acu         = 32
  kms_key_arn                = module.kms.key_arns["phi"]
  backup_retention_days      = 35
  long_term_retention_days   = 2190 # 6 years (HIPAA documentation retention)
  dr_backup_vault_arn        = aws_backup_vault.dr.arn
  tags                       = local.tags
}

module "idempotency_table" {
  source        = "../../modules/dynamodb-table"
  name          = "${local.name}-idempotency"
  hash_key      = "pk"
  attributes    = { pk = "S" }
  ttl_attribute = "expires_at"
  kms_key_arn   = module.kms.key_arns["phi"]
  replica_regions = [{
    region      = var.dr_region
    kms_key_arn = module.kms_dr.key_arns["backup"]
  }]
  tags = local.tags
}

# --- Compute -----------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
  tags = local.tags
}

locals {
  service_defaults = {
    environment               = "prod"
    cluster_arn               = aws_ecs_cluster.this.arn
    vpc_id                    = module.network.vpc_id
    vpc_cidr                  = module.network.vpc_cidr
    private_subnet_ids        = module.network.private_subnet_ids
    certificate_arn           = var.certificate_arn
    amp_workspace_arn         = module.observability.amp_workspace_arn
    amp_remote_write_endpoint = module.observability.amp_remote_write_endpoint
    traces_otlp_endpoint      = var.tempo_otlp_endpoint
    logs_kms_key_arn          = module.kms.key_arns["ops"]
  }
}

module "intake_api" {
  source = "../../modules/ecs-fargate-service"

  name                      = "intake-api"
  image                     = var.intake_api_image
  environment               = local.service_defaults.environment
  cluster_arn               = local.service_defaults.cluster_arn
  vpc_id                    = local.service_defaults.vpc_id
  vpc_cidr                  = local.service_defaults.vpc_cidr
  private_subnet_ids        = local.service_defaults.private_subnet_ids
  certificate_arn           = local.service_defaults.certificate_arn
  amp_workspace_arn         = local.service_defaults.amp_workspace_arn
  amp_remote_write_endpoint = local.service_defaults.amp_remote_write_endpoint
  traces_otlp_endpoint      = local.service_defaults.traces_otlp_endpoint
  logs_kms_key_arn          = local.service_defaults.logs_kms_key_arn

  min_count = 3
  max_count = 20
  environment_variables = {
    DB_HOST           = module.aurora.writer_endpoint
    DB_NAME           = "app"
    DB_IAM_AUTH       = "true"
    IDEMPOTENCY_TABLE = module.idempotency_table.table_name
    PHI_KMS_KEY_ID    = module.kms.key_arns["phi"]
  }
  task_policy_json = data.aws_iam_policy_document.intake_api.json
  tags             = local.tags
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

module "pipeline_worker" {
  source = "../../modules/ecs-fargate-service"

  name                      = "pipeline-worker"
  image                     = var.pipeline_worker_image
  environment               = local.service_defaults.environment
  cluster_arn               = local.service_defaults.cluster_arn
  vpc_id                    = local.service_defaults.vpc_id
  vpc_cidr                  = local.service_defaults.vpc_cidr
  private_subnet_ids        = local.service_defaults.private_subnet_ids
  certificate_arn           = local.service_defaults.certificate_arn
  amp_workspace_arn         = local.service_defaults.amp_workspace_arn
  amp_remote_write_endpoint = local.service_defaults.amp_remote_write_endpoint
  traces_otlp_endpoint      = local.service_defaults.traces_otlp_endpoint
  logs_kms_key_arn          = local.service_defaults.logs_kms_key_arn

  container_port = 9464 # health + metrics only; workers poll Temporal, no inbound traffic
  min_count      = 2
  max_count      = 10
  environment_variables = {
    TEMPORAL_ADDRESS   = var.temporal_address
    TEMPORAL_NAMESPACE = "meridian-prod"
    TASK_QUEUE         = "deidentify-export"
    DB_HOST            = module.aurora.reader_endpoint
    EXPORT_BUCKET      = aws_s3_bucket.exports.bucket
  }
  secrets = {
    TEMPORAL_TLS_CERT = "${var.temporal_mtls_secret_arn}:cert::"
    TEMPORAL_TLS_KEY  = "${var.temporal_mtls_secret_arn}:key::"
  }
  secrets_kms_key_arns = [module.kms.key_arns["ops"]]
  tags                 = local.tags
}

# Separate one-off task: the only holder of the Aurora master credential.
module "db_admin" {
  source                    = "../../modules/db-admin-task"
  name                      = "intake-api"
  environment               = "prod"
  image                     = var.intake_api_image
  db_host                   = module.aurora.writer_endpoint
  master_secret_arn         = module.aurora.master_user_secret_arn
  master_secret_kms_key_arn = module.kms.key_arns["phi"]
  logs_kms_key_arn          = module.kms.key_arns["ops"]
  tags                      = local.tags
}

# --- De-identified export bucket (Snowflake stage) ---------------------------
resource "aws_s3_bucket" "exports" {
  #checkov:skip=CKV_AWS_18:Object-level access is captured by organization CloudTrail S3 data events, which (unlike server access logs) are tamper-evident.
  #checkov:skip=CKV_AWS_144:Staging area only: every object is reproducible from Aurora by re-running the export workflow, and it expires in 30 days.
  #checkov:skip=CKV2_AWS_62:Snowflake loads via COPY INTO from the workflow; no event-driven consumers exist.
  bucket = "${local.name}-deidentified-exports-${data.aws_caller_identity.current.account_id}"
  tags   = merge(local.tags, { "data:classification" = "confidential" })
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = module.kms.key_arns["phi"]
    }
    bucket_key_enabled = true
  }
}

# Data minimization: de-identified exports only need to live until Snowflake
# has loaded them.
resource "aws_s3_bucket_lifecycle_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id

  rule {
    id     = "expire-staged-exports"
    status = "Enabled"
    filter {
      prefix = "deidentified/"
    }
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_versioning" "exports" {
  bucket = aws_s3_bucket.exports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "exports_tls_only" {
  bucket = aws_s3_bucket.exports.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.exports.arn, "${aws_s3_bucket.exports.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# --- DR -----------------------------------------------------------------------
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

# --- Analytics ---------------------------------------------------------------
module "snowflake" {
  source                = "../../modules/snowflake-analytics"
  name                  = "meridian"
  allowed_ip_cidrs      = var.nat_egress_cidrs
  snowflake_s3_role_arn = var.snowflake_s3_role_arn
  export_bucket         = aws_s3_bucket.exports.bucket
}
