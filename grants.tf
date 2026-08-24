# =============================================================================
# UC grants the DEPLOYING identity needs for the synced table.
# =============================================================================
# The synced table's pipeline runs AS the identity that applied this stack. It
# needs TWO sets of UC privileges that workspace admin does NOT imply:
#
#   1. READ on the SOURCE  — USE_CATALOG on `system` + USE_SCHEMA/SELECT on
#      `system.access` (the source of the audit synced table).
#   2. WRITE on the PIPELINE STORAGE — the pipeline creates its checkpoint/event
#      tables in pg_storage_catalog.pg_storage_schema (shlkb_dev.default). That
#      schema is owned by the sh-lakebase cicd SP, so a human deployer needs
#      USE_CATALOG + USE_SCHEMA + CREATE_TABLE there or the pipeline fails with
#      "does not have permission to create table in schema shlkb_dev.default".
#
# In CI the pipeline runs as the cicd SP (which owns shlkb_dev.default and has
# system read via sh-lakebase), so these grants are only strictly needed for a
# local apply as a human — but they are harmless/idempotent for the SP too.
#
# All use the ADDITIVE `databricks_grant` (singular), NOT `databricks_grants`
# (plural, authoritative) — adding one principal's privileges without disturbing
# others on these shared catalogs. Toggle off (manage_source_grants = false) if
# the deployer already has them or lacks authority to grant.
# =============================================================================

data "databricks_current_user" "me" {}

# ---- 1. Read the source (system.access.audit) ----
resource "databricks_grant" "system_catalog" {
  count = var.manage_source_grants ? 1 : 0

  catalog    = "system"
  principal  = data.databricks_current_user.me.user_name
  privileges = ["USE_CATALOG"]
}

resource "databricks_grant" "system_access_schema" {
  count = var.manage_source_grants ? 1 : 0

  schema     = "system.access"
  principal  = data.databricks_current_user.me.user_name
  privileges = ["USE_SCHEMA", "SELECT"]
}

# ---- 2. Write the pipeline checkpoint/event tables (pg_storage_catalog/schema) ----
resource "databricks_grant" "pg_storage_catalog" {
  count = var.manage_source_grants ? 1 : 0

  catalog    = var.pg_storage_catalog
  principal  = data.databricks_current_user.me.user_name
  privileges = ["USE_CATALOG"]
}

resource "databricks_grant" "pg_storage_schema" {
  count = var.manage_source_grants ? 1 : 0

  schema     = "${var.pg_storage_catalog}.${var.pg_storage_schema}"
  principal  = data.databricks_current_user.me.user_name
  privileges = ["USE_SCHEMA", "CREATE_TABLE"]
}
