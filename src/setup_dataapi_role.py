# Databricks notebook source
# MAGIC %pip install psycopg2-binary databricks-sdk --upgrade -q

# COMMAND ----------
dbutils.library.restartPython()

# COMMAND ----------
# Grant the Data API service principal a Postgres role so PostgREST can act as it.
#
# This is the data-plane half of the Data API path that Terraform cannot express:
# `databricks_postgres_data_api` (in data_api.tf) ENABLES the API and creates the
# `authenticator` role; this notebook then does `GRANT <sp> TO authenticator` plus the
# table/sequence DML the SP needs. The GitHub Actions post-hook runs it after apply with
# the SP application id from `terraform output`.
#
# Runs AS the runner identity (the project owner / a databricks_superuser member — in CI,
# the cicd SP that ran `terraform apply`) over an OAuth database credential. Idempotent.
import psycopg2
from databricks.sdk import WorkspaceClient

# No defaults on purpose: this grants a Postgres role, so a missing param must FAIL.
dbutils.widgets.text("project_id", "")
dbutils.widgets.text("database", "")
dbutils.widgets.text("identity", "")   # SP application id (UUID)
PROJECT  = dbutils.widgets.get("project_id").strip()
DB       = dbutils.widgets.get("database").strip()
IDENTITY = dbutils.widgets.get("identity").strip()
_missing = [n for n, v in (("project_id", PROJECT), ("database", DB), ("identity", IDENTITY)) if not v]
if _missing:
    raise ValueError(f"Missing required parameter(s): {', '.join(_missing)}. "
                     f"Run with project_id=<slug>,database=<postgres_db>,identity=<sp_app_id>.")

SP = IDENTITY

w = WorkspaceClient()
parent = f"projects/{PROJECT}/branches/production"
endpoint = f"{parent}/endpoints/primary"
host = next(iter(w.postgres.list_endpoints(parent=parent))).as_dict()["status"]["hosts"]["host"]
user = w.current_user.me().user_name   # connect as the project owner

tok = w.postgres.generate_database_credential(endpoint=endpoint).token
c = psycopg2.connect(host=host, port=5432, dbname=DB, user=user, password=tok, sslmode="require")
c.autocommit = True
cur = c.cursor()
print(f"granting Data API role to SP {SP} on {host}/{DB} as {user}")

cur.execute("CREATE EXTENSION IF NOT EXISTS databricks_auth")

# Create the SP's Postgres role (no-op if it already exists).
try:
    cur.execute("SELECT databricks_create_role(%s, 'SERVICE_PRINCIPAL')", (SP,))
    print(f"created role {SP}")
except psycopg2.Error as e:
    print(f"role {SP} already exists or create skipped: {e}")

# The one grant that specifically enables the Data API path: let PostgREST's
# `authenticator` assume this SP's role. Not schema-scoped. (authenticator exists because
# data_api.tf enabled the Data API on this database.)
cur.execute(f'GRANT "{SP}" TO authenticator')

# Table/sequence DML: enumerate ALL user schemas (not just `public`) so a developer adding
# a new schema gets Data API access on the next run. GRANTs are idempotent; identifiers
# quoted (SP id has hyphens).
cur.execute("""
    SELECT schema_name FROM information_schema.schemata
    WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND schema_name NOT LIKE 'pg_temp%' AND schema_name NOT LIKE 'pg_toast_temp%'
    ORDER BY schema_name
""")
schemas = [r[0] for r in cur.fetchall()]
print(f"granting on schemas: {schemas}")
for sch in schemas:
    for stmt in (
        f'GRANT USAGE ON SCHEMA "{sch}" TO "{SP}"',
        f'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "{sch}" TO "{SP}"',
        f'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "{sch}" TO "{SP}"',
        # Cover objects created later, too.
        f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{sch}" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{SP}"',
        f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{sch}" GRANT USAGE, SELECT ON SEQUENCES TO "{SP}"',
    ):
        cur.execute(stmt)
c.close()
print(f"Data API role setup complete for {SP} on {len(schemas)} schema(s)")
