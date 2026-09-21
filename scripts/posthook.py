#!/usr/bin/env python3
"""
Lakebase post-hook — bundle-free, Terraform-driven.

Adapted from sh-lakebase's `scripts/lakebase_prehook.py --phase post`, but driven
by `terraform output` instead of `databricks bundle validate` — this repo has NO
DABs bundle. It runs the data-plane Postgres GRANTs that Terraform cannot express,
by invoking the setup_data_role / setup_dataapi_role notebook JOBS (deployed by
posthook.tf) via `databricks jobs run-now`, and waiting for each to succeed.

WHAT IT COVERS (and what it does NOT):
  Terraform already owns the CONTROL-plane grants —
    • roles.tf        : databricks_superuser + createdb/createrole/bypassrls (admin group)
    • permissions.tf  : CAN_USE / CAN_MANAGE project ACL
    • data_api.tf     : enable the Data API (creates the `authenticator` role)
  So this post-hook is ONLY the residual data-plane SQL the provider can't run:
    • setup_data_role    -> GRANT <privs> ON tables TO the developer GROUP role
    • setup_dataapi_role -> GRANT <app SP> TO authenticator + table/sequence DML

PRIVILEGE POLICY (same as the prehook):
    SERVICE_PRINCIPAL -> SELECT,INSERT,UPDATE,DELETE   (runtime writer)
    USER / GROUP      -> SELECT                          (read-only inspector)

AUTH: the `databricks` CLI resolves auth from the environment — azure-client-secret
via ARM_* in CI (see .github/workflows/deploy.yml), or a local profile. Pass
--profile to force a profile locally. Depends only on the stdlib + the CLI.

Data-plane grant failures are FATAL (a silently dropped grant means an identity has
no access, which must not pass as green).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time


def log(msg: str) -> None:
    print(f"[posthook] {msg}", flush=True)


def _cli(args: list[str], profile: str | None, *, check: bool = False) -> subprocess.CompletedProcess:
    cmd = ["databricks", *args, "-o", "json"]
    if profile:
        cmd += ["-p", profile]
    log("$ " + " ".join(cmd))
    return subprocess.run(cmd, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def privileges_for(identity_type: str) -> str:
    """SP = runtime writer (RW); USER/GROUP = read-only inspector."""
    return "SELECT,INSERT,UPDATE,DELETE" if identity_type == "SERVICE_PRINCIPAL" else "SELECT"


def run_job(job_id: str, params: dict[str, str], profile: str | None, dry_run: bool) -> bool:
    """
    Trigger a job with job_parameters and wait for it to finish. Returns True on
    SUCCESS. NOTE: `jobs run-now --json` takes job_id INSIDE the JSON body — the CLI
    rejects a positional id alongside --json.
    """
    body = json.dumps({"job_id": int(job_id), "job_parameters": params})
    if dry_run:
        log(f"DRY-RUN would run job {job_id} with {params}")
        return True

    proc = _cli(["jobs", "run-now", "--json", body], profile)
    try:
        run_id = json.loads(proc.stdout)["run_id"]
    except (json.JSONDecodeError, KeyError, TypeError):
        log(f"ERROR: could not start job {job_id}: {proc.stdout}")
        return False
    log(f"started run {run_id} for job {job_id}; waiting...")

    # Poll until the run terminates.
    while True:
        time.sleep(15)
        p = _cli(["jobs", "get-run", str(run_id)], profile)
        try:
            state = json.loads(p.stdout).get("state", {})
        except json.JSONDecodeError:
            continue
        life = state.get("life_cycle_state")
        if life in ("TERMINATED", "SKIPPED", "INTERNAL_ERROR"):
            result = state.get("result_state")
            ok = result == "SUCCESS"
            log(f"run {run_id}: {life}/{result} — {state.get('state_message', '')[:120]}")
            return ok


def tf_outputs() -> dict:
    """Read `terraform output -json` from the current directory."""
    proc = subprocess.run(["terraform", "output", "-json"], text=True, stdout=subprocess.PIPE)
    return {k: v.get("value") for k, v in json.loads(proc.stdout or "{}").items()}


def main() -> int:
    ap = argparse.ArgumentParser(description="Bundle-free Lakebase data-plane post-hook (Terraform-driven).")
    ap.add_argument("--from-terraform", action="store_true",
                    help="Read project_id/database/principals/job-ids from `terraform output -json` "
                         "(run from the Terraform dir). Explicit flags below override individual values.")
    ap.add_argument("--project-id", default=None, help="Lakebase project id (e.g. dev-sh-lkb-terra).")
    ap.add_argument("--database", default=None, help="Postgres database to grant on (default: databricks_postgres).")
    ap.add_argument("--developer-group", default=None,
                    help="Account GROUP to grant read-only SELECT via setup_data_role. Empty/omitted = skip.")
    ap.add_argument("--app-sp", default=None,
                    help="App SP application id to wire into the Data API via setup_dataapi_role. Empty/omitted = skip.")
    ap.add_argument("--data-role-job-id", default=None, help="Job id of the setup_data_role job.")
    ap.add_argument("--dataapi-role-job-id", default=None, help="Job id of the setup_dataapi_role job.")
    ap.add_argument("--abac-job-id", default=None,
                    help="Job id of the ABAC column-masking demo job. Omitted/empty (the default when "
                         "deploy_abac_demo=false) => skip. Schema/group names come from the job's own defaults.")
    ap.add_argument("--profile", default=None, help="databricks CLI profile (omit in CI; use env auth).")
    ap.add_argument("--dry-run", action="store_true", help="Print the planned job runs; do not execute.")
    args = ap.parse_args()

    out = tf_outputs() if args.from_terraform else {}

    project = args.project_id or out.get("project_id")
    database = args.database or out.get("postgres_database") or "databricks_postgres"
    dev_group = args.developer_group if args.developer_group is not None else out.get("developer_group")
    app_sp = args.app_sp if args.app_sp is not None else out.get("app_service_principal_id")
    data_job = args.data_role_job_id or out.get("setup_data_role_job_id")
    api_job = args.dataapi_role_job_id or out.get("setup_dataapi_role_job_id")
    abac_job = args.abac_job_id or out.get("setup_abac_masking_job_id")

    if not project:
        raise SystemExit("Missing project_id (pass --project-id or --from-terraform).")

    log(f"project={project} database={database} dev_group={dev_group or '(skip)'} app_sp={app_sp or '(skip)'}")

    failures: list[str] = []

    # Developer GROUP -> read-only SELECT (direct-connection). GROUP => SELECT per policy.
    # A missing job id means the post-hook jobs weren't deployed (deploy_posthook=false)
    # — skip that grant, don't fail. (An ABAC-only apply has no data-role job.)
    if dev_group and dev_group not in ("", "null"):
        if not data_job or data_job in ("", "null"):
            log(f"skipping setup_data_role for group {dev_group}: no job (deploy_posthook=false).")
        else:
            ok = run_job(data_job, {
                "project_id": project, "database": database,
                "identity": dev_group, "identity_type": "GROUP",
                "privileges": privileges_for("GROUP"),
            }, args.profile, args.dry_run)
            if not ok:
                failures.append(f"setup_data_role for GROUP {dev_group}")

    # App SP -> Data API (GRANT sp TO authenticator + DML). Requires data_api.tf to have
    # enabled the API (so `authenticator` exists).
    if app_sp and app_sp not in ("", "null"):
        if not api_job or api_job in ("", "null"):
            log(f"skipping setup_dataapi_role for SP {app_sp}: no job (deploy_posthook=false).")
        else:
            ok = run_job(api_job, {
                "project_id": project, "database": database, "identity": app_sp,
            }, args.profile, args.dry_run)
            if not ok:
                failures.append(f"setup_dataapi_role for SP {app_sp}")

    # ABAC column-masking demo (only when deploy_abac_demo=true, i.e. the job id
    # is present). Schema + group names come from the job's parameter defaults, so
    # only project/database are passed here.
    if abac_job and abac_job not in ("", "null"):
        ok = run_job(abac_job, {
            "project_id": project, "database": database,
        }, args.profile, args.dry_run)
        if not ok:
            failures.append("setup_abac_masking (ABAC demo)")

    if failures:
        raise SystemExit("ERROR: data-plane grant(s) failed: " + "; ".join(failures))
    log("post-hook complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
