#!/usr/bin/env python3
"""Disable / enable / delete Conditional Access policies by name pattern.

Uses the existing Azure CLI login for Microsoft Graph auth, so run `az login` first.
Write operations need the Policy.ReadWrite.ConditionalAccess scope:
    az login --use-device-code --scope https://graph.microsoft.com/Policy.ReadWrite.ConditionalAccess

Examples:
    python3 ca_policy_toggle.py list
    python3 ca_policy_toggle.py disable                 # dry run
    python3 ca_policy_toggle.py disable --apply
    python3 ca_policy_toggle.py enable --apply
    python3 ca_policy_toggle.py delete --apply
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

GRAPH = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"

# Substrings matched case-insensitively against policy displayName.
DEFAULT_PATTERNS = ["security info registration", "multifactor authentication"]

BACKUP_DIR = Path(__file__).parent / "ca_policy_backups"


def az_rest(method: str, url: str, body: dict | None = None) -> dict | None:
    cmd = ["az", "rest", "--method", method, "--url", url]
    if body is not None:
        cmd += ["--body", json.dumps(body), "--headers", "Content-Type=application/json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def list_policies() -> list[dict]:
    return az_rest("get", GRAPH)["value"]


def match(policies: list[dict], patterns: list[str]) -> list[dict]:
    lowered = [p.lower() for p in patterns]
    return [p for p in policies if any(s in (p.get("displayName") or "").lower() for s in lowered)]


def backup(policies: list[dict]) -> Path:
    BACKUP_DIR.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = BACKUP_DIR / f"ca_policies_{stamp}.json"
    path.write_text(json.dumps(policies, indent=2))
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["list", "disable", "enable", "delete"])
    parser.add_argument("--pattern", action="append", help="Name substring to match (repeatable). Defaults to the security-info/MFA policies.")
    parser.add_argument("--apply", action="store_true", help="Actually perform the change. Without this it is a dry run.")
    args = parser.parse_args()

    patterns = args.pattern or DEFAULT_PATTERNS

    try:
        policies = list_policies()
    except RuntimeError as exc:
        print(f"Failed to read policies: {exc}", file=sys.stderr)
        return 1

    targets = match(policies, patterns)
    if not targets:
        print(f"No policies matched: {patterns}")
        return 0

    print(f"Matched {len(targets)} of {len(policies)} policies:")
    for p in targets:
        print(f"  - {p['displayName']!r}  state={p['state']}  id={p['id']}")

    if args.action == "list":
        return 0

    if not args.apply:
        print(f"\nDRY RUN — would {args.action} the policies above. Re-run with --apply to execute.")
        return 0

    path = backup(targets)
    print(f"\nBacked up current definitions to {path}")

    failures = 0
    for p in targets:
        url = f"{GRAPH}/{p['id']}"
        try:
            if args.action == "delete":
                az_rest("delete", url)
            else:
                state = "disabled" if args.action == "disable" else "enabled"
                az_rest("patch", url, {"state": state})
            print(f"  OK  {args.action}d {p['displayName']!r}")
        except RuntimeError as exc:
            failures += 1
            print(f"  FAIL {p['displayName']!r}: {exc}", file=sys.stderr)

    if failures:
        print(f"\n{failures} operation(s) failed. Microsoft-managed policies often cannot be deleted — try 'disable' instead.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
