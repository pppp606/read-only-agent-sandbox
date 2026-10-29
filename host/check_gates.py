#!/usr/bin/env python3
"""Host-only fail-closed gate verifier; reads evidence, never trusts guest output alone."""
import argparse
import json
from pathlib import Path

REQUIRED = [
    "G0_versions", "G1_oauth_guest_root", "G2_egress_guest_root",
    "G3_host_integrity", "G4_agent_permissions", "G5_negative_network",
    "G5_proxy_down", "G5_ipv6_lan_dns",
]

def evaluate(data):
    if set(data) != set(REQUIRED):
        return False, "missing or unexpected gate keys"
    for key in REQUIRED:
        item = data[key]
        if not isinstance(item, dict) or item.get("status") != "pass":
            return False, f"{key} is not pass"
        if not isinstance(item.get("evidence"), str) or not item["evidence"].strip():
            return False, f"{key} lacks evidence"
    return True, "all gates explicitly marked pass (not independently authenticated)"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("evidence", type=Path)
    args = p.parse_args()
    try:
        ok, reason = evaluate(json.loads(args.evidence.read_text()))
    except (OSError, ValueError) as exc:
        ok, reason = False, str(exc)
    print(("PASS: " if ok else "BLOCKED: ") + reason)
    raise SystemExit(0 if ok else 1)

if __name__ == "__main__":
    main()
