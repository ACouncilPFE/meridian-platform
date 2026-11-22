terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 1.0"
    }
  }

  # State: encrypted, versioned S3 bucket with native S3 locking.
  backend "s3" {
    bucket       = "meridian-tfstate-prod"
    key          = "envs/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { "managed-by" = "terraform", "env" = "prod" }
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = { "managed-by" = "terraform", "env" = "prod", "dr" = "true" }
  }
}

# Key-pair auth for a Terraform service user; private key comes from CI secrets.
provider "snowflake" {
  organization_name = var.snowflake_organization
  account_name      = var.snowflake_account
  user              = "TERRAFORM_SVC"
  authenticator     = "SNOWFLAKE_JWT"
  role              = "SYSADMIN"
}
