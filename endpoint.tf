# =============================================================================
# Primary endpoint compute — autoscaling window, scale-to-zero, HA group.
# =============================================================================
# This is the piece the DABs side could NOT declare: the pre-hook created a
# provisioned instance and the post-hook applied the compute window MANUALLY via
#   databricks postgres update-endpoint .../endpoints/primary spec.autoscaling_*
#   databricks postgres update-endpoint .../endpoints/primary spec.group   (prod HA)
# (the risk lakebase_risk.yml even carries a hand-written runbook for it).
#
# The project auto-creates a `primary` read-write endpoint on the `production`
# branch; `replace_existing = true` adopts that endpoint and manages its window
# declaratively — closing the autoscaling gap entirely.
#
#   dev  : autoscaling 0.5 <-> 2 CU per node, scale-to-zero after suspend_timeout
#   prod : autoscaling CU window + HA group of ha_node_count NODES (not CU:
#          3 = 1 primary + 2 readable secondaries), always-on
#
# The CU window (per-node compute) and the group (node count + readable
# secondaries) are orthogonal and coexist — the DABs runbook sets both, in
# separate update-endpoint calls.
# =============================================================================

resource "databricks_postgres_endpoint" "primary" {
  endpoint_id      = "primary"
  parent           = "${databricks_postgres_project.this.name}/branches/production"
  replace_existing = true

  # Optional fields are set to null when not applicable (the provider treats null
  # as unset). HA requires always-on; otherwise honor the scale-to-zero timeout.
  spec = {
    endpoint_type            = "ENDPOINT_TYPE_READ_WRITE"
    autoscaling_limit_min_cu = var.autoscaling_min_cu
    autoscaling_limit_max_cu = var.autoscaling_max_cu

    no_suspension            = var.enable_readable_secondaries ? true : null
    suspend_timeout_duration = (!var.enable_readable_secondaries && var.suspend_timeout != "") ? var.suspend_timeout : null

    # group.min/max are a NODE count (not CU): 3 = 1 primary + 2 readable secondaries.
    group = var.enable_readable_secondaries ? {
      min                         = var.ha_node_count
      max                         = var.ha_node_count
      enable_readable_secondaries = true
    } : null
  }

  lifecycle {
    precondition {
      condition     = var.autoscaling_min_cu <= var.autoscaling_max_cu
      error_message = "autoscaling_min_cu must be <= autoscaling_max_cu."
    }
  }
}
