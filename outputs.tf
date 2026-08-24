# Outputs — the connection + state details the DABs side surfaced via CLI
# (`postgres get-project` / `get-endpoint`), now first-class Terraform outputs.

output "project_id" {
  description = "The Lakebase project id (the instance)."
  value       = databricks_postgres_project.this.project_id
}

output "project_name" {
  description = "Full resource path of the project (projects/<id>)."
  value       = databricks_postgres_project.this.name
}

output "project_uid" {
  description = "Immutable UUID of the project."
  value       = databricks_postgres_project.this.uid
}

output "endpoint_name" {
  description = "Full resource path of the primary read-write endpoint."
  value       = databricks_postgres_endpoint.primary.name
}

output "catalog_name" {
  description = "UC catalog the Postgres database is registered as."
  value       = databricks_postgres_catalog.this.catalog_id
}

output "synced_table" {
  description = "Three-part name of the synced table created in Postgres."
  value       = databricks_postgres_synced_table.this.synced_table_id
}

output "refresh_job_url" {
  description = "URL of the snapshot-refresh job (null when create_refresh_job = false)."
  value       = var.create_refresh_job ? "${var.workspace_host}/jobs/${databricks_job.refresh[0].id}" : null
}

output "data_api_url" {
  description = "Data API base URL (null when enable_data_api = false)."
  value       = var.enable_data_api ? databricks_postgres_data_api.this[0].status.url : null
}

output "enterprise_admin_role" {
  description = "Postgres role name for the enterprise-admin group (superuser). Null when skipped."
  value       = var.enterprise_admin_group != "" ? databricks_postgres_role.enterprise_admin[0].name : null
}

# --- Post-hook wiring (consumed by .github/workflows/deploy.yml) ---------------
output "postgres_database" {
  description = "Postgres database the post-hook grants target."
  value       = var.postgres_database
}

output "developer_group" {
  description = "Developer group to grant SELECT (setup_data_role). Empty = skip."
  value       = var.developer_group
}

output "app_service_principal_id" {
  description = "App SP to wire into the Data API (setup_dataapi_role). Empty = skip."
  value       = var.app_service_principal_id
}

output "setup_data_role_job_id" {
  description = "Job id of the direct-connection data-grant post-hook (null when deploy_posthook = false)."
  value       = var.deploy_posthook ? databricks_job.setup_data_role[0].id : null
}

output "setup_dataapi_role_job_id" {
  description = "Job id of the Data API grant post-hook (null when deploy_posthook = false)."
  value       = var.deploy_posthook ? databricks_job.setup_dataapi_role[0].id : null
}

output "developer_role" {
  description = "Postgres role name for the developer group. Null when skipped."
  value       = var.developer_group != "" ? databricks_postgres_role.developer[0].name : null
}
