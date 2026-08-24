# =============================================================================
# Enable the Data API on the database.
# =============================================================================
# Replaces the manual "Enable Data API" click that the DABs side requires as a
# PREREQUISITE before running setup_dataapi_role. Creating this resource stands
# up the Data API machinery on the database (the `authenticator` role, the
# `pgrst` schema, and the `pre_config` function); deleting it disables the API.
#
# IMPORTANT — this ENABLES the API surface; it does NOT grant a service principal
# into it. The actual `GRANT <sp> TO authenticator` + table/sequence DML is
# Postgres SQL and still runs in the DABs setup_dataapi_role job (the Databricks
# provider runs no SQL inside Postgres). So this removes the click, not the job.
#
# `parent` is the DATABASE resource path:
#   projects/<project_id>/branches/<branch>/databases/<database_id>
# Note the default database's resource id is `databricks-postgres` (HYPHEN),
# while its Postgres database name is `databricks_postgres` (underscore).
# =============================================================================

resource "databricks_postgres_data_api" "this" {
  count = var.enable_data_api ? 1 : 0

  parent = "${databricks_postgres_project.this.name}/branches/production/databases/${var.default_database_id}"

  spec = {
    db_schemas = var.data_api_schemas
  }
}
