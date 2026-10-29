#!/bin/sh
# Host preflight: inventories the Docker Sandboxes (sbx) installation and reports
# whether the host-wide settings match the read-only review posture.
# It changes nothing. Exit 1 means "do not launch".
set -u
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL: $*"; fail=1; }

say "== Host preflight (read-only) =="
sw_vers 2>/dev/null || uname -a
for cmd in sbx python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || bad "missing command: $cmd"
done
[ "$fail" = 1 ] && exit 1

say "== Versions =="
sbx version
command -v claude >/dev/null 2>&1 && claude --version || say "note: host claude not found (only needed for comparison)"
command -v docker >/dev/null 2>&1 && docker --version || say "note: docker not found (needed only for the compose egress proxy)"

say "== Daemon =="
sbx daemon status || bad "sbx daemon not healthy"

say "== Settings that must hold during a review =="
check_setting() {
  key="$1"; want="$2"
  got=$(sbx settings get "$key" 2>/dev/null | tr -d '[:space:]')
  if [ "$got" = "$want" ]; then say "ok   $key=$got"; else bad "$key=$got (want $want)"; fi
}
check_setting ssh.agentForwardingEnabled false
check_setting browser.enabled false
check_setting claude.remoteControl false
check_setting skills.defaultMode off
proxy=$(sbx settings get proxy.sandbox 2>/dev/null | tr -d '[:space:]')
case "$proxy" in
  http://127.0.0.1:*) say "ok   proxy.sandbox=$proxy" ;;
  *) bad "proxy.sandbox=$proxy (want http://127.0.0.1:<port> pointing at the host-only egress proxy)" ;;
esac
noproxy=$(sbx settings get no_proxy.sandbox 2>/dev/null | tr -d '[:space:]')
[ -z "$noproxy" ] || [ "$noproxy" = "-" ] || bad "no_proxy.sandbox is set ($noproxy); it must be empty"

say "== Upstream proxy reachability (expects 403 for a non-allowlisted host) =="
if [ -n "$proxy" ] && [ "$proxy" != "-" ]; then
  code=$(curl -sS -o /dev/null -m 8 -w '%{http_code}' -x "$proxy" https://example.com/ 2>/dev/null || true)
  if [ "$code" = "403" ]; then say "ok   proxy denies example.com (403)"; else bad "proxy returned '$code' for example.com (want 403; is 'docker compose up' running?)"; fi
fi

say "== Network policy =="
if ! sbx policy ls --wide 2>/dev/null; then
  bad "global network policy not initialized (run: sbx policy init deny-all)"
fi
for target in example.com 1.1.1.1 registry.npmjs.org github.com; do
  if sbx policy check network "$target" 2>/dev/null | grep -qi allow; then bad "policy allows $target"; else say "ok   policy denies $target"; fi
done
say "note: api.anthropic.com / claude.ai / platform.claude.com are allowed per sandbox by host/launch_review.sh, not globally."

say "== Secrets stored for sandboxes (should be empty for this workflow) =="
sbx secret ls 2>/dev/null || true

say "== Diagnose =="
sbx diagnose 2>/dev/null | grep -E '✗|Authentication|network policy' || true

if [ "$fail" = 1 ]; then
  say "== PREFLIGHT FAILED: fix the items above before launching =="
  exit 1
fi
say "== Preflight OK. This inventories settings only; it does NOT prove isolation. Run scripts/test-egress.sh against a disposable sandbox. =="
