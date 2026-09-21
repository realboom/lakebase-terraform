# =============================================================================
# Post-hook jobs — the data-plane GRANTs Terraform cannot express.
# =============================================================================
# Terraform deploys the notebooks (src/*.py) and wraps each in a parameterized
# job. The GitHub Actions pipeline (.github/workflows/deploy.yml) runs these
# AFTER `terraform apply` via `jobs run-now`, feeding the project/db/identity
# from `terraform output`. This is the residual notebook-only piece:
#
#   • setup_data_role     -> GRANT SELECT ON tables TO the developer GROUP role
#   • setup_dataapi_role  -> GRANT <app SP> TO authenticator + table DML
#
# Deployed as `databricks_notebook` (not workspace_file) because the tasks are
# notebook_task. No cluster is declared -> the tasks run on serverless.
#
# The runner that executes these must own the project / be a databricks_superuser
# (to create OAuth roles). In CI that is the cicd SP that ran `terraform apply`.
# =============================================================================

resource "databricks_notebook" "setup_data_role" {
  count    = var.deploy_posthook ? 1 : 0
  source   = "${path.module}/src/setup_data_role.py"
  path     = "${var.posthook_workspace_dir}/setup_data_role"
  language = "PYTHON"
}

resource "databricks_notebook" "setup_dataapi_role" {
  count    = var.deploy_posthook ? 1 : 0
  source   = "${path.module}/src/setup_dataapi_role.py"
  path     = "${var.posthook_workspace_dir}/setup_dataapi_role"
  language = "PYTHON"
}

# --- Job: direct-connection data grant (developer group -> SELECT) -------------
resource "databricks_job" "setup_data_role" {
  count = var.deploy_posthook ? 1 : 0
  name  = "[terra] setup data role (direct-connection grant)"

  parameter {
    name    = "project_id"
    default = ""
  }
  parameter {
    name    = "database"
    default = ""
  }
  parameter {
    name    = "identity"
    default = ""
  }
  parameter {
    name    = "identity_type"
    default = ""
  }
  parameter {
    name    = "privileges"
    default = "SELECT"
  }

  task {
    task_key = "setup_data_role"
    notebook_task {
      notebook_path = databricks_notebook.setup_data_role[0].path
    }
  }
}

# --- Job: Data API grant (app SP -> authenticator + DML) -----------------------
resource "databricks_job" "setup_dataapi_role" {
  count = var.deploy_posthook ? 1 : 0
  name  = "[terra] setup Data API role (grant SP)"

  parameter {
    name    = "project_id"
    default = ""
  }
  parameter {
    name    = "database"
    default = ""
  }
  parameter {
    name    = "identity"
    default = ""
  }

  task {
    task_key = "setup_dataapi_role"
    notebook_task {
      notebook_path = databricks_notebook.setup_dataapi_role[0].path
    }
  }
}

# =============================================================================
# ABAC column-masking demo (Scripius/SelectHealth two-group model).
# =============================================================================
# UC ABAC does NOT follow data synced into Lakebase Postgres, so the serving
# layer is governed natively: a security_barrier view keyed off pg_has_role,
# with SCRP_ABAC_EXEMPT unmasked and SCRP_RXVS_RESTRICTED masked. Same deploy
# shape as the post-hook (notebook + parameterized job, run via `jobs run-now`
# after apply), but gated by its own var so it ships only when you want the demo.
# Canonical hand-runnable copy: sql/abac_masking.sql.
# =============================================================================

resource "databricks_notebook" "setup_abac_masking" {
  count    = var.deploy_abac_demo ? 1 : 0
  source   = "${path.module}/src/setup_abac_masking.py"
  path     = "${var.posthook_workspace_dir}/setup_abac_masking"
  language = "PYTHON"
}

resource "databricks_job" "setup_abac_masking" {
  count = var.deploy_abac_demo ? 1 : 0
  name  = "[terra] ABAC column-masking demo (serving layer)"

  parameter {
    name    = "project_id"
    default = ""
  }
  parameter {
    name    = "database"
    default = ""
  }
  parameter {
    name    = "raw_schema"
    default = "sh_pharmacy"
  }
  parameter {
    name    = "secure_schema"
    default = "sh_pharmacy_secure"
  }
  parameter {
    name    = "exempt_group"
    default = var.abac_exempt_group
  }
  parameter {
    name    = "restricted_group"
    default = var.abac_restricted_group
  }
  parameter {
    name    = "seed_data"
    default = "true"
  }

  task {
    task_key = "setup_abac_masking"
    notebook_task {
      notebook_path = databricks_notebook.setup_abac_masking[0].path
    }
  }
}
