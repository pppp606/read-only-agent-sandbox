# Platform investigation (2026-10-29, Apple Silicon Mac)

This records what was actually observed on the target machine and in the current
official documentation. "Verified" means executed locally; "documented" means read
in official docs but not yet exercised here. Anything marked **open** blocks a gate.

## Host inventory (verified)

| Item | Value |
| --- | --- |
| macOS | 26.6.2 (25G83), arm64 |
| Docker Desktop | 4.24.2 (2023, no sandbox support, CLI plugins only) |
| Docker context | OrbStack 2.1.1 (daemon stopped at inspection time) |
| Docker Sandboxes CLI | `sbx` v0.50.1, installed via `brew install docker/tap/sbx` during this investigation |
| sbx daemon | running; **not signed in** (`sbx login` is a browser OAuth to Docker and must be done by the operator) |
| sbx global network policy | **not initialized** (must become `deny-all`) |
| Claude Code (host) | 2.1.312 |
| Python (host) | 3.9.17 (CI uses 3.13; both now pass) |
| Virtualization | `kern.hv_support = 1` |

Consequences:

- The old `docker sandbox` plugin flow in earlier notes is obsolete. `sbx` is a standalone
  CLI that needs neither Docker Desktop nor Docker Engine (docs: install page). Local
  sandboxes are free.
- OrbStack is **not** a candidate: all containers share one Linux VM that has host
  filesystem passthrough, so a guest root escape from a container lands in a VM with host
  access.
- Docker Desktop 4.24 is irrelevant to this design and can stay as is. The compose egress
  proxy only needs *some* Docker engine (OrbStack works once started), or the proxy can be
  run directly with `python3 proxy/egress_proxy.py` on the host.

## Docker Sandboxes: what it provides (v0.50.1)

### Isolation model (documented, consistent with CLI)
- One microVM per sandbox, own kernel and own Docker Engine, "no path to the host daemon".
  The agent has sudo inside the VM. Virtualization is Apple Virtualization.framework-class
  (daemon reports `kern.hv_support`), hypervisor not named by Docker.
- Workspace modes: **direct** bind mount (read-write, same path as host), **clone**
  (`--clone`, host repo mounted read-only at `/run/sandbox/source`), **mountless** (no path
  argument). This project uses **mountless** and copies a sanitized snapshot in with
  `sbx cp`. Extra `PATH:ro` workspaces exist but still expose a host directory; not used.
- Shared skills store is mounted into every sandbox by default (`skills.defaultMode=readonly`).
  It is a cross-sandbox channel; we pass `--skills off` and set the default to `off`.
- `~/.claude` of the host is **not** picked up (documented on the Claude Code agent page).

### Network (documented; CLI verified)
- "All outbound TCP traffic from the sandbox routes through a proxy on your host." HTTP(S)
  goes through a forward proxy that also does credential injection; other TCP is forwarded
  transparently; both are subject to network policy. UDP is off by default, ICMP blocked.
  "Sandboxes cannot communicate directly over the network."
- Policy CLI verified: `sbx policy init deny-all`, `sbx policy allow network [--sandbox NAME] HOST:PORT`,
  `sbx policy deny network`, `sbx policy check network [--sandbox NAME] TARGET`,
  `sbx policy ls --wide`, `sbx policy log NAME`. Deny beats allow. Per-sandbox *allow*
  rules are supported locally (`--sandbox`), so the global policy can stay `deny-all`.
- `balanced` preset is broad (e.g. `*.googleapis.com`); never use it for this workflow.
- Upstream proxy: `sbx settings set proxy.sandbox http://127.0.0.1:3128` chains Docker's
  host proxy to ours. Docs: "Only HTTP and HTTPS traffic can be forwarded to an upstream
  proxy." Therefore the sbx network policy is the primary boundary and our CONNECT proxy is
  defense in depth plus an independent host-side audit log. Both are outside the guest.
- Interactive approval prompts for new domains exist (`--created-via approval` filter in
  `sbx policy ls`). The operator must never approve one during a review (NET-07).

### Credentials (documented)
- API keys: `sbx secret set anthropic` stores in the macOS Keychain; the guest sees a
  sentinel and the host proxy injects the real header for allowed provider domains.
- Claude subscription (Max) OAuth: get-started page states "For Claude subscriptions, you
  sign in with `/login` inside the sandbox. The session token stays on your host and is
  never stored inside the sandbox." The credentials page is less explicit and mentions a
  kit-level `passthrough: true` that would send the real token into the guest. **Open (G1):**
  this must be verified with `scripts/verify-oauth-isolation.sh` as guest root. If a real
  `sk-ant-oat01-`/`sk-ant-ort01-` token is found, the requirement is not met.
- `browser.enabled=true` lets the guest open URLs in the host browser and is what makes the
  in-sandbox `/login` redirect work. It is also a guest-to-host channel. The runbook keeps it
  **false** and uses the paste-code flow (`claude auth login`).
- `ssh.agentForwardingEnabled=true` by default. Must be `false`.

### Defaults that Docker applies to the Claude agent (documented)
- `sbx run claude` launches `claude --dangerously-skip-permissions`; flag-style extra args are
  appended, bare-word args replace the defaults. To avoid any ambiguity the launcher never uses
  `sbx run` for the agent. It uses `sbx exec` with a fully specified argument list.
- Base image `docker/sandbox-templates:claude-code`, WORKDIR `/home/agent/workspace`.

## Claude Code 2.1.312: what was verified locally

Command (run on the host against a scratch directory):

```
claude -p --restricted --tools "Read,Grep,Glob" \
  --disallowedTools Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Agent "mcp__*" \
  --strict-mcp-config --disable-slash-commands --setting-sources user \
  --permission-mode dontAsk --permission-prompts none --output-format stream-json --verbose "..."
```

Result: the `system/init` event reported `tools: ["Glob","Grep","Read"]`, `mcp_servers: []`,
`permissionMode: dontAsk`, and the model answered with the same three names. Three built-in
plugins (agents-md, telemetry, plugin-authoring) are still listed; they add no tools.

Facts from the official docs relevant to the boundary (see sources at the end):

- `--restricted` ignores user/project/local settings, removes code-running tools and WebFetch,
  and refuses `bypassPermissions`. It needs 2.1.248+.
- `--bare` disables OAuth entirely ("never reads OAuth credentials"), so it cannot be used
  with a subscription. Observed: `--bare` returned "Not logged in".
- In `-p` mode a repository's `.claude/settings.json` hooks and `.mcp.json` servers load
  without a trust prompt unless `--restricted`/`--strict-mcp-config` are used. The snapshot
  additionally strips `.claude/` and `.mcp.json`, and `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` keeps
  `CLAUDE.md` out of context (it remains reviewable as a file).
- Linux credential storage is plaintext `~/.claude/.credentials.json` (mode 0600). This is why
  G1 hinges on Docker's sentinel mechanism, not on Claude Code.
- Hosts needed for a subscription session: `api.anthropic.com` (inference, feature flags,
  telemetry), `claude.ai` (account auth), `platform.claude.com` (token exchange/refresh),
  `claude.com` only for the browser page that the operator opens on the host.
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `DISABLE_AUTOUPDATER=1` remove the rest.
- Anthropic's legal page: OAuth is for subscribers' "ordinary use of Claude Code and other
  native Anthropic applications"; third-party developers "may not collect, store, or
  intermediate Claude.ai credentials or session tokens"; signing in to the unmodified binary
  with your own subscription is explicitly allowed. In this design the operator signs in to an
  unmodified Claude Code with their own account; the token handling is Docker's product
  behaviour, and no token is copied or injected by this project. Whether that satisfies
  Anthropic's intent is a judgment for the account holder, not something this repository
  can certify.

## Alternative platform (not pursued now)

Apple `container` (apple/container, macOS 26 only, VM per container via
Virtualization.framework, vmnet networking, `--mount ...,readonly`, `container network create
--internal`). It gives the same microVM boundary but **no built-in egress policy or credential
broker**: enforcement would have to be a host `pf` ruleset confining the vmnet subnet to the
proxy port, and OAuth tokens would live in the guest unless a custom TLS-terminating broker is
written. That is more code in the trusted computing base than the Docker Sandboxes path, so it
is the fallback only if G1/G2 fail on Docker Sandboxes.

## Gate status after this investigation

| Gate | Status | How to close |
| --- | --- | --- |
| G0 versions | **recorded above** | re-record if any component changes |
| G1 OAuth not readable by guest root | open | `sbx login`, run launcher in `--unsafe-probe-mode` on a dummy repo with a throwaway session, read `verify-oauth-isolation.sh` output |
| G2 egress enforced outside guest | open | `scripts/test-egress.sh` standard + `--tamper` on a disposable sandbox |
| G3 host integrity | open | FS-01/FS-02 manual checks; mountless design plus `verify-oauth-isolation.sh` host-exposure section |
| G4 agent tools | **verified on host**, open in guest | launcher step 9 records the guest `system/init` tool list |
| G5 negative tests incl. proxy-down | open | `test-egress.sh`, then stop compose proxy and run `--proxy-down` |

Nothing in this document is evidence that the gates pass; it is the map of how to produce
that evidence.

## Sources
- https://docs.docker.com/ai/sandboxes/ (overview, install, get-started, architecture, security, security/defaults, configuration/credentials, configuration/upstream-proxy, agents/claude-code)
- `sbx --help`, `sbx <cmd> --help` on v0.50.1; `sbx settings ls`, `sbx diagnose`
- https://code.claude.com/docs/en/ (authentication, network-config, permissions, cli-reference, headless, sandboxing, sandbox-environments, legal-and-compliance)
- `claude --help` on 2.1.312
- https://github.com/apple/container (README, docs/technical-overview.md, docs/command-reference.md)
