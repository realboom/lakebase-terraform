# =============================================================================
# Project permissions (control-plane ACL).
# =============================================================================
# Replaces the DABs `permissions:` block on the postgres_project:
#
#   permissions:
#     - service_principal_name: <app SP client id>   # sh-lakebase-app (reused)
#       level: CAN_USE
#     - group_name: SH_LKB_RISK_DEVELOPER            # reused
#       level: CAN_MANAGE
#
# databricks_permissions targets a Lakebase project via `database_project_name`,
# with the two Lakebase levels CAN_USE / CAN_MANAGE. This is the PROJECT ACL
# (platform management) only — NOT Postgres table access. Postgres table/schema
# GRANTs remain data-plane SQL (the setup_data_role / setup_dataapi_role jobs);
# see the README parity table.
#
# Created only when at least one principal variable is set.
# =============================================================================

resource "databricks_permissions" "project" {
  count = (var.app_service_principal_id != "" || var.developer_group != "") ? 1 : 0

  database_project_name = databricks_postgres_project.this.project_id

  dynamic "access_control" {
    for_each = var.app_service_principal_id != "" ? [var.app_service_principal_id] : []
    content {
      service_principal_name = access_control.value
      permission_level       = "CAN_USE"
    }
  }

  dynamic "access_control" {
    for_each = var.developer_group != "" ? [var.developer_group] : []
    content {
      group_name       = access_control.value
      permission_level = "CAN_MANAGE"
    }
  }
}
