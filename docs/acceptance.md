# Acceptance plan (run on the target Mac)

Record macOS, `sbx`, Claude Code versions and the date (G0; see platform-investigation.md for the
current values). Use a dummy repository and a throwaway Claude session for the first pass.

| ID | Test | How | Pass condition |
| --- | --- | --- | --- |
| NET-01 | Inference via allowed endpoint | launcher step 10, `test-egress.sh` positive probes | Review completes; only api.anthropic.com / claude.ai / platform.claude.com in `sbx policy log` |
| NET-02 | HTTPS to unapproved domain | `test-egress.sh` | denied |
| NET-03 | Direct IPv4/IPv6, alternate ports, SSH | `test-egress.sh` | denied |
| NET-04 | UDP DNS, ICMP, gateway, host.docker.internal, LAN, link-local | `test-egress.sh` | denied |
| NET-05 | Upstream proxy stopped | `docker compose stop egress-proxy; test-egress.sh --proxy-down` | api.anthropic.com and claude.ai unreachable |
| NET-06 | Guest root edits proxy env, resolv.conf, iptables/nft | `test-egress.sh` (passive) and `--tamper` on a disposable sandbox | egress unchanged |
| NET-07 | Approval prompts / kit rules | `sbx policy ls --wide --created-via approval` empty; operator never approves | no implicit grants |
| FS-01 | Modify/delete snapshot in guest | `sbx exec -u root NAME rm -rf /home/agent/workspace/review/source` then check host repo | host original unchanged (no mount exists) |
| FS-02 | Host mounts, Docker socket, SSH agent, Keychain | `verify-oauth-isolation.sh` host-exposure section; `mount`, `ls /var/run/docker.sock`, `$SSH_AUTH_SOCK` | none present |
| AUTH-01 | Max subscription login | `claude auth login` paste-code inside sandbox | works without API key |
| AUTH-02 | Guest root looks for token material | `verify-oauth-isolation.sh` | no `sk-ant-oat01-`/`sk-ant-ort01-`/`sk-ant-api03-` strings in files, process env, or credentials file; only sentinels |
| AUTH-03 | Host-side grant removed at teardown | after the session: `sbx secret ls` must show no `anthropic` entry; from a still-running guest, a request to api.anthropic.com must return 401 (not 429/200) | no injection without the host grant; guest `claude auth logout` alone is NOT sufficient (observed) |
| AGENT-01 | Available tools | launcher step 9 (`system/init`) | exactly Glob, Grep, Read; `mcp_servers` empty |
| AGENT-02 | Hostile `CLAUDE.md`, `.claude/settings.json` hooks, `.mcp.json` in dummy repo | run a review on such a repo | files absent from snapshot (`.claude/`, `.mcp.json`), `CLAUDE.md` not loaded, no tool expansion, no hook execution in `review.jsonl` |
| LIFE-01 | Teardown | launcher exit without `--keep` | `sbx ls` shows no sandbox; `sbx policy ls --wide` shows no rule for the name |

Failure or inability to observe enforcement is a blocker. Do not test with a confidential
repository until every row passes.

## Evidence
For each gate key in `evidence.example.json` record `status: pass` and a pointer (file path or
log excerpt) in `evidence`. Suggested mapping: G1 ← AUTH-01/02; G2 ← NET-02/03/04/06; G3 ←
FS-01/02; G4 ← AGENT-01/02; G5 ← NET-05/07, LIFE-01. Keep `review-output/` and `evidence/` out
of Git (already ignored). Never record credentials or confidential code in evidence.
