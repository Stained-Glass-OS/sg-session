#!/bin/sh
# Windows files opened from Linux programs (sg-open-windows-file): the
# desktop entry is valid and claims the types, mimeapps.list makes it the
# default, and the opener hands the file (a file:// URI too) to Wine's start.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
D="$HERE/config/applications/sg-windows-file.desktop"
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$D" && pass "the desktop entry is valid" || fail "desktop-file-validate"
fi
for m in application/x-ms-dos-executable application/vnd.microsoft.portable-executable application/x-msi; do
    grep -q "^MimeType=.*$m;" "$D" && grep -q "^$m=sg-windows-file.desktop" "$HERE/config/applications/sg-mimeapps.list" \
        && pass "$m: claimed, the default" || fail "$m not claimed"
done
mkdir -p "$T/bin" "$T/lib"
printf '#!/bin/sh\necho "$*" > %s/started\n' "$T" > "$T/bin/wine"; chmod +x "$T/bin/wine"
sed "s|/usr/lib/stained-glass/sg-common.sh|$T/lib/common.sh|" "$HERE/bin/sg-open-windows-file" > "$T/open"
printf 'sg_session_env() { echo /nonexistent; }\nsg_wine_env() { PATH=%s/bin:$PATH; }\n' "$T" > "$T/lib/common.sh"
sh "$T/open" '/tmp/My Setup.exe'
[ "$(cat "$T/started")" = "start /unix /tmp/My Setup.exe" ] && pass "a path goes to Wine's start" || fail "started: $(cat "$T/started")"
sh "$T/open" 'file:///tmp/My%20Setup.exe'
[ "$(cat "$T/started")" = "start /unix /tmp/My Setup.exe" ] && pass "...and a file:// URI" || fail "uri: $(cat "$T/started")"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
