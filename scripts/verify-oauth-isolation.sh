#!/bin/sh
# AUTH-02 / G1: as GUEST ROOT, look for usable Claude subscription credentials
# inside the sandbox after `/login` (or `claude auth login`) has completed.
#
# Docker Sandboxes documents that the subscription session token "stays on your
# host and is never stored inside the sandbox" (the guest holds a sentinel the
# host proxy swaps for the real token). This script checks that claim instead of
# trusting it. Exit 0 = no real-looking token found. Exit 1 = token material
# found; the launch requirement is NOT met.
#
#   SANDBOX=<name> sh scripts/verify-oauth-isolation.sh
set -u
: "${SANDBOX:?Set SANDBOX to the sandbox that completed login}"
# Claude subscription OAuth tokens are prefixed sk-ant-oat01- (access) and
# sk-ant-ort01- (refresh). API keys are sk-ant-api03-. Treat any as a failure.
PATTERN='sk-ant-(oat|ort|api)[0-9]{2}-[A-Za-z0-9_-]{20,}'
found=0

root() { sbx exec -u root "$SANDBOX" sh -c "$1"; }

echo "== AUTH-02 on sandbox $SANDBOX (running as guest root) =="
echo "-- credential files (values masked; only key names and value shapes shown)"
root 'for f in /home/*/.claude/.credentials.json /root/.claude/.credentials.json; do
  [ -f "$f" ] || continue
  echo "file: $f ($(stat -c %a "$f" 2>/dev/null))"
  if command -v node >/dev/null 2>&1; then
    node -e "
const o=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));
const walk=(v,p)=>{ if(v&&typeof v===\"object\"){ for(const k of Object.keys(v)) walk(v[k],p?p+\".\"+k:k); }
  else { const s=String(v); console.log(\"  \"+p+\": len=\"+s.length+\" prefix=\"+s.slice(0,13)); } };
walk(o,\"\");" "$f"
  else
    sed -E "s/(sk-ant-[a-z0-9]{5}-)[A-Za-z0-9_-]+/\1<masked>/g" "$f" | cut -c1-400
  fi
done; true'

echo "-- filesystem sweep for token material"
hits=$(root "grep -rIlE '$PATTERN' / --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev 2>/dev/null | head -20")
if [ -n "$hits" ]; then echo "FOUND token-shaped strings in:"; echo "$hits"; found=1; else echo "ok   no token-shaped strings on the guest filesystem"; fi

echo "-- process environments"
envhits=$(root "for p in /proc/[0-9]*; do tr '\0' '\n' < \$p/environ 2>/dev/null | grep -E '$PATTERN' >/dev/null && echo \"\$p \$(cat \$p/comm 2>/dev/null)\"; done; true")
if [ -n "$envhits" ]; then echo "FOUND token-shaped strings in process environments:"; echo "$envhits"; found=1; else echo "ok   no token-shaped strings in any process environment"; fi

echo "-- environment variables that would carry credentials"
root 'for p in /proc/[0-9]*; do tr "\0" "\n" < $p/environ 2>/dev/null | grep -E "^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=" | sed -E "s/=(.{0,8}).*/=\1<masked> (pid ${p#/proc/})/"; done | sort -u; true'

echo "-- host exposure checks (should all be absent)"
root 'ls -la /var/run/docker.sock /run/host-services 2>&1 | grep -v "No such" ; echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-<unset>}"; ls -la "${SSH_AUTH_SOCK:-/nonexistent}" 2>/dev/null; mount | grep -Ei "virtiofs|9p|fuse|nfs|cifs" || echo "no host filesystem passthrough mounts"; true'

if [ "$found" = 1 ]; then
  echo "AUTH-02 FAILED: credential material is readable by guest root. Requirement 6 of the threat model is not met; do not use real credentials." >&2
  exit 1
fi
echo "AUTH-02 passed for this sandbox: only sentinel/placeholder values are visible to guest root."
echo "Record the output above as G1 evidence. Note: a guest can still *use* the sentinel to reach api.anthropic.com through the proxy; that is the accepted residual covert channel."
