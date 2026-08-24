# lakebase-terraform

Deploy a **Lakebase instance** (and the objects it owns — its Unity Catalog
catalog registration, a synced table, and the snapshot-refresh job) with
**Terraform**, modeled as an **autoscaling project** — instead of Databricks
Asset Bundles (DABs).

This is a **demonstration** built to answer Marcin's question: *"can we deploy
Lakebase with Terraform instead of DABs?"* It does **not** replace or destroy the
DABs work in `sh-lakebase` — it reproduces the same outcome so the two approaches
can be compared. It reuses the **existing Azure substrate** (workspace, Key Vault,
UC metastore, service principals, project catalog) that the
`sh-lakebase/terraform/` component stands up; this stack only creates the Lakebase
project **inside** that workspace.

> **Decision (Marcin, 2026-08-24):** go **autoscaling-native**. The DABs side
> creates the instance the *legacy provisioned* way only to unlock Dual
> Networking — which we don't need here — so this stack skips
> `databricks_database_instance` entirely and uses the `postgres_*` (autoscaling
> project) resource family, the same model the DABs bundle already declares.

---

## What DABs does today (the thing we're reproducing)

In `sh-lakebase`, standing up one value-stream instance takes two moving parts:

1. **A Python pre-hook** (`scripts/lakebase_prehook.py`) that runs *before*
   `bundle deploy`: it creates the instance the **legacy provisioned** way
   (`databricks database create-database-instance`) to unlock Dual Networking,
   then **binds** it to the bundle's autoscaling `postgres_projects` key so
   `bundle deploy` adopts it instead of re-creating it.
2. **The bundle** declares `postgres_projects`, `postgres_catalogs`,
   `postgres_synced_tables`, and refresh `jobs`; a **post-hook** then applies the
   autoscaling CU window, scale-to-zero, HA group, and the data-plane grants —
   all *manually*, via `databricks postgres update-endpoint` and notebook jobs,
   because the bundle can't express them.

The create-then-bind dance exists only because the bundle models the instance as
an autoscaling **project** but must create it **provisioned-first**. Going
autoscaling-native in Terraform removes that dance *and* pulls the manual
post-hook steps into declarative config.

## What this stack does

`databricks_postgres_project` **is** the autoscaling project the bundle
declares — created directly, no legacy instance, no pre-hook, no bind:

| File | Resource | Replaces (DABs) |
|------|----------|-----------------|
| `main.tf` | `databricks_postgres_project` | pre-hook create + bind, and `postgres_projects` |
| `endpoint.tf` | `databricks_postgres_endpoint` (adopts the primary) | post-hook `update-endpoint` (autoscaling window, scale-to-zero, HA group) |
| `catalog.tf` | `databricks_postgres_catalog` | `postgres_catalogs` |
| `synced_tables.tf` | `databricks_postgres_synced_table` + `databricks_job` | `postgres_synced_tables` + refresh `jobs` |
| `data_api.tf` | `databricks_postgres_data_api` | the manual "Enable Data API" click |
| `roles.tf` | `databricks_postgres_role` (admin + developer groups) | pre-hook `grant_admin_superuser` (role API) |
| `grants.tf` | `databricks_grant` (system read for the deployer) | infra `catalog.tf` system grants |
| `permissions.tf` | `databricks_permissions` (`database_project_name`) | the project `permissions:` block |
| `posthook.tf` + `src/*.py` | `databricks_notebook` + `databricks_job` | the DABs `setup_data_role` / `setup_dataapi_role` jobs |
| `scripts/posthook.py` | bundle-free post-hook orchestrator | `lakebase_prehook.py --phase post` |
| `.github/workflows/deploy.yml` | GitHub Actions | the DABs GitHub pipeline |

The project auto-creates its `production` branch and primary read-write endpoint;
`endpoint.tf` adopts that primary (`replace_existing = true`) to manage its
compute window declaratively.

## The GitHub Actions pipeline (Terraform + post-hook)

Terraform can't run SQL inside Postgres, so the per-table GRANTs stay a job — but
that job is deployed *by* Terraform (`posthook.tf` imports `src/*.py` as notebooks
and wraps each in a parameterized `databricks_job`). `.github/workflows/deploy.yml`
does the two-phase deploy, mirroring the DABs pre-hook + post-hook split:

1. **`terraform apply`** — project, endpoint, catalog, synced table, Data API,
   roles, ACLs (everything declarative).
2. **post-hook** — `scripts/posthook.py --from-terraform`, a **bundle-free port of
   sh-lakebase's `lakebase_prehook.py --phase post`**. It reads the project /
   database / principals / job-ids from `terraform output` (no `bundle validate`,
   no `bundle run`) and triggers the residual data-plane GRANTs, waiting for each:
   - `setup_data_role` → `GRANT SELECT … TO` the developer group role (GROUP → RO)
   - `setup_dataapi_role` → `GRANT <app SP> TO authenticator` + table DML

Because Terraform already owns the control-plane grants (`roles.tf` superuser,
`permissions.tf` ACLs, `data_api.tf` enable-API), the post-hook is *just* the two
data-plane grant jobs — a much thinner script than the DABs post phase.

**Auth** matches sh-lakebase exactly: the Entra **`sh-lakebase-cicd` SP** via
`azure-client-secret`. The GitHub secrets `DATABRICKS_CLIENT_ID/SECRET` are mapped
to `ARM_CLIENT_ID/SECRET` (with `ARM_TENANT_ID`) so both the Terraform provider and
the CLI select the Entra path — *not* OAuth-M2M. Required GitHub Environment
`vars`/`secrets`, the runner note, and the state-backend note are in the workflow
header.

---

## DABs → Terraform parity

| Capability | DABs today | Terraform here | Notes |
|------------|-----------|----------------|-------|
| Create instance | pre-hook legacy create **+ bind** | `databricks_postgres_project` | ✅ **no pre-hook, no bind** — the project is the resource |
| PostgreSQL version | **pg16** (legacy path is pinned; bundle *declares* 17 but can't get it) | **pg17** (`pg_version = 17`) | ✅ **win** — autoscaling API honors the version |
| Autoscaling CU **window** (min↔max) | post-hook `update-endpoint spec.autoscaling_*` (manual) | `databricks_postgres_endpoint` `autoscaling_limit_min/max_cu` | ✅ **win** — declarative, was the big gap |
| Scale-to-zero | post-hook `update-endpoint spec.suspension` (manual) | endpoint `suspend_timeout_duration` | ✅ **win** |
| **prod HA group** (1 primary + 2 readable secondaries) | manual `update-endpoint spec.group` (unverified in DABs) | endpoint `group { min, max, enable_readable_secondaries }` + `no_suspension` | ✅ **win** — declarative |
| Register DB as UC catalog | `postgres_catalogs` | `databricks_postgres_catalog` | ✅ |
| Synced table | `postgres_synced_tables` | `databricks_postgres_synced_table` | ✅ |
| Scheduled snapshot refresh | `jobs` + `pipeline_task` | `databricks_job` + `pipeline_task` | ✅ pipeline id referenced, not hardcoded |
| Project ACL (CAN_USE / CAN_MANAGE) | project `permissions:` | `databricks_permissions` (`database_project_name`) | ✅ |
| Dual Networking | unlocked by the legacy provisioned create | **not available on this path** | ⚠️ accepted per the decision above — the autoscaling create does not provide it |
| **Enable Data API** | manual "Enable Data API" click | `databricks_postgres_data_api` | ✅ **win** — the click is now declarative (enables the API surface: `authenticator` role, `pgrst` schema) |
| Admin `databricks_superuser` + role attributes | post-hook role API (`create-role`/`update-role`) | `databricks_postgres_role` (`membership_roles`, `attributes`) | ✅ **win** — SH_ENTERPRISE_ADMIN superuser + createdb/createrole/bypassrls, declarative |
| Developer group Postgres **role principal** | pre-hook / SQL creates it | `databricks_postgres_role` (plain login role) | ✅ role object created; its table SELECTs still notebook (below) |
| Postgres **data-plane** table/schema GRANTs | post-hook `setup_data_role` / `setup_dataapi_role` (SQL inside Postgres) | ⚠️ **still notebook** | The Databricks provider runs no SQL inside Postgres. `postgres_data_api` enables the API but does NOT grant an SP into it; `postgres_role` manages the role object, not table GRANTs. Eliminating the notebook needs the `cyrilgdn/postgresql` provider over a live OAuth token. |

**Headline for the demo:** going autoscaling-native doesn't just match DABs — it
**closes the gaps DABs handled manually**. The pre-hook create-then-bind is gone,
the autoscaling window / scale-to-zero / HA group become declarative, and pg17
(the version the bundle always wanted) is finally what you get. The only true
notebook-only remainder is the per-table **Postgres GRANT** SQL; the trade we
accept is **no Dual Networking** on this path — which is fine per Marcin's call.

---

## Run it

Prereq: the `sh-lakebase/terraform/` infra stack has been applied, so a workspace
+ UC metastore + project catalog + SPs exist.

```bash
cp terraform.tfvars.example terraform.tfvars
# Fill in workspace_host (and app_service_principal_id if granting the SP):
#   terraform -chdir=../sh-lakebase/terraform output -raw workspace_url
#   terraform -chdir=../sh-lakebase/terraform output -raw catalog_name    # -> pg_storage_catalog
#   terraform -chdir=../sh-lakebase/terraform output -raw app_client_id   # -> app_service_principal_id

# Auth (either):
az login --tenant bf465dc7-3bc8-4944-b018-092572b5c20d      # local demo, or
export DATABRICKS_CLIENT_ID=... DATABRICKS_CLIENT_SECRET=... # CI (same SP as the DABs pipeline)

terraform init
terraform plan
terraform apply

terraform output project_name    # projects/dev-sh-lkb-terra
terraform output endpoint_name   # the primary read-write endpoint (connect via `postgres get-endpoint`)
```

The stack creates its own project, **`dev-sh-lkb-terra`** (via `value_stream =
"terra"`), deliberately distinct from the DABs-managed `risk` / `isops` projects
that already live in the shared workspace — so this apply never collides with
them. It **reuses the existing identities** — the `sh-lakebase-app` SP and the
`SH_LKB_RISK_DEVELOPER` group — for the CAN_USE / CAN_MANAGE grants rather than
creating new ones. Point at a different token by copying the tfvars and changing
`value_stream` / `catalog_name` — one tfvars file per instance, mirroring the
DABs one-file-per-stream model.

For a **prod-shaped** apply, set `autoscaling_min_cu`/`max_cu` higher (e.g. 8/24),
`enable_readable_secondaries = true`, and `ha_node_count = 3`.

## Scope / caveats

- **Demo, not production.** Reuses the FE One-Env sandbox substrate; everything is
  ephemeral (the sandbox wipes classic workspaces the 1st & 3rd Sunday, account
  objects after 14 days). Re-`apply` after a rebuild once `workspace_host` is
  refreshed.
- Fill ids from the `sh-lakebase` infra outputs — **no client secrets are
  committed here**, and `terraform.tfvars` is gitignored.
- **No Dual Networking** on this path. Per-table Postgres GRANTs stay in the
  `setup_data_role` / `setup_dataapi_role` jobs — `postgres_data_api` enables the
  API surface but doesn't grant an SP into it, and `postgres_role` creates the
  role principals (incl. the admin superuser) but not the table-level GRANTs.
  With TF owning the role objects, those jobs should do only the GRANTs, not
  re-create the roles.
