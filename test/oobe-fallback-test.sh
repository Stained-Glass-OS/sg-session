#!/bin/sh
# The first-run setup must never keep a machine from its login screen
# (lib/sg-login-ui). With stand-ins for the compositor, the bridge and the
# greeter bridge -- no Wine, no display:
#   - a first-run setup that comes up is waited for, and its run ends the greeter
#   - one whose window never appears is stopped after SG_OOBE_TIMEOUT, and the
#     next start of the greeter shows the login screen
#   - one that keeps ending without finishing is tried three times, then the
#     login screen
#   - without its service's socket it is not shown at all
# shellcheck disable=SC2015  # pass never fails
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
command -v systemd-cat >/dev/null || { echo "SKIP: no systemd-cat"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-oobe-fallback.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/libexec" "$T/tmp"
# The compositor: runs its client (after --), and records that it ran.
cat > "$T/compositor" <<'EOS'
#!/bin/sh
while [ "$1" != -- ]; do shift; done; shift
echo "compositor $1" >> "$T/log"
exec "$@"
EOS
# The bridge: --oobe means the first-run setup; its behaviour is $MODE.
cat > "$T/libexec/sg-setup-bridge" <<'EOS'
#!/bin/sh
echo "oobe started" >> "$T/log"
case "$MODE" in
ready) : > "$SG_OOBE_READY"; sleep 1 ;;
hang) sleep 60 ;;
crash) exit 1 ;;
esac
EOS
cat > "$T/libexec/sg-greet-bridge" <<'EOS'
#!/bin/sh
echo "greeter" >> "$T/log"
EOS
: > "$T/libexec/sg-oobe64.exe"
chmod +x "$T/compositor" "$T/libexec/sg-setup-bridge" "$T/libexec/sg-greet-bridge"
: > "$T/pending"
python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/oobed.sock"
run() {
    env T="$T" MODE="$1" TMPDIR="$T/tmp" SG_LIB="$HERE/lib" SG_LIBEXEC="$T/libexec" SG_COMPOSITOR="$T/compositor" \
        SG_OOBE_PENDING="$T/pending" SG_OOBED_SOCK="$T/oobed.sock" SG_OOBE_TIMEOUT=3 SG_WINE_DIR=/nonexistent \
        timeout 30 sh "$HERE/lib/sg-login-ui" >/dev/null 2>&1
}
count() { grep -c "^$1" "$T/log" 2>/dev/null || true; }

: > "$T/log"; run ready
[ "$(count 'oobe started')" = 1 ] && [ "$(count greeter)" = 0 ] && pass "a first-run setup that comes up runs, and ends this greeter" \
    || fail "ready: $(cat "$T/log")"

rm -f "$T/tmp"/*; : > "$T/log"
start=$(date +%s); run hang; took=$(( $(date +%s) - start ))
run hang
[ "$(count 'oobe started')" = 1 ] && [ "$(count greeter)" = 1 ] && [ "$took" -lt 20 ] \
    && pass "one whose window never appears is stopped (${took}s), and the next start shows the login screen" \
    || fail "hang: took ${took}s: $(cat "$T/log")"

rm -f "$T/tmp"/*; : > "$T/log"
for _ in 1 2 3 4; do run crash; done
[ "$(count 'oobe started')" = 3 ] && [ "$(count greeter)" = 1 ] \
    && pass "one that keeps ending unfinished is tried three times, then the login screen" \
    || fail "crash loop: $(cat "$T/log")"

rm -f "$T/tmp"/* "$T/oobed.sock"; : > "$T/log"; run ready
[ "$(count 'oobe started')" = 0 ] && [ "$(count greeter)" = 1 ] && pass "without its service's socket, the login screen" \
    || fail "no socket: $(cat "$T/log")"

echo
[ "$RC" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
