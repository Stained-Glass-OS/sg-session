#!/bin/sh
# Unit test: an initialized prefix is brought up to date at boot only when
# Wine was updated (its .update-timestamp is not wine.inf's time) -- starting
# Wine and waiting for its server on every boot held the login screen back
# 25 s and more. Wine writes the stamp with CRLF. Stand-in wine records calls.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wine/bin" "$T/wine/share/wine" "$T/root/prefix" "$T/empty"
for b in wine wineserver; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$b" "$T" > "$T/wine/bin/$b"; chmod +x "$T/wine/bin/$b"
done
: > "$T/wine/share/wine/wine.inf"; touch -d @1790725500 "$T/wine/share/wine/wine.inf"
: > "$T/root/prefix/.sg-initialized"
run() {   # stamp content -> whether the update ran
    printf "$1" > "$T/root/prefix/.update-timestamp"; : > "$T/calls"
    SG_LIB="$HERE/lib" SG_WINE_DIR="$T/wine" SG_ROOT="$T/root" SG_PREFIX="$T/root/prefix" SG_STATE="$T/root/state" \
        SG_DEFAULTS_DIR="$T/empty" SG_BIN="$T/empty" PATH="$T/wine/bin:/usr/bin:/bin" \
        sh "$HERE/bin/sg-prefix-init" >/dev/null 2>&1
    grep -q '^wine cmd /c exit' "$T/calls" && echo updated || echo skipped
}
RC=0
[ "$(run '1790725500\r\n')" = skipped ] && echo "PASS  a current prefix (CRLF stamp) is not updated at boot" || { echo "FAIL  a current prefix was updated"; RC=1; }
[ "$(run '1690000000\r\n')" = updated ] && echo "PASS  after a Wine update the prefix is updated" || { echo "FAIL  a stale prefix was not updated"; RC=1; }
[ "$(run 'disable\r\n')" = skipped ] && echo "PASS  updates disabled in the prefix: none" || { echo "FAIL  'disable' was not honoured"; RC=1; }
exit $RC
