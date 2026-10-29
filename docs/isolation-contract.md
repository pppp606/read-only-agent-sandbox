# Host/guest separation contract

The guest receives **only**:
- `source/` — tracked, filtered files of the target repository
- `history.txt` — commit hash, author date, subject (no diffs, no bodies)
- `REVIEW_SCOPE.txt` — a note that this is untrusted input
- `REVIEW_INSTRUCTIONS.md` — a copy of `prompts/reviewer.md` (also appended to the system prompt)

The guest never receives: this repository or any of `host/`, `scripts/`, `tests/`, `proxy/`,
`evidence/`, `.github/`, `review-output/`; the original repository or its `.git`; untracked
files; symlinks; `.env*`; key or credential files; `.claude/`; `.mcp.json`; host logs; proxy
configuration; OAuth tokens; SSH keys; the Docker socket.

Mechanism:
- The sandbox is created **mountless** (`sbx create claude --name NAME --skills off`), so no host
  path exists inside the VM. The shared skills store is disabled.
- The snapshot is produced on the host by `host/prepare_snapshot.py` into a temporary directory
  outside both repositories and copied in with `sbx cp`. The launcher aborts if it finds
  `.mcp.json` or `.claude/` in the snapshot.
- Review output comes back over the `sbx exec` stdout stream, never through a shared directory.
- The sandbox and its per-sandbox network rules are destroyed when the launcher exits.

```sh
python3 host/prepare_snapshot.py /path/to/target-repo /tmp/roas-input-001
```

**This is a best-effort filter, not proof of secret removal.** Commit subjects and source files
can still contain sensitive data; Git history may have contained secrets that are no longer
tracked (those never reach the snapshot because diffs are excluded, but subjects might
mention them). Inspect the snapshot before using confidential input.

**Security gate:** `host/launch_review.sh` refuses to run without an evidence file that
`host/check_gates.py` accepts. The checker verifies completeness and explicit `pass` status of
operator-recorded evidence; it does not and cannot verify the truth of that evidence. The
`--unsafe-probe-mode` flag bypasses the gate for acceptance testing on dummy repositories only
and refuses to snapshot this repository.

## Confidentiality note
This public repository contains the defensive logic; that is acceptable. Keeping the controls
out of the guest is defense in depth, not the boundary. The boundary is the microVM plus
host-side policy and credential handling.
