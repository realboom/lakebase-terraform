# =============================================================================
# Synced table: UC Delta source -> Postgres public schema.
# =============================================================================
# Replaces the DABs `postgres_synced_tables` resource one-to-one:
#
#   postgres_synced_tables:
#     <stream>_healow_audit:
#       synced_table_id: ${catalog}.public.audit
#       source_table_full_name: system.access.audit
#       postgres_database: databricks_postgres
#       branch: .../branches/production
#       primary_key_columns: [event_id]
#       scheduling_policy: SNAPSHOT
#       create_database_objects_if_missing: true
#       new_pipeline_spec: { storage_catalog, storage_schema }
# =============================================================================

resource "databricks_postgres_synced_table" "this" {
  synced_table_id = "${local.catalog_name}.public.${var.synced_table_leaf}"

  spec = {
    source_table_full_name             = var.synced_source_table
    primary_key_columns                = var.synced_primary_keys
    scheduling_policy                  = "SNAPSHOT"
    postgres_database                  = var.postgres_database
    branch                             = "${databricks_postgres_project.this.name}/branches/production"
    create_database_objects_if_missing = true
    new_pipeline_spec = {
      storage_catalog = var.pg_storage_catalog
      storage_schema  = var.pg_storage_schema
    }
  }

  # The catalog (+ database) must exist before the sync targets it; the deployer
  # needs read on the source (system.access) AND create on the pipeline storage
  # schema (pg_storage_catalog.pg_storage_schema) before the pipeline runs.
  depends_on = [
    databricks_postgres_catalog.this,
    databricks_grant.system_catalog,
    databricks_grant.system_access_schema,
    databricks_grant.pg_storage_catalog,
    databricks_grant.pg_storage_schema,
  ]
}

# --- Scheduled refresh for the SNAPSHOT synced table ---------------------------
# A SNAPSHOT synced table only syncs when its pipeline is triggered, so we wrap
# the generated pipeline in a cron job — exactly what the DABs `jobs:` block does
# with a pipeline_task. The pipeline id comes from the synced table's computed
# status, so nothing is hardcoded.
resource "databricks_job" "refresh" {
  count = var.create_refresh_job ? 1 : 0

  name = "[SH Lakebase] Refresh ${var.value_stream} ${var.synced_table_leaf} snapshot (${var.environment})"

  schedule {
    quartz_cron_expression = var.refresh_cron
    timezone_id            = var.refresh_timezone
    pause_status           = "UNPAUSED"
  }

  task {
    task_key = var.synced_table_leaf
    pipeline_task {
      pipeline_id = databricks_postgres_synced_table.this.status.pipeline_id
    }
  }
}
