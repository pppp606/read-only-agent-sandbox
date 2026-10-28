# Threat model

## Assets
Host files, SSH keys, OAuth credentials, original Git repositories, local network services, and egress policy integrity.

## Adversary
The model may deliberately or accidentally try to discover network access, run commands, change configuration, follow prompt injection in repository files, or exploit guest/virtualization defects. Assume full guest compromise for boundary analysis.

## Trusted computing base
macOS host, virtualization monitor, external egress policy enforcement, credential broker, and snapshot preparation tool. The model, guest OS, agent plugins, repository files and its Git history are untrusted.

## Mandatory properties
1. Guest cannot modify original host repository; input is a disposable snapshot.
2. Guest has no host Docker socket, privileged host service, host SSH agent, or credential files.
3. Egress policy is enforced outside the guest; changing environment variables, guest routes, DNS, or guest firewall cannot loosen it.
4. Default deny for all outbound traffic except explicitly verified Claude subscription authentication and inference traffic.
5. No agent-facing arbitrary command execution or writable tool exposed; MCP, hooks, plugins, project instructions, and agent extension points must be audited or disabled.
6. Auth credentials must not be readable as plaintext inside guest, including after guest root compromise; if impossible, block launch.
7. A blocked connection is a policy decision, not a condition for the agent to repair.
8. Session is disposable; no persistence of untrusted modifications across reviews.

## Residual risks
Hypervisor escapes, host/proxy bugs, covert channels via allowed Anthropic traffic, sensitive source transmitted to Anthropic as part of normal inference, malicious prompt injection affecting review output, and incorrect snapshot filtering. The model's instructions are not a security boundary.

## Out of scope
Executing reviewed code, installing dependencies, dynamic vulnerability verification, automatically applying fixes, or automatically approving network requests.
