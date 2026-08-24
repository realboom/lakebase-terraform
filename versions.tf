# Provider + version pins.
#
# This stack manages ONLY the Lakebase instance and the objects it owns — the
# database instance, its UC (database) catalog registration, and synced tables.
# It does NOT create the Azure substrate (workspace, Key Vault, UC metastore,
# service principals). That substrate is stood up separately by the sh-lakebase
# `terraform/` component; this stack POINTS AT the workspace it produced.
#
# databricks is pinned to the same major line as the sh-lakebase infra stack
# (~> 1.50) so both sides resolve a compatible provider.

terraform {
  required_version = ">= 1.5"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}
