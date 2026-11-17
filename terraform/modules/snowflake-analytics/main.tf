# -----------------------------------------------------------------------------
# snowflake-analytics: governed analytics landing zone for de-identified data.
#  - RAW (loader-only) and CURATED (analyst-readable) schemas
#  - Functional roles: LOADER (Temporal pipeline), TRANSFORMER, ANALYST
#  - Dynamic data masking on any residual quasi-identifiers: only the
#    PHI_PRIVILEGED role sees clear text; everyone else sees hashes
#  - Network policy: only the platform NAT egress IPs can authenticate
#  - Storage integration so Snowflake reads from the KMS-encrypted S3 stage
#    via an IAM role (no long-lived AWS keys inside Snowflake)
# -----------------------------------------------------------------------------

locals {
  db = upper("${var.name}_ANALYTICS")
}

resource "snowflake_database" "this" {
  name                        = local.db
  comment                     = "De-identified clinical analytics (managed by Terraform)"
  data_retention_time_in_days = 30 # Time Travel: point-in-time recovery for analytics
}

resource "snowflake_schema" "raw" {
  database = snowflake_database.this.name
  name     = "RAW"
  comment  = "Landing zone. Written only by LOADER."
}

resource "snowflake_schema" "curated" {
  database = snowflake_database.this.name
  name     = "CURATED"
  comment  = "Modeled tables for analysts."
}

resource "snowflake_warehouse" "load" {
  name           = "${local.db}_LOAD_WH"
  warehouse_size = "XSMALL"
  auto_suspend   = 60
  auto_resume    = true
}

resource "snowflake_warehouse" "analyst" {
  name           = "${local.db}_ANALYST_WH"
  warehouse_size = var.analyst_warehouse_size
  auto_suspend   = 120
  auto_resume    = true
}

resource "snowflake_account_role" "roles" {
  for_each = toset(["LOADER", "TRANSFORMER", "ANALYST", "PHI_PRIVILEGED"])
  name     = "${local.db}_${each.key}"
}

resource "snowflake_grant_privileges_to_account_role" "loader_raw" {
  account_role_name = snowflake_account_role.roles["LOADER"].name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE STAGE"]
  on_schema {
    schema_name = "\"${snowflake_database.this.name}\".\"${snowflake_schema.raw.name}\""
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_curated" {
  account_role_name = snowflake_account_role.roles["ANALYST"].name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = "\"${snowflake_database.this.name}\".\"${snowflake_schema.curated.name}\""
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_future_select" {
  account_role_name = snowflake_account_role.roles["ANALYST"].name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = "\"${snowflake_database.this.name}\".\"${snowflake_schema.curated.name}\""
    }
  }
}

resource "snowflake_masking_policy" "quasi_identifier" {
  name     = "MASK_QUASI_IDENTIFIER"
  database = snowflake_database.this.name
  schema   = snowflake_schema.curated.name
  argument {
    name = "VAL"
    type = "VARCHAR"
  }
  return_data_type = "VARCHAR"
  body             = <<-SQL
    CASE
      WHEN IS_ROLE_IN_SESSION('${snowflake_account_role.roles["PHI_PRIVILEGED"].name}') THEN VAL
      ELSE SHA2(VAL, 256)
    END
  SQL
  comment          = "Hashes quasi-identifiers (zip3, birth_year) for non-privileged roles."
}

resource "snowflake_network_policy" "platform" {
  name            = "${local.db}_PLATFORM_ONLY"
  allowed_ip_list = var.allowed_ip_cidrs
  comment         = "Service users may only authenticate from platform NAT egress."
}

resource "snowflake_storage_integration" "s3" {
  name                      = "${local.db}_S3_INT"
  type                      = "EXTERNAL_STAGE"
  storage_provider          = "S3"
  enabled                   = true
  storage_aws_role_arn      = var.snowflake_s3_role_arn
  storage_allowed_locations = ["s3://${var.export_bucket}/deidentified/"]
}
