terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73" # Aurora Serverless v2 scale-to-zero
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Local state: the demo is short-lived and single-operator. (prod uses an
  # encrypted, versioned S3 backend with locking.) The state file is gitignored.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { "managed-by" = "terraform", "env" = "demo", "repo" = "meridian-platform" }
  }
}
