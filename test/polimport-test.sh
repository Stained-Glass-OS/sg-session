#!/bin/sh
# Unit test: sg-polimport converts the registry.pol fixture to the expected .reg.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN="${SG_POLIMPORT:-$HERE/build/sg-polimport}"
[ -x "$BIN" ] || { echo "SKIP: sg-polimport not built"; exit 0; }
out=$("$BIN" "$HERE/test/fixtures/machine.pol")
ok=1
echo "$out" | grep -q 'Windows Registry Editor Version 5.00' || ok=0
echo "$out" | grep -qi 'HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer' || ok=0
echo "$out" | grep -qi '"NoClose"=hex(4):01,00,00,00' || ok=0
if [ "$ok" = 1 ]; then echo "PASS  sg-polimport converts registry.pol correctly"; exit 0
else echo "FAIL  sg-polimport output unexpected:"; echo "$out" | sed 's/^/      /'; exit 1; fi
