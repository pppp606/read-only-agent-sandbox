# read-only-agent-sandbox

An experimental, fail-closed environment for **read-only AI code review** on macOS.

## Goals
- Allow an agent to inspect source code and selected Git history.
- Do not execute project code, package managers, tests, or shell commands through the agent.
- Protect the original repository and host credentials even if the guest is compromised.
- Restrict egress at a boundary controlled **outside** the agent's guest VM.
- Support Claude Code with a Max subscription (OAuth); do not require an Anthropic API key.
- Keep the isolation layer independent of the model and agent implementation.

## Status: DESIGN / NOT SAFE TO RUN YET

This repository deliberately contains **no runnable sandbox launcher** until the external enforcement boundary, OAuth flow, and fail-closed egress behavior are verified on the target macOS/Docker Desktop versions. Do not treat Claude Code permission settings, prompts, or Docker Sandboxes' preset labels as security guarantees.

Start with [the threat model](docs/threat-model.md), [architecture](docs/architecture.md), and [acceptance tests](docs/acceptance.md).

## Security principle

Assume the model can disregard its instructions and that all content in the reviewed repository is adversarial. Controls must remain effective even if the guest acquires root. Any inability to verify the required boundaries means **no review session is started**.

No real source repositories, secrets, OAuth tokens, or private Git history should ever be committed to this repository.

## Host-side prototype commands

```sh
python3 -m unittest discover -s tests -v
python3 host/prepare_snapshot.py /path/to/repository /tmp/roas-review-001
python3 host/check_gates.py evidence.example.json  # expected BLOCKED
```

Only the generated snapshot may eventually be supplied to the guest; **never mount this repository into the agent VM**. See [isolation contract](docs/isolation-contract.md) and [runbook](docs/runbook.md).

CI tests are not an egress E2E proof. A complete launcher is intentionally blocked until OAuth, network and guest-root checks can be demonstrated on the actual Mac.
