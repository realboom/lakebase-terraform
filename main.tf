# =============================================================================
# The Lakebase instance — as an AUTOSCALING PROJECT.
# =============================================================================
# This ONE resource replaces the entire DABs create path:
#
#   pre-hook:  databricks database create-database-instance <name> --capacity CU_1
#              databricks bundle deployment bind sh_lkb_<stream> projects/<name>
#   bundle:    postgres_projects: { sh_lkb_<stream>: {...} }
#
# `databricks_postgres_project` IS the autoscaling project the bundle declared —
# so there is no legacy provisioned instance and NO create-then-bind dance. The
# project's `production` branch and primary read-write endpoint are auto-created;
# the endpoint's compute window is adopted declaratively in endpoint.tf.
#
# pg_version is honored here (17) — the whole reason the DABs bundle needed the
# pre-hook was the legacy provisioned path (pg16-only) that unlocked Dual
# Networking. Going autoscaling-native drops both that path and its version pin.
# =============================================================================

locals {
  # dev-sh-lkb-terra  (hyphens — project/endpoint names are DNS-safe; underscores
  # illegal). `terra` is this demo's own instance, kept distinct from the
  # DABs-managed risk/isops projects that already exist in the shared workspace.
  project_id = "${var.environment}-sh-lkb-${var.value_stream}"

  # UC catalog name: underscores only. Derived from the same tokens as the project
  # (so it can't drift when environment/value_stream change) unless overridden.
  catalog_name = var.catalog_name != "" ? var.catalog_name : "${var.environment}_sh_lkb_${var.value_stream}_healow"

  # environment + value_stream tags are derived from the vars (never hand-set in
  # var.custom_tags) so cost/provenance tags always track the actual instance.
  project_tags = merge(var.custom_tags, {
    environment  = var.environment
    value_stream = var.value_stream
  })
}

resource "databricks_postgres_project" "this" {
  project_id = local.project_id

  spec = {
    display_name               = "SH Lakebase ${var.value_stream} (${var.environment})"
    pg_version                 = var.pg_version
    history_retention_duration = "${var.retention_days * 86400}s"

    custom_tags = [for k, v in local.project_tags : { key = k, value = v }]
  }
}
