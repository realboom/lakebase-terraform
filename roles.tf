# =============================================================================
# Postgres OAuth roles for the account groups.
# =============================================================================
# Replaces the DABs pre-hook's grant_admin_superuser() (the control-plane role
# API: create-role + update-role), done declaratively.
#
#   • enterprise admin group -> DATABRICKS_SUPERUSER membership + role attributes
#     (createdb / createrole / bypassrls). Attributes are NOT inherited through
#     membership in Postgres, so they're set directly on the role — same reason
#     the pre-hook sets both in one update-role call.
#   • risk developer group   -> a plain login role (no superuser, no attributes).
#     Its read-only TABLE grants (SELECT) are Postgres SQL and still come from the
#     setup_data_role job — this resource just establishes the role principal the
#     grants target.
#
# role_id is derived the same way the pre-hook does: "grp-" + the group name
# lowercased with non-alphanumerics collapsed to hyphens. replace_existing adopts
# a role a prior run / the SQL path may already have created.
#
# NOTE ON OWNERSHIP: with Terraform managing these role principals, the
# setup_data_role / setup_dataapi_role jobs should do ONLY the table/authenticator
# GRANTs, not re-create the roles, to avoid two owners of the same object.
# =============================================================================

locals {
  production_branch     = "${databricks_postgres_project.this.name}/branches/production"
  admin_role_id         = "grp-${lower(replace(var.enterprise_admin_group, "/[^A-Za-z0-9-]/", "-"))}"
  dev_role_id           = "grp-${lower(replace(var.developer_group, "/[^A-Za-z0-9-]/", "-"))}"
  abac_exempt_role_id   = "grp-${lower(replace(var.abac_exempt_group, "/[^A-Za-z0-9-]/", "-"))}"
  abac_restrict_role_id = "grp-${lower(replace(var.abac_restricted_group, "/[^A-Za-z0-9-]/", "-"))}"
}

# --- Enterprise admin: databricks_superuser + all role attributes --------------
resource "databricks_postgres_role" "enterprise_admin" {
  count = var.enterprise_admin_group != "" ? 1 : 0

  role_id          = local.admin_role_id
  parent           = local.production_branch
  replace_existing = true

  spec = {
    identity_type    = "GROUP"
    postgres_role    = var.enterprise_admin_group
    auth_method      = "LAKEBASE_OAUTH_V1"
    membership_roles = ["DATABRICKS_SUPERUSER"]
    attributes = {
      createdb   = true
      createrole = true
      bypassrls  = true
    }
  }
}

# --- Risk developer: plain login role (table SELECT grants come via notebook) --
resource "databricks_postgres_role" "developer" {
  count = var.developer_group != "" ? 1 : 0

  role_id          = local.dev_role_id
  parent           = local.production_branch
  replace_existing = true

  spec = {
    identity_type = "GROUP"
    postgres_role = var.developer_group
    auth_method   = "LAKEBASE_OAUTH_V1"
  }
}

# --- ABAC masking groups: OAuth GROUP roles so real SelectHealth group members --
#     map into them over OAuth. The masking VIEW keys off pg_has_role(current_user,
#     'SCRP_ABAC_EXEMPT','member'); the SELECT-on-view GRANTs (data-plane SQL) come
#     from the setup_abac_masking job — these resources just establish the two role
#     principals. postgres_role = the group name, so the view's role check and the
#     grants both reference the same identifier.
#     NOTE: a control-plane GROUP role cannot be SET ROLE'd into by its creator, so
#     masking is verified from a real group member's OAuth session (not the admin SP).
resource "databricks_postgres_role" "abac_exempt" {
  count = var.deploy_abac_demo && var.abac_exempt_group != "" ? 1 : 0

  role_id          = local.abac_exempt_role_id
  parent           = local.production_branch
  replace_existing = true

  spec = {
    identity_type = "GROUP"
    postgres_role = var.abac_exempt_group
    auth_method   = "LAKEBASE_OAUTH_V1"
  }
}

resource "databricks_postgres_role" "abac_restricted" {
  count = var.deploy_abac_demo && var.abac_restricted_group != "" ? 1 : 0

  role_id          = local.abac_restrict_role_id
  parent           = local.production_branch
  replace_existing = true

  spec = {
    identity_type = "GROUP"
    postgres_role = var.abac_restricted_group
    auth_method   = "LAKEBASE_OAUTH_V1"
  }
}
