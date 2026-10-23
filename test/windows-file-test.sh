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
grep -qx "x-scheme-handler/mailto=sg-mail.desktop;thunderbird.desktop;" "$HERE/config/applications/sg-mimeapps.list" \
    && pass "mailto: links open SG Mail (else Thunderbird)" || fail "mailto: is not SG Mail's"
mkdir -p "$T/bin" "$T/lib"
printf '#!/bin/sh\necho "$*" > %s/started\n' "$T" > "$T/bin/wine"; chmod +x "$T/bin/wine"
sed "s|/usr/lib/stained-glass/sg-common.sh|$T/lib/common.sh|" "$HERE/bin/sg-open-windows-file" > "$T/open"
printf 'sg_session_env() { echo /nonexistent; }\nsg_wine_env() { PATH=%s/bin:$PATH; }\n' "$T" > "$T/lib/common.sh"
sh "$T/open" '/tmp/My Setup.exe'
[ "$(cat "$T/started")" = "start /unix /tmp/My Setup.exe" ] && pass "a path goes to Wine's start" || fail "started: $(cat "$T/started")"
sh "$T/open" 'file:///tmp/My%20Setup.exe'
[ "$(cat "$T/started")" = "start /unix /tmp/My Setup.exe" ] && pass "...and a file:// URI" || fail "uri: $(cat "$T/started")"
# a downloaded AppImage (Linux Firefox's "open"): the Install an AppImage
# window, with the file's Unix path -- not start, which would run an
# AppImage named without .AppImage
A="$HERE/config/applications/sg-appimage-install.desktop"
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$A" && pass "the AppImage entry is valid" || fail "desktop-file-validate (AppImage)"
fi
for m in application/vnd.appimage application/x-iso9660-appimage; do
    grep -q "^MimeType=.*$m;" "$A" && grep -q "^$m=sg-appimage-install.desktop" "$HERE/config/applications/sg-mimeapps.list" \
        && pass "$m: claimed, the default" || fail "$m not claimed"
done
grep -q '^Exec=sg-open-windows-file --appimage %f$' "$A" && grep -q 'sg-appimage-install.desktop' "$HERE/Makefile" \
    && pass "it opens the file with --appimage, and is installed" || fail "AppImage entry's Exec / install"
sh "$T/open" --appimage 'file:///tmp/My%20Tool-x86_64.AppImage'
[ "$(cat "$T/started")" = "/usr/libexec/stained-glass/shell/sg-store64.exe --appimage /tmp/My Tool-x86_64.AppImage" ] \
    && pass "an AppImage goes to the Install an AppImage window (sg-store64.exe --appimage), not to start" || fail "appimage: $(cat "$T/started")"
# mutant APPIMAGE_VIA_START: the AppImage handed to start like a Windows file
sed '/\[ "\$appimage" = 1 \] && exec/d' "$T/open" > "$T/open-mutant"
sh "$T/open-mutant" --appimage '/tmp/x.AppImage'
[ "$(cat "$T/started")" != "/usr/libexec/stained-glass/shell/sg-store64.exe --appimage /tmp/x.AppImage" ] \
    && pass "MUTANT APPIMAGE_VIA_START caught" || fail "MUTANT APPIMAGE_VIA_START not caught"
# a .zip from a Linux program (David 2026-10-23: Linux Firefox did not know
# how to open one): Compressed (zipped) Folders, through the .zip association
Zd="$HERE/config/applications/sg-zip.desktop"
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$Zd" && pass "the zip entry is valid" || fail "desktop-file-validate (zip)"
fi
for m in application/zip application/x-zip-compressed; do
    grep -q "^MimeType=.*$m;" "$Zd" && grep -q "^$m=sg-zip.desktop;" "$HERE/config/applications/sg-mimeapps.list" \
        && pass "$m: claimed, the default" || fail "$m not claimed"
done
grep -q '^Exec=sg-open-windows-file %f$' "$Zd" && grep -q 'config/applications/sg-zip.desktop' "$HERE/Makefile" \
    && pass "a zip opens through Wine's start (the .zip association), and the entry is installed" || fail "zip entry's Exec / install"
sh "$T/open" 'file:///tmp/My%20Image.zip'
[ "$(cat "$T/started")" = "start /unix /tmp/My Image.zip" ] && pass "a downloaded zip goes to Wine's start" || fail "zip: $(cat "$T/started")"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
