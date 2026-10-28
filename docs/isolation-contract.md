# Host/guest separation contract

The agent guest must receive **only** a sanitized review snapshot and a minimal review prompt. Never mount or copy this repository, `host/`, `scripts/`, `tests/`, `proxy/`, `evidence/`, `.github/`, or host logs into the guest.

Host-side preparation:
```sh
python3 host/prepare_snapshot.py /path/to/target-repo /tmp/roas-input-001
```
The snapshot contains `source/`, metadata-only `history.txt`, and `REVIEW_SCOPE.txt`. It does **not** contain a `.git` directory, diffs, untracked files, symlinks, or files matching common secret names. This is a *best-effort filter*, not proof of secret removal. Commit messages and source files may still contain sensitive information. Inspect the snapshot before copying it to a VM. The guest may edit its copy; the host original must remain unaffected.

**Security gate:** do not start Claude Code or send source to Anthropic until all required host-side tests have independently passed. The evidence JSON checker enforces completeness of declarations, not truth of evidence; it cannot replace test execution or trustworthy attestation.

```sh
python3 host/check_gates.py evidence.example.json
# Expected exit 1 / BLOCKED
```

## What is deliberately not implemented
An automatic agent launcher, OAuth credential bridge, and sandbox copy/mount operations. Their correct APIs and isolation behavior depend on the installed Docker Sandboxes version and need local validation. A fake launcher that skips those checks would defeat the threat model.

## Confidentiality note
The public repository contains defensive test logic, which is acceptable. The **guest must not have access** to this repository or host enforcement configuration. Keeping controls hidden is defense in depth, not the isolation boundary.
