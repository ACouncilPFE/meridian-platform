# -----------------------------------------------------------------------------
# dynamodb-table: paved-road DynamoDB table
#  - CMK encryption, PITR (35-day continuous backups), deletion protection
#  - Optional global table replicas for multi-region DR
#  - Streams on by default (CDC into Snowflake / audit pipeline)
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "this" {
  name                        = var.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = var.hash_key
  range_key                   = var.range_key
  deletion_protection_enabled = var.deletion_protection
  stream_enabled              = true
  stream_view_type            = "NEW_AND_OLD_IMAGES"

  dynamic "attribute" {
    for_each = var.attributes
    content {
      name = attribute.key
      type = attribute.value
    }
  }

  dynamic "global_secondary_index" {
    for_each = var.global_secondary_indexes
    content {
      name            = global_secondary_index.key
      hash_key        = global_secondary_index.value.hash_key
      range_key       = global_secondary_index.value.range_key
      projection_type = global_secondary_index.value.projection_type
    }
  }

  ttl {
    enabled        = var.ttl_attribute != null
    attribute_name = var.ttl_attribute != null ? var.ttl_attribute : ""
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region_name            = replica.value.region
      kms_key_arn            = replica.value.kms_key_arn
      point_in_time_recovery = true
    }
  }

  tags = merge(var.tags, {
    "platform:module"     = "dynamodb-table"
    "data:classification" = var.data_classification
  })
}
