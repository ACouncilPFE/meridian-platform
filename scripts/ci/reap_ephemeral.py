"""Destroy preview environments whose `expires-at` tag has passed, or whose
PR is closed. Belt and braces for cost control: PR-close destroy can fail,
and an orphaned Aurora cluster is real money.

    python scripts/ci/reap_ephemeral.py --dir terraform/envs/ephemeral [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import UTC, datetime


def sh(*args: str, cwd: str | None = None) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


def expired_prs(now: datetime) -> set[int]:
    out = sh(
        "aws", "resourcegroupstaggingapi", "get-resources",
        "--tag-filters", "Key=env,Values=ephemeral", "--output", "json",
    )
    prs: set[int] = set()
    for res in json.loads(out)["ResourceTagMappingList"]:
        tags = {t["Key"]: t["Value"] for t in res["Tags"]}
        exp = tags.get("expires-at")
        if exp and datetime.fromisoformat(exp.replace("Z", "+00:00")) < now and tags.get("pr", "").isdigit():
            prs.add(int(tags["pr"]))
    return prs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    sh("terraform", "init", "-input=false", cwd=args.dir)
    workspaces = {w.strip("* ").strip() for w in sh("terraform", "workspace", "list", cwd=args.dir).splitlines()}
    targets = sorted(pr for pr in expired_prs(datetime.now(UTC)) if f"pr-{pr}" in workspaces)
    print(f"expired preview envs: {targets or 'none'}")

    for pr in targets:
        if args.dry_run:
            continue
        sh("terraform", "workspace", "select", f"pr-{pr}", cwd=args.dir)
        sh("terraform", "destroy", "-auto-approve", "-input=false",
           f"-var=pr_number={pr}", "-var=image=unused", cwd=args.dir)
        sh("terraform", "workspace", "select", "default", cwd=args.dir)
        sh("terraform", "workspace", "delete", f"pr-{pr}", cwd=args.dir)
        print(f"destroyed pr-{pr}")


if __name__ == "__main__":
    main()
