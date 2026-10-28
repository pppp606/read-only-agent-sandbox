#!/bin/sh
set -eu
echo "== Host preflight (read-only) =="
uname -a
for cmd in docker sbx python3 curl; do
  command -v "$cmd" >/dev/null || { echo "MISSING: $cmd" >&2; exit 1; }
done
docker info >/dev/null
sbx version
echo "== Effective sandbox settings =="
sbx settings get proxy.sandbox
sbx settings get no_proxy.sandbox
sbx settings get ssh.agentForwardingEnabled
sbx settings get browser.enabled
echo "== Network policy =="
sbx policy ls --wide
echo "== WARNING: This only inventories settings; it does NOT establish isolation =="
