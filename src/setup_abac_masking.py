# Databricks notebook source
# MAGIC %pip install psycopg2-binary databricks-sdk --upgrade -q

# COMMAND ----------
dbutils.library.restartPython()

# COMMAND ----------
# Deploy the Scripius/SelectHealth ABAC-equivalent column masking demo onto the
# Lakebase Postgres SERVING layer.
#
# WHY A NOTEBOOK: Unity Catalog ABAC (row filters / column masks) governs only the
# analytical path; it does NOT follow data synced into Lakebase Postgres. The
# Databricks Terraform provider runs no SQL inside Postgres, so — like
# setup_data_role / setup_dataapi_role — the data-plane objects (the masking view
# and its grants) are applied here over a direct psql connection. This is the
# parameterized twin of sql/abac_masking.sql; keep the two in sync.
#
# THE TWO-GROUP MODEL (mirrors Dan's UC ABAC EXCEPT-list, default-deny):
#   <exempt_group>     -> in the EXCEPT list -> sees UNMASKED data
#   <restricted_group> -> not in EXCEPT list -> sees MASKED data (default)
#
# The two groups are registered as OAuth GROUP roles by roles.tf
# (databricks_postgres_role, identity_type=GROUP), so real SelectHealth group
# members map into them over OAuth. This notebook does NOT create the roles — it
# builds the schema/table/view and grants SELECT on the view to those roles.
#
# The masking view is created WITH (security_barrier = true) — it runs with the
# view OWNER's rights, and consumers get SELECT on the view but NO base-table
# access, so the pg_has_role() CASE is un-bypassable.
#
# Runs AS the runner identity (project owner / a databricks_superuser member — in
# CI, the cicd SP that ran `terraform apply`) over an OAuth database credential.
# Idempotent.
import re

import psycopg2
from databricks.sdk import WorkspaceClient

# No defaults on the targeting params — a missing value must FAIL, never build the
# demo against the wrong instance/database.
dbutils.widgets.text("project_id", "")
dbutils.widgets.text("database", "")
# Object names default to the Scripius pharmacy value stream; override to reuse.
dbutils.widgets.text("raw_schema", "sh_pharmacy")
dbutils.widgets.text("secure_schema", "sh_pharmacy_secure")
dbutils.widgets.text("exempt_group", "SCRP_ABAC_EXEMPT")
dbutils.widgets.text("restricted_group", "SCRP_RXVS_RESTRICTED")
dbutils.widgets.text("seed_data", "true")       # seed demo rows into the base table

PROJECT      = dbutils.widgets.get("project_id").strip()
DB           = dbutils.widgets.get("database").strip()
RAW_SCHEMA   = dbutils.widgets.get("raw_schema").strip()
SEC_SCHEMA   = dbutils.widgets.get("secure_schema").strip()
EXEMPT       = dbutils.widgets.get("exempt_group").strip()
RESTRICTED   = dbutils.widgets.get("restricted_group").strip()
SEED         = dbutils.widgets.get("seed_data").strip().lower() in ("1", "true", "yes")

_missing = [n for n, v in (("project_id", PROJECT), ("database", DB),
                           ("raw_schema", RAW_SCHEMA), ("secure_schema", SEC_SCHEMA),
                           ("exempt_group", EXEMPT), ("restricted_group", RESTRICTED)) if not v]
if _missing:
    raise ValueError(f"Missing required parameter(s): {', '.join(_missing)}.")

# Every identifier below is interpolated into SQL, so validate strictly against a
# plain-identifier allow-pattern. Group names are UPPER (double-quoted in SQL to
# preserve case); schema names are lower. Reject anything that could break out.
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
for label, val in (("raw_schema", RAW_SCHEMA), ("secure_schema", SEC_SCHEMA),
                   ("exempt_group", EXEMPT), ("restricted_group", RESTRICTED)):
    if not _IDENT.match(val):
        raise ValueError(f"{label}='{val}' is not a valid SQL identifier "
                         f"(allowed: letters, digits, underscore; must not start with a digit).")

w = WorkspaceClient()
parent = f"projects/{PROJECT}/branches/production"
endpoint = f"{parent}/endpoints/primary"
host = next(iter(w.postgres.list_endpoints(parent=parent))).as_dict()["status"]["hosts"]["host"]
user = w.current_user.me().user_name   # connect as the project owner (superuser)

tok = w.postgres.generate_database_credential(endpoint=endpoint).token
c = psycopg2.connect(host=host, port=5432, dbname=DB, user=user, password=tok, sslmode="require")
c.autocommit = True
cur = c.cursor()
print(f"building ABAC masking demo on {host}/{DB} as {user}")
print(f"  raw schema={RAW_SCHEMA}  secure schema={SEC_SCHEMA}")
print(f"  exempt={EXEMPT} (unmasked)  restricted={RESTRICTED} (masked)")

# 1. Group roles are OWNED BY TERRAFORM (roles.tf databricks_postgres_role, OAuth
#    GROUP). This notebook does not create them — it only grants on the view below.
#    Guard: confirm they exist so the GRANTs don't fail on a missing role. (A
#    control-plane GROUP role cannot be SET ROLE'd into by this SP anyway, so
#    masking is verified from a real member's session, not here.)
cur.execute("SELECT rolname FROM pg_roles WHERE rolname = ANY(%s)", ([EXEMPT, RESTRICTED],))
present = {r[0] for r in cur.fetchall()}
missing = [g for g in (EXEMPT, RESTRICTED) if g not in present]
if missing:
    raise RuntimeError(
        f"OAuth GROUP role(s) not found: {missing}. They are provisioned by roles.tf "
        f"(databricks_postgres_role) — apply Terraform with deploy_abac_demo=true before "
        f"running this job, or register them via `databricks postgres create-role`.")

# 2. Schemas.
cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW_SCHEMA}"')
cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{SEC_SCHEMA}"')

# 3. Raw base table (PII lives here).
cur.execute(f'''
    CREATE TABLE IF NOT EXISTS "{RAW_SCHEMA}".member_rx (
      rx_claim_id   bigint PRIMARY KEY,
      member_id     text          NOT NULL,
      member_name   text          NOT NULL,
      member_ssn    text          NOT NULL,
      member_dob    date          NOT NULL,
      drug_name     text          NOT NULL,
      ndc           text          NOT NULL,
      fill_date     date          NOT NULL,
      days_supply   int           NOT NULL,
      copay_amount  numeric(10,2) NOT NULL
    )
''')

if SEED:
    cur.execute(f'''
        INSERT INTO "{RAW_SCHEMA}".member_rx
          (rx_claim_id, member_id, member_name, member_ssn, member_dob,
           drug_name, ndc, fill_date, days_supply, copay_amount)
        VALUES
          (100001, 'M-0001', 'Alice Nguyen',  '512-33-8841', '1984-02-11', 'Atorvastatin 20mg',  '00093-1234-56', '2026-08-02', 30, 10.00),
          (100002, 'M-0002', 'Brian Carter',  '298-45-1190', '1971-07-30', 'Metformin 500mg',    '00093-2345-67', '2026-08-05', 90, 12.50),
          (100003, 'M-0003', 'Carla Fuentes', '640-12-7723', '1990-11-19', 'Lisinopril 10mg',    '00093-3456-78', '2026-08-09', 30,  8.00),
          (100004, 'M-0004', 'Derek Olsen',   '733-88-2045', '1965-04-03', 'Levothyroxine 75mcg','00093-4567-89', '2026-08-12', 90, 15.00),
          (100005, 'M-0005', 'Evelyn Park',   '410-27-6698', '1988-09-27', 'Omeprazole 20mg',    '00093-5678-90', '2026-08-15', 30,  9.25)
        ON CONFLICT (rx_claim_id) DO NOTHING
    ''')

# 4. Masking view — PII unmasked only for EXEMPT members, masked for everyone else.
cur.execute(f'''
    CREATE OR REPLACE VIEW "{SEC_SCHEMA}".member_rx_secure
      WITH (security_barrier = true) AS
    SELECT
      rx_claim_id, member_id, drug_name, ndc, fill_date, days_supply, copay_amount,
      CASE WHEN pg_has_role(current_user, '{EXEMPT}', 'member')
           THEN member_name ELSE '***REDACTED***' END              AS member_name,
      CASE WHEN pg_has_role(current_user, '{EXEMPT}', 'member')
           THEN member_ssn  ELSE 'XXX-XX-' || right(member_ssn, 4) END AS member_ssn,
      CASE WHEN pg_has_role(current_user, '{EXEMPT}', 'member')
           THEN member_dob::text ELSE NULL END                     AS member_dob
    FROM "{RAW_SCHEMA}".member_rx
''')

# 5. Grants: groups get NOTHING on the raw path, SELECT only on the view.
cur.execute(f'REVOKE ALL ON ALL TABLES IN SCHEMA "{RAW_SCHEMA}" FROM "{EXEMPT}", "{RESTRICTED}"')
cur.execute(f'REVOKE ALL ON SCHEMA "{RAW_SCHEMA}"               FROM "{EXEMPT}", "{RESTRICTED}"')
cur.execute(f'GRANT USAGE ON SCHEMA "{SEC_SCHEMA}"              TO "{EXEMPT}", "{RESTRICTED}"')
cur.execute(f'GRANT SELECT ON "{SEC_SCHEMA}".member_rx_secure   TO "{EXEMPT}", "{RESTRICTED}"')
cur.execute(f'ALTER DEFAULT PRIVILEGES IN SCHEMA "{SEC_SCHEMA}" GRANT SELECT ON TABLES '
            f'TO "{EXEMPT}", "{RESTRICTED}"')

# 6. Confirm the SELECT-on-view grant landed for both groups (ACL check). We do NOT
#    SET ROLE here: these are control-plane OAuth GROUP roles, which the creating SP
#    cannot assume — masking is verified by connecting AS a real group member.
cur.execute(
    f'SELECT grantee, privilege_type FROM information_schema.role_table_grants '
    f"WHERE table_schema = %s AND table_name = 'member_rx_secure' "
    f'AND grantee = ANY(%s)', (SEC_SCHEMA, [EXEMPT, RESTRICTED]))
grants = cur.fetchall()
print(f"\ngrants on {SEC_SCHEMA}.member_rx_secure: {grants}")

c.close()
print(f"\nABAC masking demo ready: {SEC_SCHEMA}.member_rx_secure "
      f"(exempt={EXEMPT} unmasked, restricted={RESTRICTED} masked).")
print("VERIFY from a real group member's OAuth session (not this SP):")
print(f"  member of {RESTRICTED} -> masked; member of {EXEMPT} -> unmasked.")
