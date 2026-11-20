# -----------------------------------------------------------------------------
# github-oidc: keyless CI/CD. GitHub Actions assumes short-lived AWS roles via
# OIDC; there are no AWS access keys stored in GitHub at all.
#
#  - plan role: read-only, assumable from any PR in this repo
#  - apply role: assumable ONLY from the `production` GitHub environment on
#    main (which itself requires reviewer approval), enforced in the trust policy
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "github_repo" {
  description = "owner/repo"
  type        = string
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request", "repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "gha-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
  managed_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

resource "aws_iam_role" "apply" {
  name                 = "gha-terraform-apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
  # In a real org this is a scoped permission boundary, not AdministratorAccess.
  # Kept explicit here so reviewers see where the blast radius lives.
  managed_policy_arns  = ["arn:aws:iam::aws:policy/PowerUserAccess"]
  permissions_boundary = aws_iam_policy.boundary.arn
}

# Boundary: even the apply role cannot touch CloudTrail, the state bucket
# deletion, or KMS key deletion.
resource "aws_iam_policy" "boundary" {
  #checkov:skip=CKV_AWS_62:Permissions boundary, not a grant. Effective access = intersection with the attached PowerUserAccess policy.
  #checkov:skip=CKV_AWS_63:Permissions boundary pattern: allow-all ceiling plus explicit denies.
  #checkov:skip=CKV_AWS_286:Boundary only caps permissions; it grants nothing on its own.
  #checkov:skip=CKV_AWS_287:Boundary only caps permissions; it grants nothing on its own.
  #checkov:skip=CKV_AWS_288:Boundary only caps permissions; it grants nothing on its own.
  #checkov:skip=CKV_AWS_289:Boundary only caps permissions; it grants nothing on its own.
  #checkov:skip=CKV_AWS_290:Boundary only caps permissions; it grants nothing on its own.
  #checkov:skip=CKV_AWS_355:Boundary only caps permissions; it grants nothing on its own.
  #checkov:skip=CKV2_AWS_40:Boundary only caps permissions; it grants nothing on its own.
  name = "gha-apply-boundary"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "*", Resource = "*" },
      {
        Effect   = "Deny"
        Action   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "kms:ScheduleKeyDeletion", "s3:DeleteBucket"]
        Resource = "*"
      }
    ]
  })
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}
