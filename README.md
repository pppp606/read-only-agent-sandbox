# read-only-agent-sandbox

A fail-closed environment for **read-only AI code review** on macOS, built on Docker Sandboxes
microVMs (`sbx`) with Claude Code and a Claude Max subscription (OAuth, no API key).

## Goals
- The agent reads a sanitized snapshot of source code and selected Git history. Nothing else.
- No code execution, package installation, tests, file edits or shell for the agent.
- Host repository, host credentials and host network stay protected even if the guest is
  compromised and the agent has root inside the VM.
- Egress is enforced outside the guest and defaults to deny. Only Anthropic inference and
  claude.ai login endpoints are reachable.
- The isolation layer does not depend on the model or the agent implementation.

## Status: ACCEPTANCE PASSED ON ONE MAC (2026-10-29)

All gates G0–G5 passed on the author's Apple Silicon Mac with `sbx` v0.50.1 (results and
findings in [docs/platform-investigation.md](docs/platform-investigation.md)). The launcher
refuses to start a real review unless a per-machine evidence file passes `host/check_gates.py`;
every other machine must repeat the acceptance run. Guest-root OAuth isolation (G1) holds
because Docker keeps the grant on the host and injects it at the proxy; that grant is global
to the host, so the launcher removes it on teardown.

Read in this order: [threat model](docs/threat-model.md), [architecture](docs/architecture.md),
[platform investigation](docs/platform-investigation.md), [runbook](docs/runbook.md),
[acceptance](docs/acceptance.md), [isolation contract](docs/isolation-contract.md).

## Layout
| Path | Role |
| --- | --- |
| `host/prepare_snapshot.py` | builds the only input the guest ever sees |
| `host/check_gates.py` | fail-closed evidence check; launcher refuses without `PASS` |
| `host/launch_review.sh` | gated end-to-end launcher (mountless sandbox, per-sandbox allowlist, probes, login check, tool self-check, review, teardown) |
| `proxy/egress_proxy.py`, `compose.yaml` | host-loopback CONNECT allowlist proxy with audit log (second egress layer) |
| `scripts/preflight.sh` | verifies host-wide `sbx` settings and policy posture |
| `scripts/test-egress.sh` | guest-root egress probes (standard, `--tamper`, `--proxy-down`) |
| `scripts/verify-oauth-isolation.sh` | guest-root sweep for subscription tokens (AUTH-02 / G1) |
| `prompts/reviewer.md` | review instructions appended to the system prompt |
| `tests/` | unit tests for the host tools (run in CI) |

```sh
python3 -m unittest discover -s tests -v
python3 host/check_gates.py evidence.example.json   # BLOCKED, by design
```

## Security principle
Assume the model ignores its instructions and that everything in the reviewed repository is
adversarial. Prompts and Claude Code permission settings are not the boundary; the microVM,
the host-side network policy and the host-side credential handling are. If any of them cannot
be verified on the actual machine, no review runs. Never mount this repository, `~/.claude`,
SSH keys or the Docker socket into a sandbox.
