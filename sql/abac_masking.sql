-- =============================================================================
-- Scripius / SelectHealth — ABAC-equivalent column masking on the Lakebase
-- Postgres SERVING layer (the transactional path).
-- =============================================================================
-- WHY THIS EXISTS
--   Unity Catalog ABAC (row filters / column masks) governs ONLY the analytical
--   path (SQL warehouse, clusters, Lakehouse/RT, CDF, federated read). Those
--   policies DO NOT follow data synced into Lakebase Postgres — apps/clients on
--   a direct Postgres connection (and the PostgREST/Data API) are governed only
--   by native Postgres GRANT/REVOKE/RLS. So to answer "contractors shouldn't
--   see the data in Lakebase", we replicate Dan's two-group ABAC model natively
--   in Postgres with a security_barrier view + pg_has_role.
--
-- THE TWO-GROUP MODEL (mirrors the UC ABAC EXCEPT-list, default-deny)
--   SCRP_ABAC_EXEMPT     -> in the EXCEPT list  -> sees UNMASKED data
--   SCRP_RXVS_RESTRICTED -> not in EXCEPT list  -> sees MASKED data (default)
--
-- HOW MASKING WORKS
--   member_rx_secure is a VIEW created WITH (security_barrier = true) — it runs
--   with the VIEW OWNER's privileges (NOT security_invoker). Consumers get
--   SELECT on the view and NO access to the raw base table, so the CASE
--   expression (keyed off pg_has_role(current_user, 'SCRP_ABAC_EXEMPT',...)) is
--   the only way they can read the data, and it is un-bypassable.
--
-- TWO-SCHEMA LAYOUT (production pattern)
--   sh_pharmacy         raw schema — base table, PII. Groups get NO usage here.
--   sh_pharmacy_secure  consumer schema — masking views only. Groups get
--                       USAGE + SELECT. Safe to ALTER DEFAULT PRIVILEGES here
--                       because only views live in it.
--
-- HOW TO REUSE FOR A DIFFERENT VALUE STREAM
--   Change the 4 identifiers below and re-run — the whole script is idempotent.
--     raw schema     : sh_pharmacy
--     secure schema  : sh_pharmacy_secure
--     exempt group   : SCRP_ABAC_EXEMPT
--     restricted grp : SCRP_RXVS_RESTRICTED
--
-- NOTE: The parameterized deployer is src/setup_abac_masking.py (runs this same
--       logic via the CI post-hook). Keep the two in sync.
--
-- Verified pattern: reference_lakebase_masking_role_testing /
--                   project_scripius_abac_masking_plan (torn down w/ sandbox).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Group roles.
--    The two groups are registered as OAuth GROUP roles by roles.tf
--    (`databricks_postgres_role`, identity_type = GROUP, LAKEBASE_OAUTH_V1), so
--    real SelectHealth group members map into them over OAuth. This script does
--    NOT create them — it only builds the objects that reference them. The
--    postgres_role name equals the group name, so the view's pg_has_role check and
--    the grants below both use the same identifier.
--    (If running this by hand against an instance where the OAuth roles are not yet
--    registered, create them first via `databricks postgres create-role` — do NOT
--    fall back to a raw CREATE ROLE, which produces a no-login role the identity
--    cannot OAuth into.)
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 2. Schemas.
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS sh_pharmacy;
CREATE SCHEMA IF NOT EXISTS sh_pharmacy_secure;

-- -----------------------------------------------------------------------------
-- 3. Raw base table (PII lives here) + a little demo data.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sh_pharmacy.member_rx (
  rx_claim_id   bigint PRIMARY KEY,
  member_id     text        NOT NULL,   -- business key, not PII — stays visible
  member_name   text        NOT NULL,   -- PII
  member_ssn    text        NOT NULL,   -- PII
  member_dob    date        NOT NULL,   -- PII
  drug_name     text        NOT NULL,
  ndc           text        NOT NULL,
  fill_date     date        NOT NULL,
  days_supply   int         NOT NULL,
  copay_amount  numeric(10,2) NOT NULL
);

INSERT INTO sh_pharmacy.member_rx
  (rx_claim_id, member_id, member_name, member_ssn, member_dob,
   drug_name, ndc, fill_date, days_supply, copay_amount)
VALUES
  (100001, 'M-0001', 'Alice Nguyen',   '512-33-8841', '1984-02-11', 'Atorvastatin 20mg', '00093-1234-56', '2026-08-02', 30, 10.00),
  (100002, 'M-0002', 'Brian Carter',   '298-45-1190', '1971-07-30', 'Metformin 500mg',   '00093-2345-67', '2026-08-05', 90, 12.50),
  (100003, 'M-0003', 'Carla Fuentes',  '640-12-7723', '1990-11-19', 'Lisinopril 10mg',   '00093-3456-78', '2026-08-09', 30,  8.00),
  (100004, 'M-0004', 'Derek Olsen',    '733-88-2045', '1965-04-03', 'Levothyroxine 75mcg','00093-4567-89','2026-08-12', 90, 15.00),
  (100005, 'M-0005', 'Evelyn Park',    '410-27-6698', '1988-09-27', 'Omeprazole 20mg',   '00093-5678-90', '2026-08-15', 30,  9.25)
ON CONFLICT (rx_claim_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4. Masking view (the control point).
--    security_barrier => runs with the view OWNER's rights (not the caller's),
--    so consumers never need — and never get — base-table access.
--    Non-PII columns pass through; PII columns are unmasked ONLY for members of
--    SCRP_ABAC_EXEMPT, masked for everyone else.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sh_pharmacy_secure.member_rx_secure
  WITH (security_barrier = true) AS
SELECT
  rx_claim_id,
  member_id,
  drug_name,
  ndc,
  fill_date,
  days_supply,
  copay_amount,
  CASE WHEN pg_has_role(current_user, 'SCRP_ABAC_EXEMPT', 'member')
       THEN member_name
       ELSE '***REDACTED***' END                              AS member_name,
  CASE WHEN pg_has_role(current_user, 'SCRP_ABAC_EXEMPT', 'member')
       THEN member_ssn
       ELSE 'XXX-XX-' || right(member_ssn, 4) END             AS member_ssn,
  CASE WHEN pg_has_role(current_user, 'SCRP_ABAC_EXEMPT', 'member')
       THEN member_dob::text
       ELSE NULL END                                          AS member_dob
FROM sh_pharmacy.member_rx;

-- -----------------------------------------------------------------------------
-- 5. Grants.
--    Groups get NOTHING on the raw schema/table, and SELECT only on the view.
--    Because SELECT-on-view is the only access, a NON-member of either group
--    gets "permission denied" (not masked rows) — masked visibility requires
--    membership in one of the two groups. That is by design.
-- -----------------------------------------------------------------------------
-- Lock the raw path shut for the consumer groups.
REVOKE ALL ON ALL TABLES IN SCHEMA sh_pharmacy FROM "SCRP_ABAC_EXEMPT", "SCRP_RXVS_RESTRICTED";
REVOKE ALL ON SCHEMA sh_pharmacy               FROM "SCRP_ABAC_EXEMPT", "SCRP_RXVS_RESTRICTED";

-- Open the secure (view-only) path.
GRANT USAGE ON SCHEMA sh_pharmacy_secure                   TO "SCRP_ABAC_EXEMPT", "SCRP_RXVS_RESTRICTED";
GRANT SELECT ON sh_pharmacy_secure.member_rx_secure        TO "SCRP_ABAC_EXEMPT", "SCRP_RXVS_RESTRICTED";
-- Future views in the secure schema auto-grant (safe: only views live here).
ALTER DEFAULT PRIVILEGES IN SCHEMA sh_pharmacy_secure GRANT SELECT ON TABLES
  TO "SCRP_ABAC_EXEMPT", "SCRP_RXVS_RESTRICTED";

-- =============================================================================
-- VERIFY — from a REAL group member's OAuth session, NOT the admin/SP.
--
-- These are control-plane OAuth GROUP roles, and the identity that CREATED them
-- (the cicd SP / project owner) CANNOT `SET ROLE` into them ("Only roles with
-- ADMIN option may grant this role"). So verification is done by connecting AS a
-- Databricks user who is a member of the group — Lakebase maps their OAuth session
-- into the group role, and current_user becomes the group name:
--
--   -- Connect as a member of SCRP_RXVS_RESTRICTED, then:
--   SELECT member_id, member_name, member_ssn, member_dob
--   FROM sh_pharmacy_secure.member_rx_secure ORDER BY rx_claim_id LIMIT 3;
--   -- expect: member_name='***REDACTED***', member_ssn='XXX-XX-8841', member_dob=NULL
--
--   -- Connect as a member of SCRP_ABAC_EXEMPT, then the same SELECT:
--   -- expect: real member_name / full SSN / real DOB
--
-- To flip a demo user masked <-> unmasked, add/remove them from SCRP_ABAC_EXEMPT
-- (in the Databricks account) and reconnect.
--
-- CAVEATS:
--   • A user in BOTH groups maps to a SINGLE group role (selection not
--     controllable), so keep the two groups mutually exclusive — a restricted user
--     must not also be in SCRP_ABAC_EXEMPT (matches Dan's ABAC model).
--   • A TRUE Postgres superuser (rolsuper=t) makes pg_has_role() return TRUE for
--     every role → always UNMASKED. `databricks_superuser` is NOT rolsuper, so it
--     behaves like a normal role.
-- =============================================================================
