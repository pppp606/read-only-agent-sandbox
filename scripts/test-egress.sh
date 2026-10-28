#!/bin/sh
# Run from the HOST. sbx exec commands are operator-controlled probes, never agent tools.
set -eu
: "${SANDBOX:?Set SANDBOX to an existing disposable sandbox name}"
probe() {
  label="$1"; expected="$2"; shift 2
  echo "Testing $label"
  if sbx exec "$SANDBOX" -- sh -c "$*"; then result=allow; else result=deny; fi
  if [ "$result" != "$expected" ]; then
    echo "FAIL $label: expected $expected, got $result" >&2
    exit 1
  fi
  echo "PASS $label"
}
# These checks intentionally do NOT depend on Claude Code permissions.
# Timeout avoids indefinite hangs when the external policy silently drops packets.
probe "public HTTPS blocked" deny 'curl --max-time 8 -fsS https://example.com/ >/dev/null'
probe "public IP direct blocked" deny 'curl --max-time 8 -fsSk https://1.1.1.1/ >/dev/null'
probe "public DNS-over-HTTPS blocked" deny 'curl --max-time 8 -fsS https://cloudflare-dns.com/dns-query >/dev/null'
echo "Negative probes passed. Run positive Anthropic/OAuth, proxy-down, IPv6, LAN and guest-root tests manually as documented."
