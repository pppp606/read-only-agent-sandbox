# Proposed architecture and decision gates

## Candidate
macOS host -> externally controlled VM egress enforcement -> isolated agent microVM -> immutable review snapshot. Approved inference/authentication traffic reaches Anthropic through a **host-controlled** proxy or credential broker.

**Important:** A Dockerized Squid proxy is not by itself an independent boundary. Prove that the guest has no other egress path and that any sandbox-managed network policy cannot bypass the upstream proxy. Also prove that the proxy cannot be modified from the guest. If these properties cannot be established, do not deploy.

## Platform evaluation
- Docker Sandboxes: preferred first prototype due to agent integration, but its network, mountless, authentication, kit rules, approval prompts, and upstream-proxy behavior must be verified against installed versions. Do not assume the default preset is read-only.
- Apple Virtualization.framework: fallback if Docker Sandboxes cannot enforce the boundary; requires custom guest bootstrapping and host-level network filtering.
- Firecracker: Linux/KVM only, not directly usable as a macOS hypervisor.

## OAuth / Claude Max
Use Claude subscription login, not ANTHROPIC_API_KEY. Determine empirically whether OAuth credentials are brokered outside the guest and inaccessible to guest root. Do not copy or mount host ~/.claude or Keychain material. Record exact auth endpoints and only permit those required. If external credential isolation cannot be demonstrated, do not use real credentials in the guest.

## Input preparation
On the trusted host, create a fresh review snapshot. Strip secrets and credentials, reject symlinks escaping the snapshot, bound history size, and ensure Git history does not include sensitive removed files. Prefer a pre-extracted Git log/diff/blame corpus over giving the guest a .git directory. Guest may mutate its own copy but never the host original.

## Agent
Use explicit allowlisted read-only tools. Disable Bash, edits, writes, WebFetch, WebSearch, external MCP, hooks and automatic extension loading. The exact Claude Code settings and whether any invocation can bypass them must be verified against the installed version. Repository CLAUDE.md and other instructions are untrusted input.

## Decision gates
G0: exact versions and platform capabilities recorded.
G1: Max OAuth authentication works without guest-readable secrets.
G2: guest-root cannot bypass externally enforced egress.
G3: guest-root cannot read host assets or mutate originals.
G4: agent has no arbitrary execution/write tools and untrusted instructions cannot expand privileges.
G5: automated negative tests pass, including proxy-down fail-closed behavior.
Only after G0-G5 may a real code review run.

## References to verify during implementation
- https://docs.docker.com/ai/sandboxes/
- https://docs.docker.com/ai/sandboxes/security/
- https://docs.docker.com/ai/sandboxes/configuration/upstream-proxy/
- https://docs.anthropic.com/en/docs/claude-code/security

Documentation and CLI behavior may change. These are design inputs, not claims that a particular installed version passes the gates.
