# =============================================================================
# Register the Postgres database into Unity Catalog.
# =============================================================================
# Replaces the DABs `postgres_catalogs` resource one-to-one:
#
#   postgres_catalogs:
#     sh_lkb_<stream>_healow:
#       catalog_id: ${env}_sh_lkb_<stream>_healow
#       postgres_database: databricks_postgres
#       branch: ${resources.postgres_projects.sh_lkb_<stream>.id}/branches/production
#       create_database_if_missing: false
#
# databricks_postgres_catalog is the autoscaling-family equivalent — same
# catalog_id / postgres_database / branch / create_database_if_missing fields.
# create_database_if_missing = false for `databricks_postgres` (the default,
# always-present database).
# =============================================================================

resource "databricks_postgres_catalog" "this" {
  catalog_id = local.catalog_name

  spec = {
    postgres_database          = var.postgres_database
    branch                     = "${databricks_postgres_project.this.name}/branches/production"
    create_database_if_missing = false
  }
}
