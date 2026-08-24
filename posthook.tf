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
