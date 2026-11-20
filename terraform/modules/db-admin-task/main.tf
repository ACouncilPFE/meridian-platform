# -----------------------------------------------------------------------------
# db-admin-task: a one-off ECS task definition (no service) that holds the
# Aurora master credential and nothing else does.
#
# It runs `python -m intake_api.admin` from the SAME image as the release:
# creates IAM-auth login roles, runs Alembic as the schema owner, then grants
# runtime roles least privilege. CI/scripts start it with `aws ecs run-task`
# before shifting traffic. The API's task role never sees the master secret.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  family = "${var.environment}-${var.name}-db-admin"
  tags   = merge(var.tags, { "platform:module" = "db-admin-task" })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.environment}/${var.name}-db-admin"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-dbadm-exec-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Only the execution role (used by the ECS agent to inject the secret) can
# read the master password; the container's task role has no permissions.
data "aws_iam_policy_document" "master_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.master_secret_arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.master_secret_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "master_secret" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.master_secret.json
}

resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-dbadm-task-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name                   = "db-admin"
    image                  = var.image
    essential              = true
    readonlyRootFilesystem = true
    user                   = "10001"
    entryPoint             = ["python", "-m", "intake_api.admin"]
    environment = [
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_ADMIN_USER", value = var.db_admin_user },
      { name = "APP_DB_USER", value = var.app_db_user },
      { name = "VERIFIER_DB_USER", value = var.verifier_db_user },
    ]
    secrets = [
      { name = "DB_MASTER_PASSWORD", valueFrom = "${var.master_secret_arn}:password::" },
    ]
    mountPoints = [{ sourceVolume = "tmp", containerPath = "/tmp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "db-admin"
      }
    }
  }])

  volume {
    name = "tmp"
  }

  tags = local.tags
}
