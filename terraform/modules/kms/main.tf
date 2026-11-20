# -----------------------------------------------------------------------------
# kms: one customer-managed key per data classification.
# Separate keys let us revoke/rotate PHI access independently of ops data and
# give auditors a clean answer to "who can decrypt PHI?" (key policy = the list).
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_root = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:KMS key policies must use Resource "*" (it means "this key"); the AccountAdmin statement is AWS's required default to prevent unmanageable keys.
  #checkov:skip=CKV_AWS_111:Same: key-policy Resource "*" refers only to the key the policy is attached to.
  #checkov:skip=CKV_AWS_356:Same: key-policy Resource "*" refers only to the key the policy is attached to.
  for_each = var.keys

  # Account root retains administrative control (prevents unrecoverable keys).
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  # Only explicitly listed principals may use the key for crypto operations.
  dynamic "statement" {
    for_each = length(each.value.user_principal_arns) > 0 ? [1] : []
    content {
      sid       = "AllowUse"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = each.value.user_principal_arns
      }
    }
  }

  # AWS services (RDS, DynamoDB, SNS...) acting on our behalf, scoped to this account.
  dynamic "statement" {
    for_each = length([for p in each.value.service_principals : p if !startswith(p, "logs.")]) > 0 ? [1] : []
    content {
      sid       = "AllowServices"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = [for p in each.value.service_principals : p if !startswith(p, "logs.")]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # CloudWatch Logs is scoped by the log-group ARN in the encryption context
  # (the documented pattern for KMS-encrypted log groups).
  dynamic "statement" {
    for_each = [for p in each.value.service_principals : p if startswith(p, "logs.")]
    content {
      sid       = "AllowCloudWatchLogs${replace(statement.value, "/[^A-Za-z0-9]/", "")}"
      actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = [statement.value]
      }
      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:*"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  for_each                = var.keys
  description             = "${var.name} ${each.key}: ${each.value.description}"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  multi_region            = each.value.multi_region
  policy                  = data.aws_iam_policy_document.key[each.key].json
  tags = merge(var.tags, {
    "data:classification" = each.value.classification
    "platform:module"     = "kms"
  })
}

resource "aws_kms_alias" "this" {
  for_each      = var.keys
  name          = "alias/${var.name}/${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
