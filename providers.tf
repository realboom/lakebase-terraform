# Single workspace-plane Databricks provider, pointed at the EXISTING workspace
# that the sh-lakebase `terraform/` component created. There is no account-plane
# provider here: we are not assigning metastores or registering SPs — only
# creating a Lakebase instance and its objects inside a workspace that already
# has Unity Catalog and its groups/SPs in place.
#
# Auth resolves automatically from the environment, so this file stays portable:
#   • Local demo:  `az login --tenant <tenant>` then run terraform — the provider
#                  uses your Azure CLI identity (auth_type azure-cli).
#   • CI / SP:     export DATABRICKS_CLIENT_ID + DATABRICKS_CLIENT_SECRET
#                  (OAuth M2M) — the SAME creds the DABs pipeline uses.
#   • PAT:         export DATABRICKS_TOKEN.
#
# azure_tenant_id is optional: set it (var.azure_tenant_id) only when the CLI
# identity is a guest in more than one tenant and the account/workspace rejects a
# token minted from the wrong one — the exact pin the sh-lakebase infra stack uses.

provider "databricks" {
  host            = var.workspace_host
  azure_tenant_id = var.azure_tenant_id != "" ? var.azure_tenant_id : null
}
