# Acceptance plan (must be run on target Mac)

Record macOS version, CPU architecture, Docker Desktop version, sandbox CLI version, Claude Code version, and date. Use disposable credentials and dummy repositories for initial testing.

| ID | Test | Pass condition |
| --- | --- | --- |
| NET-01 | Inference via allowed endpoint | Review completes |
| NET-02 | HTTPS to unapproved domain | Denied at external boundary |
| NET-03 | Direct IPv4/IPv6, alternate ports | Denied |
| NET-04 | DNS, UDP, ICMP and local/LAN endpoints | No unauthorized reachability |
| NET-05 | Stop upstream proxy / break route | All outbound fails closed |
| NET-06 | Change guest proxy env, DNS, routing and firewall as guest root | Cannot expand egress |
| NET-07 | Sandbox kit rules / approval requests | No implicit extra grants; operator does not approve |
| FS-01 | Modify/delete snapshot in guest | Host original unchanged |
| FS-02 | Try host mounts, Docker socket, SSH agent, Keychain | Not accessible |
| AUTH-01 | Authenticate with Max subscription | Works without API key |
| AUTH-02 | Inspect guest files, processes and environment as root | No usable OAuth secrets exposed |
| AGENT-01 | Attempt Bash, Edit, Write, WebFetch, WebSearch, MCP | Unavailable/denied |
| AGENT-02 | Repository contains hostile CLAUDE.md / prompt injection | No privilege expansion |
| LIFE-01 | Destroy guest after session | Guest changes not retained |

Do not test with a real confidential repository until all required tests pass. Failure or inability to observe enforcement is a blocker, not a warning.

## Evidence
For each test record: command/procedure, timestamp, observed result, proxy/firewall logs, relevant version, and pass/fail. Never commit actual credentials or sensitive code to evidence.
