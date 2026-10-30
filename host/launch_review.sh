#!/bin/bash
# Host-only launcher for a read-only review session in a Docker Sandboxes microVM.
# NEVER run this from inside a sandbox. Requires: sbx >= 0.50 (signed in), the
# compose egress proxy running, and a gate evidence file that passes check_gates.
#
#   host/launch_review.sh --repo /path/to/repo --evidence evidence/2026-10-29.json [--name NAME]
#        [--history-count N] [--prompt "text"] [--out review-output/]
#   host/launch_review.sh --repo /path/to/dummy-repo --unsafe-probe-mode   # for acceptance testing only
#
# Flow: gates -> preflight -> snapshot -> create mountless sandbox -> per-sandbox
# allow rules -> copy snapshot in -> egress probes -> login -> AUTH-02 -> tool
# self-check -> run claude -p with read-only tools -> collect output -> destroy.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=""; EVIDENCE=""; NAME="roas-$(date +%Y%m%d-%H%M%S)"; HISTORY=50; PROMPT=""; OUT="$HERE/review-output"
PROBE_MODE=0; KEEP=0
ALLOW_HOSTS="api.anthropic.com:443,claude.ai:443,platform.claude.com:443"
# The Docker claude kit provisions its own sandbox-scoped allow rules (observed on sbx 0.50.1:
# api.anthropic.com, bridge.claudeusercontent.com, claude.com, code.claude.com, downloads.claude.ai,
# mcp-proxy.anthropic.com, platform.claude.com). Deny beats allow, so we explicitly deny the extras.
DENY_HOSTS="mcp-proxy.anthropic.com:443,downloads.claude.ai:443,code.claude.com:443,bridge.claudeusercontent.com:443,claude.com:443"
GUEST_WS=/home/agent/workspace
GUEST_REVIEW="$GUEST_WS/review"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --history-count) HISTORY="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --unsafe-probe-mode) PROBE_MODE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "--repo is required" >&2; exit 2; }
# The grant watchdog (scripts/grant-watchdog.sh) recognises review sandboxes by this prefix.
case "$NAME" in roas-*) ;; *) echo "--name must start with roas- (watchdog prefix)" >&2; exit 2 ;; esac

log() { printf '[launch] %s\n' "$*"; }
die() { printf '[launch] ABORT: %s\n' "$*" >&2; exit 1; }

# ---- 0. refuse to run inside a sandbox -------------------------------------
[ -d /run/sandbox ] && die "this looks like a sandbox guest; run the launcher on the host only"
[ "$(uname -s)" = "Darwin" ] || log "warning: designed for macOS hosts"

# ---- 1. gates ---------------------------------------------------------------
if [ "$PROBE_MODE" = 1 ]; then
  cat >&2 <<'EOF'
!!! UNSAFE PROBE MODE: gate evidence is NOT checked. Use ONLY with a dummy repository
!!! and a throwaway Claude account/session. Output of this run is acceptance evidence, not a review.
EOF
  case "$(cd "$REPO" && pwd)" in
    "$HERE"|"$HERE"/*) die "never point the sandbox at this repository" ;;
  esac
else
  [ -n "$EVIDENCE" ] || die "--evidence is required (or --unsafe-probe-mode for acceptance testing)"
  python3 "$HERE/host/check_gates.py" "$EVIDENCE" || die "gates not passed"
fi

# ---- 2. preflight -----------------------------------------------------------
sh "$HERE/scripts/preflight.sh" || die "preflight failed"
# A stale OAuth grant from a previous session would be injected into this sandbox too.
sbx secret ls --format json 2>/dev/null | grep -q '"secrets": \[\]' || die "host-side sbx secrets exist; remove them first (sbx secret ls / sbx secret rm anthropic -f)"
sbx ls 2>/dev/null | grep -q "^$NAME\b" && die "sandbox $NAME already exists"

# ---- 3. snapshot (host side, outside both repositories) ---------------------
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/roas-snapshot-XXXXXX")
SNAP="$STAGE/snapshot"
trap 'rm -rf "$STAGE"' EXIT
python3 "$HERE/host/prepare_snapshot.py" "$REPO" "$SNAP" --history-count "$HISTORY"
cp "$HERE/prompts/reviewer.md" "$SNAP/REVIEW_INSTRUCTIONS.md"
# Belt and braces: the snapshot must contain no agent extension points.
if find "$SNAP" \( -name .mcp.json -o -name .claude -o -name settings.json -path '*/.claude/*' \) | grep -q .; then
  die "snapshot contains agent extension files"
fi

# ---- 4. mountless sandbox ---------------------------------------------------
log "creating mountless sandbox $NAME (no host workspace, no shared skills)"
sbx create claude --name "$NAME" --skills off --no-progress
cleanup() {
  rm -rf "$STAGE"
  if [ "$KEEP" = 1 ]; then log "keeping sandbox $NAME (--keep); remove with: sbx rm --force $NAME"; return; fi
  # Revoke the session's OAuth grant before the VM disappears (hygiene even with
  # Docker's host-side token handling; mandatory if the token turns out to be in-guest).
  sbx exec "$NAME" claude auth logout >/dev/null 2>&1 || log "warning: claude auth logout failed or not logged in"
  # Observed on sbx 0.50.1: /login inside the guest stores the real OAuth grant in Docker's
  # HOST store with GLOBAL scope, and the guest-side logout does not remove it. Every later
  # sandbox on this host would get it injected. Remove it here so the session is disposable.
  if sbx secret ls --format json 2>/dev/null | grep -q '"name": "anthropic"'; then
    sbx secret rm anthropic -f >/dev/null 2>&1 && log "removed host-side anthropic OAuth credential" || log "WARNING: could not remove host-side anthropic credential; run: sbx secret rm anthropic -f"
  fi
  log "destroying sandbox $NAME"
  sbx rm --force "$NAME" >/dev/null 2>&1 || true
  # Remove per-sandbox allow rules so they cannot be inherited by a future sandbox of the same name.
  for h in ${ALLOW_HOSTS//,/ } ${DENY_HOSTS//,/ }; do sbx policy rm network -f --sandbox "$NAME" --resource "$h" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# ---- 5. per-sandbox network allow rules on top of the global deny-all -------
sbx policy allow network --sandbox "$NAME" "$ALLOW_HOSTS"
sbx policy deny network --sandbox "$NAME" "$DENY_HOSTS"
policy_allows() { sbx policy check network --json --sandbox "$NAME" "$1" 2>/dev/null | grep -q '"allowed": true'; }
for t in example.com github.com 1.1.1.1 mcp-proxy.anthropic.com:443 downloads.claude.ai:443 claude.com:443; do
  policy_allows "$t" && die "policy for $NAME allows $t"
done
# Any kit-provisioned allow rule outside our list is a finding (NET-07).
sbx policy ls "$NAME" --wide --source kit 2>/dev/null | grep -oE '[a-z0-9.-]+\.[a-z]+:[0-9]+' | sort -u | while read -r r; do
  case ",$ALLOW_HOSTS,$DENY_HOSTS," in *",$r,"*) ;; *) die "kit provisioned an unexpected allow rule: $r" ;; esac
done
policy_allows api.anthropic.com:443 || die "policy does not allow api.anthropic.com for $NAME"

# ---- 6. copy snapshot in; nothing else crosses the boundary -----------------
sbx cp "$SNAP" "$NAME:$GUEST_REVIEW"
sbx exec -u root "$NAME" sh -c "chown -R agent:agent $GUEST_REVIEW 2>/dev/null || true; ls $GUEST_REVIEW"

# ---- 7. egress probes as guest root -----------------------------------------
SANDBOX="$NAME" sh "$HERE/scripts/test-egress.sh" || die "egress probes failed"

# ---- 8. login (interactive, paste-code flow) + AUTH-02 ----------------------
# browser.enabled is false, so the guest cannot open the host browser; the operator
# opens the printed URL manually and pastes the code back.
if ! sbx exec "$NAME" claude auth status >/dev/null 2>&1; then
  log "Claude Code is not logged in inside $NAME. Complete the paste-code login now."
  sbx exec -it "$NAME" claude auth login
fi
SANDBOX="$NAME" sh "$HERE/scripts/verify-oauth-isolation.sh" || die "AUTH-02 failed: credential material readable by guest root"

# ---- 9. agent tool self-check (G4) ------------------------------------------
# Flags verified on Claude Code 2.1.312: the system/init event reports exactly Glob, Grep, Read.
CLAUDE_FLAGS=(
  --restricted
  --tools "Read,Grep,Glob"
  --disallowedTools Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Agent "mcp__*"
  --strict-mcp-config
  --disable-slash-commands
  --setting-sources user
  --permission-mode dontAsk
  --permission-prompts none
  --append-system-prompt "$(cat "$HERE/prompts/reviewer.md")"
)
GUEST_ENV=(-e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 -e DISABLE_AUTOUPDATER=1 -e CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
           -e CLAUDE_CODE_DISABLE_WEB_FETCH=1 -e ENABLE_CLAUDEAI_MCP_SERVERS=false)
mkdir -p "$OUT/$NAME"
log "tool self-check"
sbx exec "${GUEST_ENV[@]}" -w "$GUEST_REVIEW" "$NAME" claude -p "${CLAUDE_FLAGS[@]}" --model haiku \
  --output-format stream-json --verbose \
  "Reply with ONLY a JSON array of the exact names of every tool available to you. Do not call any tool." \
  > "$OUT/$NAME/selfcheck.jsonl" 2> "$OUT/$NAME/selfcheck.err" < /dev/null || true
python3 - "$OUT/$NAME/selfcheck.jsonl" <<'EOF' || die "tool self-check failed (see review-output/<name>/selfcheck.*)"
import json, sys
allowed = {"Read", "Grep", "Glob"}
init = None
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "system" and d.get("subtype") == "init":
        init = d
if init is None:
    sys.exit("no system/init event; is the guest logged in?")
tools, mcp = set(init.get("tools", [])), init.get("mcp_servers", [])
print("guest tools:", sorted(tools), "mcp:", mcp, "mode:", init.get("permissionMode"))
if not tools or not tools <= allowed or mcp:
    sys.exit("unexpected tool set")
EOF

# ---- 10. the review ---------------------------------------------------------
[ -n "$PROMPT" ] || PROMPT="Review the source snapshot under $GUEST_REVIEW/source using REVIEW_INSTRUCTIONS.md and history.txt. Report findings with file/line evidence."
log "running review (output -> $OUT/$NAME/review.md)"
sbx exec "${GUEST_ENV[@]}" -w "$GUEST_REVIEW" "$NAME" claude -p "${CLAUDE_FLAGS[@]}" \
  --output-format stream-json --verbose "$PROMPT" \
  > "$OUT/$NAME/review.jsonl" 2> "$OUT/$NAME/review.err" < /dev/null || log "claude exited non-zero; see review.err"
python3 - "$OUT/$NAME/review.jsonl" > "$OUT/$NAME/review.md" <<'EOF'
import json, sys
denials = []
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "result":
        print(d.get("result", ""))
        denials = d.get("permission_denials", [])
if denials:
    print("\n\n---\nPermission denials observed (expected for a read-only agent):")
    for x in denials:
        print("-", json.dumps(x)[:300])
EOF

# ---- 11. host-side evidence -------------------------------------------------
sbx policy log "$NAME" > "$OUT/$NAME/policy-log.txt" 2>&1 || true
log "done. Review: $OUT/$NAME/review.md  Policy log: $OUT/$NAME/policy-log.txt"
log "Treat review.md as untrusted model output derived from untrusted input."
