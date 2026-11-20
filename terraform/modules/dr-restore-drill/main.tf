# -----------------------------------------------------------------------------
# dr-restore-drill: automated, scheduled proof that backups actually restore.
#
# Step Functions state machine (weekly via EventBridge Scheduler):
#   1. Read the cluster's latest restorable time (continuous backup / PITR)
#   2. Restore to a throwaway cluster in isolated subnets
#   3. Wait until available, add an instance, wait again
#   4. Lambda runs integrity checks (row counts, migration version, checksum
#      of reference tables) and pushes RTO/RPO metrics to Prometheus
#   5. Tear the cluster down (always: Catch -> Cleanup)
#
# The output (measured RTO, RPO, pass/fail) is SOC 2 A1.2/A1.3 evidence and
# feeds the `DRDrillFailed` / `DRDrillStale` Prometheus alerts.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  adot_layer_arn = coalesce(
    var.adot_python_layer_arn,
    "arn:aws:lambda:${data.aws_region.current.name}:901920570463:layer:aws-otel-python-arm64-ver-1-32-0:2",
  )
  tags          = merge(var.tags, { "platform:module" = "dr-restore-drill" })
  drill_cluster = "${var.source_cluster_id}-drill"
}

# --- Lambda: verification ----------------------------------------------------
data "archive_file" "verify" {
  type        = "zip"
  source_dir  = var.lambda_source_dir # built by `make lambda-build` (vendors psycopg)
  output_path = "${path.module}/.build/verify.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

resource "aws_iam_role" "lambda" {
  name_prefix = "dr-drill-verify-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole",
    "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess", # required by tracing_config Active
  ]
  tags = local.tags
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:*/dr_verifier"
      },
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBClusters"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = var.amp_workspace_arn
      }
    ]
  })
}

resource "aws_security_group" "lambda" {
  name_prefix = "dr-drill-verify-"
  vpc_id      = var.vpc_id
  description = "DR verify lambda"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_lambda_function" "verify" {
  function_name    = "${var.source_cluster_id}-dr-verify"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.verify.output_path
  source_code_hash = data.archive_file.verify.output_base64sha256
  timeout          = 300
  memory_size      = 512
  kms_key_arn      = var.kms_key_arn
  layers           = [local.adot_layer_arn] # ADOT: OTel SDK + collector extension

  # Private (app-tier) subnets: the function needs egress to AMP for metrics
  # and reaches the restored cluster through an explicit SG rule (see outputs).
  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      AWS_LAMBDA_EXEC_WRAPPER            = "/opt/otel-instrument"
      OPENTELEMETRY_COLLECTOR_CONFIG_URI = "/var/task/collector.yaml"
      AMP_REMOTE_WRITE_URL               = "${var.amp_remote_write_endpoint}api/v1/remote_write"
      EXPECTED_ALEMBIC_HEAD              = var.expected_alembic_head
      EXPECTED_TABLES                    = join(",", var.expected_tables)
      DB_NAME                            = var.database_name
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.tags
}

# --- Step Functions ----------------------------------------------------------
resource "aws_iam_role" "sfn" {
  name_prefix = "dr-drill-sfn-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "sfn" {
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds:DescribeDBClusters",
          "rds:DescribeDBInstances",
          "rds:RestoreDBClusterToPointInTime",
          "rds:CreateDBInstance",
          "rds:DeleteDBInstance",
          "rds:DeleteDBCluster",
          "rds:AddTagsToResource",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Decrypt", "kms:GenerateDataKey*"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.verify.arn
      },
      {
        # Required because tracing_configuration is enabled on the state machine.
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.source_cluster_id}-dr-drill"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_sfn_state_machine" "drill" {
  name     = "${var.source_cluster_id}-dr-drill"
  role_arn = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/state-machine.asl.json", {
    source_cluster_id = var.source_cluster_id
    drill_cluster_id  = local.drill_cluster
    subnet_group_name = var.db_subnet_group_name
    security_group_id = var.drill_security_group_id
    kms_key_arn       = var.kms_key_arn
    verify_lambda_arn = aws_lambda_function.verify.arn
    instance_class    = var.drill_instance_class
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false # execution data could include connection metadata
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.tags
}

# --- Schedule ----------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name_prefix = "dr-drill-sched-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
  inline_policy {
    name = "start"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.drill.arn
      }]
    })
  }
  tags = local.tags
}

resource "aws_scheduler_schedule" "weekly" {
  name                         = "${var.source_cluster_id}-dr-drill"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "America/New_York"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.drill.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ trigger = "schedule" })
  }
}
