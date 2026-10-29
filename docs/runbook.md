# Runbook (macOS Apple Silicon, Docker Sandboxes `sbx`)

This is a test harness and a gated launcher, not a certified secure environment. Do not point
it at confidential source or use a primary Claude account until every gate in
[platform-investigation.md](platform-investigation.md) is closed with recorded evidence.

Versions this runbook was written against: macOS 26.6, `sbx` v0.50.1, Claude Code 2.1.312.
Re-check `sbx <cmd> --help` and `claude --help` if yours differ.

## 1. Host requirements
- Apple Silicon, macOS 14+.
- `brew trust docker/tap && brew install docker/tap/sbx`, then `sbx login` (Docker account,
  browser OAuth; required for creating sandboxes).
- A Docker engine for the compose proxy (OrbStack or Docker Desktop), or run the proxy
  directly: `ALLOWED_HOSTS=api.anthropic.com,claude.ai,platform.claude.com python3 proxy/egress_proxy.py`.
- `python3`, `curl`.

## 2. Unit tests and the egress proxy
```sh
python3 -m unittest discover -s tests -v
docker compose up --build -d
curl -sS -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:3128 https://example.com/   # 403
curl -sS -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:3128 https://api.anthropic.com/   # not 403
docker compose logs egress-proxy   # ALLOW/DENY audit lines
```
The proxy is a CONNECT-only allowlist bound to host loopback. It is the second layer; the
first is the `sbx` network policy. It must never be exposed to the LAN.

## 3. Host-wide `sbx` settings (affects every sandbox on this Mac)
Record current values first: `sbx settings ls --no-trunc > evidence/settings-before.txt`.
```sh
sbx policy init deny-all                       # one-time; use `sbx policy reset` to start over
sbx settings set ssh.agentForwardingEnabled false
sbx settings set browser.enabled false          # guest may not open host browser; login uses paste-code
sbx settings set claude.remoteControl false
sbx settings set skills.defaultMode off
sbx settings set proxy.sandbox http://127.0.0.1:3128
sbx settings unset no_proxy.sandbox 2>/dev/null || true
sbx daemon restart                              # proxy.sandbox applies to new sandboxes after restart
sh scripts/preflight.sh                         # must print "Preflight OK"
```
Do **not** add global allow rules. The launcher adds `api.anthropic.com:443,claude.ai:443,platform.claude.com:443`
scoped to the one sandbox it creates and removes them on exit. If `sbx` ever prompts to approve a
network destination, answer no; a review that needs more egress is out of scope (NET-07).

## 4. Acceptance run on a dummy repository
Use a throwaway Git repository with no secrets and, ideally, a Claude account you can afford
to have compromised. The launcher refuses to snapshot this repository itself.
```sh
host/launch_review.sh --repo /path/to/dummy-repo --unsafe-probe-mode --keep --name roas-accept
```
What happens, in order (each step aborts the run on failure):
1. preflight (settings, policy, proxy reachability)
2. snapshot built on the host by `host/prepare_snapshot.py`
3. `sbx create claude --name roas-accept --skills off` (mountless: no host directory is visible)
4. per-sandbox allow rules; `sbx policy check` confirms example.com/github.com/1.1.1.1 are denied
5. `sbx cp` of the snapshot into `/home/agent/workspace/review`
6. `scripts/test-egress.sh` as guest root (NET-02/03/04/06 passive, NET-01 positive)
7. `claude auth login` paste-code flow: open the printed URL in the host browser, paste the code
8. `scripts/verify-oauth-isolation.sh` as guest root (AUTH-02 / G1)
9. tool self-check: the guest `system/init` event must list only Glob, Grep, Read and no MCP (G4)
10. the review itself, `claude -p` with the read-only flag set, output streamed to the host
11. `sbx policy log roas-accept` saved as host evidence

Then, still on the disposable sandbox:
```sh
SANDBOX=roas-accept sh scripts/test-egress.sh --tamper      # NET-06 active: guest root rewrites DNS/firewall
docker compose stop egress-proxy
SANDBOX=roas-accept sh scripts/test-egress.sh --proxy-down  # NET-05: everything must fail closed
docker compose start egress-proxy
sbx exec -u root roas-accept sh -c 'ls -la /run/sandbox /var/run/docker.sock 2>&1; mount | grep -Ei "virtiofs|9p"'  # FS-02
sbx rm --force roas-accept
```
Write the observed outputs into `evidence/<date>.json` using the keys in `evidence.example.json`
(`status: pass` plus a pointer to the log for each). `python3 host/check_gates.py evidence/<date>.json`
must print `PASS`.

## 5. Real review
```sh
host/launch_review.sh --repo /path/to/target --evidence evidence/<date>.json \
  --prompt "Review for authorization and injection issues in the API layer."
```
Output lands in `review-output/<name>/review.md` with the raw stream, stderr and the sandbox's
policy log beside it. The sandbox and its allow rules are destroyed on exit unless `--keep`.
Treat the review as untrusted text produced from untrusted input.

## 6. Cleanup / restore
```sh
sbx secret ls                      # must be empty; /login stores a GLOBAL host-side grant
sbx secret rm anthropic -f         # if not, remove it (the launcher does this on teardown)
sbx ls; sbx rm --force <leftovers>
docker compose down
```
Restore the settings recorded in step 3 if this Mac is also used for other sandboxes.

## Known limitations
- Login is interactive by design (paste-code). There is no unattended first run.
- Docker chains only explicitly proxied HTTP(S) to the upstream proxy; transparent TCP to an
  allowed host bypasses it (observed). The `sbx` policy is the boundary; the upstream proxy log is partial.
- The OAuth grant created by `/login` lives in Docker's host store with global scope and is injected
  into every sandbox on the host until `sbx secret rm anthropic -f`. The launcher does this on teardown.
- Secret filtering in the snapshot is heuristic. Inspect the snapshot before confidential use.
- The guest can still send anything it can read to Anthropic through the allowed channel.
  That is inherent to a cloud-model review and is listed as a residual risk.
