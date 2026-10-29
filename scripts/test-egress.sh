#!/bin/sh
# Negative/positive egress probes executed FROM THE HOST against a sandbox via
# operator-controlled `sbx exec`. Probes run as guest root on purpose: the
# boundary must hold even when the guest is fully compromised.
#
#   SANDBOX=<name> sh scripts/test-egress.sh            # standard probes
#   SANDBOX=<name> sh scripts/test-egress.sh --proxy-down   # run after stopping the compose proxy
#   SANDBOX=<name> sh scripts/test-egress.sh --tamper   # guest-root tampering; use a DISPOSABLE sandbox
#
# Exit 0 only if every probe matched its expectation.
set -u
: "${SANDBOX:?Set SANDBOX to an existing sandbox name}"
MODE="${1:-standard}"
failures=0

run_in() { sbx exec -u root "$SANDBOX" sh -c "$1"; }

# probe LABEL EXPECT(allow|deny) SHELL_COMMAND
# Docker's forward proxy answers a blocked CONNECT with 200 and then serves its own
# plaintext 403 ("Approval required for host:port"). curl exits 0 on that, so a probe
# counts as "allow" only if the command succeeds AND the output is not that block page.
probe() {
  label="$1"; expected="$2"; cmd="$3"
  out=$(run_in "$cmd 2>/dev/null; echo \"__rc=\$?\"" 2>/dev/null)
  rc=$(printf '%s' "$out" | sed -n 's/.*__rc=\([0-9]*\).*/\1/p' | tail -1)
  case "$out" in
    *"Approval required for"*|*"blocked by proxy policy"*|*"No matching allow rule"*) result=deny ;;
    *) if [ "${rc:-1}" = 0 ]; then result=allow; else result=deny; fi ;;
  esac
  if [ "$result" = "$expected" ]; then
    echo "PASS $label ($result)"
  else
    echo "FAIL $label: expected $expected, got $result" >&2
    failures=$((failures + 1))
  fi
}

# curl exits non-zero on connection failure/timeout; -f additionally fails on HTTP>=400.
# For "deny" probes we do NOT use -f: a 403 from a proxy is still a reachable endpoint
# from the point of view of data exfiltration, so any HTTP response counts as allow.
C='curl --max-time 8 -sS -o -'

echo "== Sandbox: $SANDBOX  mode: $MODE =="
run_in 'id; cat /etc/os-release 2>/dev/null | head -2; ip -4 route 2>/dev/null; ip -6 route 2>/dev/null | head -3; env | grep -i proxy || echo "(no proxy env)"' || { echo "cannot exec in sandbox" >&2; exit 2; }

if [ "$MODE" = "--proxy-down" ]; then
  echo "== NET-05: compose egress proxy must be stopped before this run =="
  probe "api.anthropic.com unreachable when upstream proxy is down" deny "$C https://api.anthropic.com/"
  probe "claude.ai unreachable when upstream proxy is down" deny "$C https://claude.ai/"
  probe "example.com still blocked" deny "$C https://example.com/"
  [ "$failures" = 0 ] && echo "Proxy-down probes passed (fail-closed)." && exit 0
  exit 1
fi

echo "== NET-02: unapproved destinations =="
probe "public HTTPS blocked" deny "$C https://example.com/"
probe "public HTTP (port 80) blocked" deny "$C http://example.com/"
probe "github.com blocked" deny "$C https://github.com/"
probe "npm registry blocked" deny "$C https://registry.npmjs.org/"
probe "DNS-over-HTTPS blocked" deny "$C https://cloudflare-dns.com/dns-query?name=example.com"

echo "== NET-03: direct IP, IPv6, alternate ports =="
probe "direct IPv4 literal blocked" deny "$C -k https://1.1.1.1/"
probe "direct IPv6 literal blocked" deny "$C -k -6 'https://[2606:4700:4700::1111]/'"
probe "alternate port 8443 blocked" deny "$C -k https://example.com:8443/"
probe "SSH port blocked" deny "$C telnet://github.com:22"

echo "== NET-04: UDP, local, LAN =="
# UDP DNS to a public resolver, using node (present in the Claude template) with a python3 fallback.
UDP_PROBE='
if command -v node >/dev/null 2>&1; then
node -e "
const d=require(\"dgram\").createSocket(\"udp4\");
const q=Buffer.from(\"abcd01000001000000000000076578616d706c6503636f6d0000010001\",\"hex\");
const t=setTimeout(()=>{d.close();process.exit(1)},4000);
d.on(\"message\",()=>{clearTimeout(t);d.close();process.exit(0)});
d.send(q,53,\"8.8.8.8\");"
elif command -v python3 >/dev/null 2>&1; then
python3 -c "
import socket,sys;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(4)
s.sendto(bytes.fromhex(\"abcd01000001000000000000076578616d706c6503636f6d0000010001\"),(\"8.8.8.8\",53))
try: s.recv(512); sys.exit(0)
except Exception: sys.exit(1)"
else exit 1; fi'
probe "UDP DNS to 8.8.8.8:53 blocked" deny "$UDP_PROBE"
probe "ICMP ping blocked" deny "ping -c1 -W3 1.1.1.1"
GW=$(run_in "ip -4 route 2>/dev/null | awk '/default/{print \$3; exit}'" 2>/dev/null | tr -d '[:space:]')
if [ -n "$GW" ]; then
  echo "guest default gateway: $GW"
  probe "gateway HTTP blocked" deny "$C http://$GW/"
  probe "gateway :3128 (compose proxy) not directly reachable" deny "$C http://$GW:3128/"
  probe "gateway :22 blocked" deny "$C telnet://$GW:22"
fi
probe "host.docker.internal blocked" deny "$C http://host.docker.internal/"
probe "RFC1918 LAN blocked" deny "$C http://192.168.0.1/"
probe "link-local metadata blocked" deny "$C http://169.254.169.254/"

echo "== NET-06 (passive): environment manipulation does not widen egress =="
probe "no_proxy=* bypass blocked" deny "env no_proxy='*' NO_PROXY='*' $C https://example.com/"
probe "unset proxy env bypass blocked" deny "env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY $C https://example.com/"
probe "curl --noproxy bypass blocked" deny "$C --noproxy '*' https://example.com/"

if [ "$MODE" = "--tamper" ]; then
  echo "== NET-06 (active): guest-root tampering on a DISPOSABLE sandbox =="
  run_in 'echo "nameserver 8.8.8.8" > /etc/resolv.conf; (command -v iptables && iptables -F && iptables -P OUTPUT ACCEPT) 2>/dev/null; (command -v nft && nft flush ruleset) 2>/dev/null; sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null; true'
  probe "after resolv.conf/firewall tampering: example.com still blocked" deny "$C https://example.com/"
  probe "after tampering: direct IP still blocked" deny "$C -k https://1.1.1.1/"
  probe "after tampering: UDP DNS still blocked" deny "$UDP_PROBE"
fi

echo "== NET-01 (positive): approved destinations reachable through the host proxy chain =="
# Any HTTP status counts as reachable; without -f, curl only fails on transport errors.
probe "api.anthropic.com reachable" allow "$C https://api.anthropic.com/"
probe "platform.claude.com reachable" allow "$C https://platform.claude.com/"

if [ "$failures" = 0 ]; then
  echo "All egress probes matched expectations."
  echo "Still manual: NET-05 (--proxy-down), NET-07 (no approval prompts answered), AUTH-02 (scripts/verify-oauth-isolation.sh)."
  exit 0
fi
echo "$failures probe(s) FAILED. Do not start a review." >&2
exit 1
