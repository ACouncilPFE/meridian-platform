output "database_name" {
  value = snowflake_database.this.name
}

output "loader_role" {
  value = snowflake_account_role.roles["LOADER"].name
}

output "storage_integration_name" {
  value = snowflake_storage_integration.s3.name
}
