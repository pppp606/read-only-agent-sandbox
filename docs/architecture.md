# Architecture and decision gates

## Chosen platform: Docker Sandboxes (`sbx`) microVMs

```
macOS host
 ├─ sbx daemon (host): network policy deny-all + per-sandbox allow, credential sentinel/injection, policy log
 │    └─ upstream HTTP(S) proxy: proxy/egress_proxy.py on 127.0.0.1:3128, CONNECT allowlist, audit log
 ├─ host/launch_review.sh: gates -> snapshot -> create -> probes -> login check -> tool check -> review -> destroy
 └─ microVM (one per review, mountless, destroyed afterwards)
      ├─ /home/agent/workspace/review/{source,history.txt,REVIEW_SCOPE.txt,REVIEW_INSTRUCTIONS.md}
      └─ claude -p --restricted --tools Read,Grep,Glob ... (guest root assumed hostile)
```

Why this platform (details in [platform-investigation.md](platform-investigation.md)):
- hypervisor isolation per sandbox, own kernel, no host Docker socket;
- all guest TCP is proxied on the host and subject to a policy the guest cannot edit; UDP off,
  ICMP blocked;
- credentials for allowed providers are swapped in on the host, the guest sees sentinels;
- mountless mode means no host directory exists inside the VM; input arrives by `sbx cp`.

Rejected: OrbStack (shared VM with host filesystem passthrough), Docker Desktop containers
(shared kernel), running Claude Code's own bubblewrap/Seatbelt sandbox on the host (covers Bash
only, credentials on host). Fallback: Apple `container` with a host `pf` ruleset and a custom
credential broker, only if G1/G2 fail on Docker Sandboxes.

## Boundary analysis
| Property | Enforced by | Guest can influence? |
| --- | --- | --- |
| No host files | mountless sandbox; snapshot copied in | no (no mount exists) |
| No host repo mutation | guest only has a copy | no |
| Egress deny-all | sbx host-side policy + upstream CONNECT allowlist | no; env vars, routes, DNS, firewall are inside the VM |
| Fail closed | upstream proxy down ⇒ Docker's proxy cannot chain HTTP(S); policy denies everything else | no |
| OAuth not in guest | Docker's host-side token handling (to be verified, G1) | can read the sentinel only |
| No execution tools | `--restricted --tools Read,Grep,Glob`, `--strict-mcp-config`, snapshot strips `.claude/` and `.mcp.json` | defense in depth only; VM is the real boundary |
| Disposable | `sbx rm --force` on exit; per-sandbox allow rules removed | no |

What the guest *can* still do: exfiltrate anything inside the VM to Anthropic through the
allowed inference channel, produce misleading review output, and consume the subscription.
These are accepted residual risks of using a hosted model.

## Agent configuration (verified on Claude Code 2.1.312)
`--restricted --tools "Read,Grep,Glob" --disallowedTools Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Agent "mcp__*" --strict-mcp-config --disable-slash-commands --setting-sources user --permission-mode dontAsk --permission-prompts none`
plus environment `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_DISABLE_WEB_FETCH=1 ENABLE_CLAUDEAI_MCP_SERVERS=false`.
The launcher reads the `system/init` event and aborts unless the tool list is a subset of
{Read, Grep, Glob} with no MCP servers. `--bare` is not usable (it disables OAuth) and
`--dangerously-skip-permissions` is never passed (and is refused by `--restricted`).

## Input preparation
`host/prepare_snapshot.py` copies tracked, non-symlink, non-binary files under size limits,
drops credential-like names, `.env*`, `.git`, `.claude/`, `.mcp.json`, build output and
dependency directories, aborts on known secret markers, and emits a metadata-only Git log
(hash, date, subject). Diffs are deliberately excluded because removed secrets live in them.
This is best effort. Inspect before confidential use.

## Decision gates
- G0: versions recorded (done for this Mac; redo on change).
- G1: Max OAuth works and guest root cannot read token material (`scripts/verify-oauth-isolation.sh`).
- G2: guest root cannot widen egress (`scripts/test-egress.sh`, standard and `--tamper`).
- G3: no host assets reachable, originals untouched (FS-01/FS-02).
- G4: guest tool list is exactly read-only (launcher self-check output).
- G5: negative tests pass including `--proxy-down`.
Only an evidence file that `host/check_gates.py` accepts lets the launcher start a real review.

## References
- https://docs.docker.com/ai/sandboxes/ (security, architecture, configuration/credentials, configuration/upstream-proxy, agents/claude-code)
- https://code.claude.com/docs/en/ (permissions, cli-reference, network-config, authentication, sandbox-environments, legal-and-compliance)
