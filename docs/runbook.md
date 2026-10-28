# Prototype runbook (macOS Apple Silicon)

This is a **runnable prototype and test harness**, not a certified secure review environment. It must not be used with real confidential source or OAuth credentials until all gates pass.

## 1. Host requirements
macOS 14+, Apple Silicon, Docker Engine/Desktop for the separate proxy container, Docker Sandboxes `sbx` CLI, Python 3, curl. Run `sh scripts/preflight.sh`. Compare installed CLI help to documentation.

## 2. Local proxy and deterministic tests
```sh
python3 -m unittest discover -s tests -v
docker compose up --build -d
curl -sS -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:3128 https://example.com/
# Expect 403, not 200. Do not confuse this proxy-only test with VM egress isolation.
```

The example Python CONNECT proxy is deliberately small and unauthenticated, listens only on host loopback through Docker, and **must not be exposed to LAN**. It is not a production security product. Before real use replace it with a maintained, hardened proxy and log/monitor it. The prototype forwards opaque TLS, so it cannot inspect prompts or responses.

## 3. Configure Docker Sandboxes (host-wide settings!)
Review current settings before changing anything:
```sh
sbx settings ls --no-trunc
sbx policy ls --wide
```
These changes affect other local sandboxes. Do not run blindly on a shared machine.
```sh
sbx settings set ssh.agentForwardingEnabled false
sbx settings set browser.enabled false
sbx settings set proxy.sandbox http://127.0.0.1:3128
sbx settings set no_proxy.sandbox ""
sbx daemon restart
```
Check `sbx settings get proxy.sandbox` and verify that the sandbox's host-side proxy actually reaches Docker's loopback published port. A failed connection must stop the rollout. Verify policy syntax on the installed CLI (`sbx policy init --help`, `sbx policy allow --help`). Initialize deny-all and explicitly allow only the verified inference and login destinations; inspect kit/agent-added rules. Never automatically approve network access prompts.

**No agent session is authorized by this runbook yet.** Do not start the agent with `--dangerously-skip-permissions`. Auth and agent permission isolation need independent validation.

## 4. Disposable VM egress probes
Create a disposable shell sandbox, with **no host workspace mounted**:
```sh
sbx create --name roas-egress shell
SANDBOX=roas-egress sh scripts/test-egress.sh
```
Run probes with operator-controlled `sbx exec` only. If `sbx create shell` needs a path on your version, stop and inspect CLI help rather than mounting a real repository.

Positive Anthropic connectivity, proxy-down fail-closed, direct IPv6, private/LAN access, DNS, guest-root manipulation, auth secrecy and no extra kit rules remain **manual release blockers**. The test script is not a complete e2e certification.

## 5. Cleanup
```sh
sbx rm roas-egress
docker compose down
```
Restore host-wide settings from the values recorded in step 3; do not reset blindly.

## Status
The proxy and negative-probe scripts are runnable, but no actual Mac or `sbx` runtime was available to execute integration tests in this repository authoring session. Never interpret successful unit tests alone as permission to review sensitive code.
