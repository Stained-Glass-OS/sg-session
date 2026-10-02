#!/bin/sh
# sg-common.sh's sg_dotnet_support: Wine Mono's .NET support files
# (fusion.dll...) are put into the system prefix when missing -- without them
# no .NET program found the Windows GAC (AmbirScan, SQL Server Compact,
# David 2026-10-02) -- with the 64-bit and the 32-bit rundll32, and nothing
# is run when they are there. A fake wine records its calls.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
mkdir -p "$T/bin" "$T/c/windows/syswow64" "$T/c/windows/Microsoft.NET/Framework/v4.0.30319"
: > "$T/support.inf"
cat > "$T/bin/wine" <<EOF2
#!/bin/sh
printf "%s\\n" "\$*" >> "$T/calls"
EOF2
chmod +x "$T/bin/wine"
run() { ( PATH="$T/bin:$PATH"; . "$1" >/dev/null 2>&1; sg_dotnet_support "$T/c" "$T/support.inf" ); }
run "$HERE/lib/sg-common.sh"
n=$(wc -l < "$T/calls" 2>/dev/null || echo 0)
grep -q '^rundll32 setupapi.dll,InstallHinfSection DefaultInstall 128 Z:.*support.inf$' "$T/calls" 2>/dev/null &&
grep -q '^C:\\windows\\syswow64\\rundll32.exe setupapi.dll,InstallHinfSection DefaultInstall 128 Z:' "$T/calls" 2>/dev/null &&
[ "$n" -eq 2 ] && echo "PASS  missing fusion.dll: the support inf is installed, 64-bit and 32-bit" \
    || { echo "FAIL  install calls: $(cat "$T/calls" 2>/dev/null | tr '\n' '|')"; RC=1; }
rm -f "$T/calls"
mkdir -p "$T/c/windows/Microsoft.NET/Framework64/v4.0.30319"
: > "$T/c/windows/Microsoft.NET/Framework/v4.0.30319/fusion.dll"; : > "$T/c/windows/Microsoft.NET/Framework64/v4.0.30319/fusion.dll"
run "$HERE/lib/sg-common.sh"
[ ! -s "$T/calls" ] && echo "PASS  and nothing when they are there" || { echo "FAIL  ran with fusion.dll present: $(cat "$T/calls")"; RC=1; }
# mutant: the function does nothing
rm -f "$T/calls" "$T/c/windows/Microsoft.NET/Framework/v4.0.30319/fusion.dll"
sed '/^sg_dotnet_support() {/,/^}/c\sg_dotnet_support() { :; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
run "$T/mut.sh"
[ ! -s "$T/calls" ] && echo "PASS  MUTANT NO_DOTNET_SUPPORT installs nothing (test catches it)" || { echo "FAIL  mutant"; RC=1; }
exit $RC
