# -----------------------------------------------------------------------------
# ecs-fargate-service: the "paved road" for running a containerized service.
# A product team supplies an image + a handful of inputs and gets, by default:
#  - Private-subnet Fargate tasks behind an internal/external ALB (TLS 1.2+ only)
#  - Least-privilege task role, read-only root FS, non-root user
#  - AWS Distro for OpenTelemetry (ADOT) sidecar: scrapes /metrics and
#    remote-writes to Amazon Managed Prometheus (SigV4), forwards OTLP traces
#  - Deployment circuit breaker with automatic rollback
#  - Target-tracking autoscaling
#  - Secrets injected from Secrets Manager / SSM, never baked into images
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  tags = merge(var.tags, {
    "platform:module"     = "ecs-fargate-service"
    "service"             = var.name
    "data:classification" = var.data_classification
  })

  tls           = var.certificate_arn != null
  listener_port = local.tls ? 443 : 80

  adot_config = templatefile("${path.module}/adot-config.yaml.tftpl", {
    service_name    = var.name
    environment     = var.environment
    app_port        = var.container_port
    metrics_path    = var.metrics_path
    amp_endpoint    = var.amp_remote_write_endpoint
    region          = data.aws_region.current.name
    traces_endpoint = var.traces_otlp_endpoint
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.environment}/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

# --- IAM ---------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
    resources = values(var.secrets)
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = var.secrets_kms_key_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = length(var.secrets) > 0 ? 1 : 0
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

# Every service can remote-write its own metrics; nothing more by default.
data "aws_iam_policy_document" "task_observability" {
  statement {
    actions   = ["aps:RemoteWrite"]
    resources = [var.amp_workspace_arn]
  }
  statement {
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_observability" {
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_observability.json
}

resource "aws_iam_role_policy" "task_extra" {
  count  = var.task_policy_json == null ? 0 : 1
  role   = aws_iam_role.task.id
  policy = var.task_policy_json
}

# --- Networking --------------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  vpc_id      = var.vpc_id
  description = "ALB for ${var.name}"
  tags        = local.tags

  ingress {
    description = local.tls ? "HTTPS" : "HTTP (demo only: no certificate, synthetic data)"
    from_port   = local.listener_port
    to_port     = local.listener_port
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  egress {
    description = "To tasks"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_security_group" "service" {
  name_prefix = "${var.name}-svc-"
  vpc_id      = var.vpc_id
  description = "Tasks for ${var.name}"
  tags        = local.tags

  ingress {
    description     = "From ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "HTTPS egress (VPC endpoints, AMP, NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Postgres within VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Temporal frontend within VPC"
    from_port   = 7233
    to_port     = 7233
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_lb" "this" {
  name                       = substr("${var.environment}-${var.name}", 0, 32)
  internal                   = var.internal
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.internal ? var.private_subnet_ids : var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"

  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket == null ? [] : [1]
    content {
      bucket  = var.alb_access_logs_bucket
      prefix  = var.name
      enabled = true
    }
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !(var.environment == "prod" && var.certificate_arn == null)
      error_message = "prod services must terminate TLS: set certificate_arn."
    }
  }
}

resource "aws_lb_target_group" "this" {
  name_prefix          = substr(replace(var.name, "-", ""), 0, 6)
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    matcher             = "200"
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "https" {
  count             = local.tls ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Plain-HTTP listener exists only when no certificate is supplied (demo envs).
# A precondition on aws_lb fails the plan if prod omits certificate_arn.
resource "aws_lb_listener" "http" {
  count             = local.tls ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# --- Task definition ---------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.environment}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name                   = var.name
      image                  = var.image
      essential              = true
      readonlyRootFilesystem = true
      user                   = "10001"
      portMappings           = [{ containerPort = var.container_port, protocol = "tcp" }]
      environment = [for k, v in merge(var.environment_variables, {
        AWS_REGION                  = data.aws_region.current.name
        SERVICE_NAME                = var.name
        DEPLOY_ENV                  = var.environment
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4317"
        OTEL_SERVICE_NAME           = var.name
        OTEL_RESOURCE_ATTRIBUTES    = "deployment.environment=${var.environment}"
      }) : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]
      mountPoints = [{ sourceVolume = "tmp", containerPath = "/tmp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "app"
        }
      }
      dependsOn = [{ containerName = "otel-collector", condition = "START" }]
    },
    {
      name      = "otel-collector"
      image     = var.adot_image
      essential = false
      command   = ["--config=env:ADOT_CONFIG"]
      environment = [
        { name = "ADOT_CONFIG", value = local.adot_config },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "otel"
        }
      }
    }
  ])

  volume {
    name = "tmp"
  }

  tags = local.tags
}

resource "aws_ecs_service" "this" {
  name                   = var.name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.min_count
  launch_type            = "FARGATE"
  enable_execute_command = false # no interactive shells into PHI-bearing containers
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = concat([aws_security_group.service.id], var.additional_security_group_ids)
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count] # owned by autoscaling
  }

  tags = local.tags
}

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
