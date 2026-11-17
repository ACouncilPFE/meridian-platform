terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # One state file per workspace (pr-<n>) under env:/ prefix.
  backend "s3" {
    bucket       = "meridian-tfstate-dev"
    key          = "envs/ephemeral/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { "managed-by" = "terraform", "env" = "ephemeral" }
  }
}
