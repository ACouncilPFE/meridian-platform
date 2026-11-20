# -----------------------------------------------------------------------------
# aurora-postgres: production-grade Aurora PostgreSQL cluster
#  - Multi-AZ writer + readers, automatic failover
#  - KMS encryption at rest, TLS enforced in transit (rds.force_ssl)
#  - IAM database authentication; master password managed by Secrets Manager
#  - PITR (backup_retention_period) + AWS Backup plan with cross-region copy (DR)
#  - pgaudit + Performance Insights + enhanced monitoring for SOC 2 evidence
#  - Optional Aurora Global Database secondary for low-RPO regional DR
# -----------------------------------------------------------------------------

locals {
  tags = merge(var.tags, {
    "platform:module"     = "aurora-postgres"
    "data:classification" = var.data_classification
    "backup:plan"         = var.name
  })
  family = "aurora-postgresql${split(".", var.engine_version)[0]}"
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = local.tags
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-aurora-"
  description = "Aurora ${var.name}: Postgres only from allowed app security groups"
  vpc_id      = var.vpc_id
  tags        = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_apps" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from ${each.value}"
}

resource "aws_rds_cluster_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = local.family
  description = "Hardened parameters for ${var.name}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pgaudit"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "pgaudit.log"
    value = "ddl,role,write"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.slow_query_ms)
  }
  # Never log bind parameters: they may contain PHI.
  parameter {
    name  = "pgaudit.log_parameter"
    value = "0"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "this" {
  #checkov:skip=CKV2_AWS_27:Statement-level query logging (log_statement) would write PHI literals to CloudWatch. pgaudit logs DDL/role/write events with parameter logging disabled, plus slow-query logging.
  cluster_identifier = var.name
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version
  database_name      = var.database_name
  master_username    = "platform_admin"

  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.this.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  storage_encrypted                   = true
  kms_key_id                          = var.kms_key_arn
  iam_database_authentication_enabled = true

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "06:00-07:00"
  preferred_maintenance_window = "sun:07:30-sun:08:30"
  copy_tags_to_snapshot        = true
  deletion_protection          = var.deletion_protection
  skip_final_snapshot          = !var.deletion_protection
  final_snapshot_identifier    = var.deletion_protection ? "${var.name}-final" : null

  enabled_cloudwatch_logs_exports = ["postgresql"]

  dynamic "serverlessv2_scaling_configuration" {
    for_each = var.instance_class == "db.serverless" ? [1] : []
    content {
      min_capacity             = var.serverless_min_acu
      max_capacity             = var.serverless_max_acu
      seconds_until_auto_pause = var.serverless_min_acu == 0 ? var.seconds_until_auto_pause : null
    }
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [engine_version] # minor upgrades applied via maintenance window / runbook
  }
}

resource "aws_iam_role" "monitoring" {
  name_prefix = "${var.name}-rds-mon-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"]
  tags                = local.tags
}

resource "aws_rds_cluster_instance" "this" {
  count                                 = var.instance_count
  identifier                            = "${var.name}-${count.index}"
  cluster_identifier                    = aws_rds_cluster.this.id
  engine                                = aws_rds_cluster.this.engine
  engine_version                        = aws_rds_cluster.this.engine_version
  instance_class                        = var.instance_class
  db_subnet_group_name                  = aws_db_subnet_group.this.name
  publicly_accessible                   = false
  auto_minor_version_upgrade            = true
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 15
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  promotion_tier                        = count.index
  tags                                  = local.tags
}

# --- AWS Backup: long-term retention + cross-region copy ---------------------
resource "aws_backup_vault" "primary" {
  count       = var.enable_aws_backup ? 1 : 0
  name        = "${var.name}-primary"
  kms_key_arn = var.kms_key_arn
  tags        = local.tags
}

# WORM lock: backups cannot be deleted early, even by an admin (ransomware defense).
resource "aws_backup_vault_lock_configuration" "primary" {
  count               = var.enable_aws_backup && var.enable_vault_lock ? 1 : 0
  backup_vault_name   = aws_backup_vault.primary[0].name
  min_retention_days  = 7
  max_retention_days  = var.long_term_retention_days
  changeable_for_days = 3
}

resource "aws_backup_plan" "this" {
  count = var.enable_aws_backup ? 1 : 0
  name  = var.name

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.primary[0].name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.long_term_retention_days
    }

    dynamic "copy_action" {
      for_each = var.dr_backup_vault_arn == null ? [] : [1]
      content {
        destination_vault_arn = var.dr_backup_vault_arn
        lifecycle {
          delete_after = var.long_term_retention_days
        }
      }
    }
  }

  tags = local.tags
}

resource "aws_iam_role" "backup" {
  count       = var.enable_aws_backup ? 1 : 0
  name_prefix = "${var.name}-backup-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ]
  tags = local.tags
}

resource "aws_backup_selection" "this" {
  count        = var.enable_aws_backup ? 1 : 0
  name         = var.name
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [aws_rds_cluster.this.arn]
}
