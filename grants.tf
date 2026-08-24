# =============================================================================
# UC read grants on the synced-table SOURCE catalog.
# =============================================================================
# The synced table sources from `system.access.audit`; creating it requires the
# deploying identity to hold USE_CATALOG on `system` and USE_SCHEMA + SELECT on
# `system.access` (workspace admin does NOT imply UC privileges). The DABs side
# grants this to the CI/CD SP in sh-lakebase/terraform/catalog.tf — this stack
# grants the equivalent to whoever is running Terraform, so the demo is
# self-contained.
#
# Uses the ADDITIVE `databricks_grant` (singular), NOT `databricks_grants`
# (plural, authoritative) — so it adds this one principal's privileges without
# disturbing other grants on the shared `system` catalog.
#
# Toggle off (manage_source_grants = false) if the deployer already has system
# read, or lacks authority to grant on `system` (then grant it out-of-band).
# =============================================================================

data "databricks_current_user" "me" {}

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
