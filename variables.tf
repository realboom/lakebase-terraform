# Inputs for the Lakebase-instance stack (autoscaling-native).
#
# This stack models the Lakebase instance as an AUTOSCALING PROJECT — the same
# model the DABs bundle's `postgres_projects` uses. There is no legacy provisioned
# `databricks_database_instance` and no create-then-bind pre-hook: the project is
# the managed resource, and its production branch + primary endpoint are adopted
# declaratively (decision: Marcin, 2026-08-24 — the legacy path was only there to
# unlock Dual Networking, which we don't need here).
#
# One tfvars file = one instance (mirrors the DABs one-file-per-stream model).
# See terraform.tfvars.example for a filled-in `terra` instance.

# --- Target workspace (produced by the sh-lakebase terraform/ component) -------
variable "workspace_host" {
  description = <<-EOT
    Full https:// URL of the EXISTING Databricks workspace to create the Lakebase
    project in. This is the workspace the sh-lakebase `terraform/` component
    created — get it with: terraform -chdir=../sh-lakebase/terraform output -raw workspace_url
    (The One-Env dev workspace host changes on each sandbox rebuild.)
  EOT
  type        = string
}

variable "azure_tenant_id" {
  description = <<-EOT
    Optional Entra tenant id to pin Azure CLI auth to (leave "" to let the
    provider resolve it). Set it when your CLI identity is a guest in multiple
    tenants — e.g. the FE One-Env sandbox tenant dbdevfieldeng.onmicrosoft.com.
  EOT
  type        = string
  default     = ""
}

# --- The Lakebase project (the instance / compute boundary) --------------------
variable "environment" {
  description = "Environment name token (dev/prod). Prefixes the project + catalog names."
  type        = string
  default     = "dev"
}

variable "value_stream" {
  description = <<-EOT
    Instance-name token → <env>-sh-lkb-<token>. Defaults to `terra` (this
    Terraform demo's OWN instance), deliberately distinct from the DABs-managed
    `risk` / `isops` instances that already exist in the shared workspace, so a
    Terraform apply never collides with them.
  EOT
  type        = string
  default     = "terra"
}

variable "pg_version" {
  description = <<-EOT
    PostgreSQL major version. The autoscaling projects API HONORS this (unlike the
    legacy provisioned path, which was pinned to pg16) — so we can finally use 17,
    the version the DABs bundle always declared. Immutable after creation.
  EOT
  type        = number
  default     = 17
}

variable "retention_days" {
  description = "Point-in-time recovery / history retention, in days (2-35). Converted to seconds for the API."
  type        = number
  default     = 7

  validation {
    condition     = var.retention_days >= 2 && var.retention_days <= 35
    error_message = "retention_days must be between 2 and 35."
  }
}

# --- Primary endpoint compute (autoscaling window + scale-to-zero + HA) --------
# These are what the DABs side applied MANUALLY, post-deploy, via
# `postgres update-endpoint` (the pre-hook could not). Here they are declarative.
variable "autoscaling_min_cu" {
  description = "Autoscaling floor in compute units (0.5-64). dev: 0.5."
  type        = number
  default     = 0.5

  validation {
    condition     = var.autoscaling_min_cu >= 0.5 && var.autoscaling_min_cu <= 64
    error_message = "autoscaling_min_cu must be between 0.5 and 64."
  }
}

variable "autoscaling_max_cu" {
  description = "Autoscaling ceiling in compute units (0.5-64; max-min <= 16 typical). dev: 2."
  type        = number
  default     = 2

  validation {
    condition     = var.autoscaling_max_cu >= 0.5 && var.autoscaling_max_cu <= 64
    error_message = "autoscaling_max_cu must be between 0.5 and 64."
  }
}

variable "suspend_timeout" {
  description = <<-EOT
    Scale-to-zero idle timeout, e.g. "300s" (5m) .. "604800s" (7d). Applied only
    when enable_readable_secondaries = false (HA requires always-on). "" leaves
    the endpoint's suspend setting untouched.
  EOT
  type        = string
  default     = "300s"
}

variable "enable_readable_secondaries" {
  description = <<-EOT
    prod HA group: 1 primary + readable secondaries (min = max = ha_node_count).
    Requires always-on, so this forces no_suspension = true on the endpoint.
    Reproduces the DABs prod runbook's `update-endpoint spec.group` — declaratively.
  EOT
  type        = bool
  default     = false
}

variable "ha_node_count" {
  description = "Node count for the HA group when enable_readable_secondaries = true (3 = 1 primary + 2 readable secondaries)."
  type        = number
  default     = 3
}

# --- UC catalog registration ----------------------------------------------------
variable "postgres_database" {
  description = <<-EOT
    Postgres database inside the project to register into Unity Catalog.
    `databricks_postgres` is the default, auto-provisioned database (always
    exists) — so create_database_if_missing stays false for it, matching the DABs
    postgres_catalogs entry.
  EOT
  type        = string
  default     = "databricks_postgres"
}

variable "default_database_id" {
  description = <<-EOT
    Resource id of the project's default, auto-provisioned database, used to
    build the Data API parent path. NOTE the hyphen: the resource id is
    `databricks-postgres` even though the Postgres database NAME (postgres_database
    above) is `databricks_postgres` with an underscore.
  EOT
  type        = string
  default     = "databricks-postgres"
}

variable "catalog_name" {
  description = <<-EOT
    UC catalog name the Postgres database is registered as. Underscores only
    (hyphens are illegal in catalog names). Leave "" to DERIVE it from the
    instance tokens as <env>_sh_lkb_<value_stream>_healow (e.g. dev + terra ->
    dev_sh_lkb_terra_healow) so it can never drift from the project name when
    environment/value_stream change. Set a literal to override.
  EOT
  type        = string
  default     = ""
}

# --- Synced table (UC Delta source -> Postgres) --------------------------------
variable "synced_source_table" {
  description = "Three-part UC name of the Delta source table to sync into Postgres."
  type        = string
  default     = "system.access.audit"
}

variable "synced_table_leaf" {
  description = "Leaf table name created in the catalog's public schema (the sync target)."
  type        = string
  default     = "audit"
}

variable "synced_primary_keys" {
  description = "Primary-key column(s) for the synced table."
  type        = list(string)
  default     = ["event_id"]
}

variable "pg_storage_catalog" {
  description = <<-EOT
    UC catalog where the synced-table PIPELINE stores its checkpoints/event logs
    (NOT the synced data — that lives in Postgres). This is the sh-lakebase
    project catalog: terraform -chdir=../sh-lakebase/terraform output -raw catalog_name
    (dev -> shlkb_dev). For a real customer, their bronze/medallion catalog.
  EOT
  type        = string
  default     = "shlkb_dev"
}

variable "pg_storage_schema" {
  description = "Schema under pg_storage_catalog for pipeline state."
  type        = string
  default     = "default"
}

variable "deploy_posthook" {
  description = <<-EOT
    Deploy the post-hook notebooks (src/*.py) + their jobs — the data-plane GRANTs
    Terraform can't express. The GitHub Actions pipeline runs them after apply.
    Set false to skip them (e.g. a pure infra-only demo).
  EOT
  type        = bool
  default     = true
}

variable "posthook_workspace_dir" {
  description = "Workspace directory the post-hook notebooks are deployed to."
  type        = string
  default     = "/Workspace/Shared/lakebase-terraform"
}

variable "manage_source_grants" {
  description = <<-EOT
    Grant the deploying identity USE_CATALOG on `system` + USE_SCHEMA/SELECT on
    `system.access` (the synced-table source) via additive databricks_grant.
    Set false if the deployer already has that read, or lacks authority to grant
    on `system` (grant it out-of-band instead).
  EOT
  type        = bool
  default     = true
}

variable "enable_data_api" {
  description = <<-EOT
    Enable the Data API on the database (replaces the manual "Enable Data API"
    click). This enables the API surface only — the GRANT <sp> TO authenticator
    is still the setup_dataapi_role job.
  EOT
  type        = bool
  default     = true
}

variable "data_api_schemas" {
  description = "Postgres schemas the Data API exposes."
  type        = list(string)
  default     = ["public"]
}

variable "create_refresh_job" {
  description = <<-EOT
    Whether to create the scheduled refresh job for the SNAPSHOT synced table.
    A SNAPSHOT synced table only syncs when its pipeline is triggered, so the
    DABs side wraps the pipeline in a cron job; this reproduces that.
  EOT
  type        = bool
  default     = true
}

variable "refresh_cron" {
  description = "Quartz cron for the refresh job. Default: daily 09:00 America/Denver."
  type        = string
  default     = "0 0 9 * * ?"
}

variable "refresh_timezone" {
  description = "Timezone id for the refresh cron."
  type        = string
  default     = "America/Denver"
}

# --- Permissions (scoped to this project) --------------------------------------
# Mirrors the DABs `permissions:` block on the postgres_project:
#   app SP        -> CAN_USE   (discover the project + read the connection URI)
#   developer grp -> CAN_MANAGE
variable "app_service_principal_id" {
  description = <<-EOT
    Application (client) id of the app service principal granted CAN_USE on the
    project. We REUSE the existing sh-lakebase-app SP (the same one the risk
    stream uses) — no new SP is created for this demo. This client id changes on
    a sandbox rebuild; refresh it with:
      terraform -chdir=../sh-lakebase/terraform output -raw app_client_id
    Set it in terraform.tfvars (see the example). Leave "" to skip the SP grant.
  EOT
  type        = string
  default     = ""
}

variable "developer_group" {
  description = <<-EOT
    Databricks account group granted CAN_MANAGE on the project (ACL) AND given a
    plain Postgres login role (roles.tf). We REUSE the existing
    SH_LKB_RISK_DEVELOPER group (created by sh-lakebase terraform/groups.tf)
    rather than create a `terra` group. Its read-only table SELECT grants still
    come from the setup_data_role job. Leave "" to skip both.
  EOT
  type        = string
  default     = "SH_LKB_RISK_DEVELOPER"
}

variable "enterprise_admin_group" {
  description = <<-EOT
    Databricks account group granted the Postgres `databricks_superuser` role +
    all attributes (createdb / createrole / bypassrls) via roles.tf. Mirrors the
    DABs pre-hook's --admin-group (default SH_ENTERPRISE_ADMIN). Leave "" to skip.
  EOT
  type        = string
  default     = "SH_ENTERPRISE_ADMIN"
}

variable "custom_tags" {
  description = <<-EOT
    Extra custom tags applied to the project (cost attribution / provenance).
    `environment` and `value_stream` are added automatically from those variables
    (see main.tf) so they never drift — do not set them here.
  EOT
  type        = map(string)
  default = {
    project     = "sh-lakebase"
    cost_center = "data-architecture"
    managed_by  = "terraform"
  }
}
