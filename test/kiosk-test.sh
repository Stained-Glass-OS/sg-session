#!/bin/sh
# sg-kiosk: the kiosk app (Settings > Accounts > Kiosk). Against stand-ins: a
# Linux app (a .desktop file whose Exec records each start and exits), the
# Windows launcher (records its arguments), a session (a sleep whose end is
# the sign-out) and wine's reg (a one-value registry in a file):
#   - the app is started, and started again after it closes, SG_KIOSK_DELAY
#     seconds later; never once the session has ended;
#   - only for the account the automatic sign-in names; field codes (%U)
#     are not passed; the Windows program gets its path, folder and
#     arguments as three arguments, spaces and quotes intact;
#   - an app that keeps closing at once is started at most once a minute;
#   - prepare: the taskbar hides itself for the kiosk account, and the
#     person's own setting (or none) comes back without a kiosk app.
# Mutant: SG_MUTANT_KIOSK_NO_RESTART=1 (the app is not started again).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KIOSK="$HERE/lib/sg-kiosk"
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }
T=$(mktemp -d)
SESSION=; RUNNER=
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    [ -n "$RUNNER" ] && kill "$RUNNER" 2>/dev/null
    [ -n "$SESSION" ] && kill "$SESSION" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
ME=$(id -un)

# the Linux app: records each start (time, arguments), runs a second, exits
cat > "$T/app.sh" <<EOF
#!/bin/sh
echo "\$(date +%s.%N) \$#:\$*" >> "$T/starts"
sleep "\${KIOSK_APP_RUN:-1}"
EOF
chmod +x "$T/app.sh"
printf '[Desktop Entry]\nType=Application\nName=Stand-in\nExec=%s --flag %%U\n[Desktop Action x]\nExec=false\n' "$T/app.sh" > "$T/app.desktop"
# the Windows launcher: records its arguments, one per line
cat > "$T/launcher" <<EOF
#!/bin/sh
{ echo "\$(date +%s.%N)"; for a in "\$@"; do echo "[\$a]"; done; } >> "$T/wstarts"
sleep 1
EOF
chmod +x "$T/launcher"

conf() { printf '%s\n' "$@" > "$T/autologon.conf"; }
starts() { [ -f "$T/$1" ] && grep -c "${2:-.}" "$T/$1" || echo 0; }
session() { sleep 300 & SESSION=$!; }
run_kiosk() {   # ENV... -> starts sg-kiosk run in the background (RUNNER)
    env SG_AUTOLOGON_CONF="$T/autologon.conf" SG_KIOSK_PARENT="$SESSION" SG_KIOSK_DELAY=1 SG_KIOSK_QUICK=0 \
        SG_KIOSK_LAUNCHER="$T/launcher" "$@" python3 "$KIOSK" run 2>>"$T/log" &
    RUNNER=$!
}
stop_all() {
    [ -n "$SESSION" ] && kill "$SESSION" 2>/dev/null; SESSION=
    i=0; while [ -n "$RUNNER" ] && kill -0 "$RUNNER" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
    [ -n "$RUNNER" ] && kill "$RUNNER" 2>/dev/null; RUNNER=
    rm -f "$T/starts" "$T/wstarts"
}

# --- a Linux app: started, and again after it closes
conf "user=$ME" "kiosk-name=Stand-in" "kiosk-desktop=$T/app.desktop"
session; run_kiosk
sleep 5.5
n=$(starts starts)
[ "$n" -ge 2 ] && [ "$n" -le 4 ] && pass "the kiosk app is started, and started again after it closes ($n starts in 5.5 s)" \
    || fail "starts in 5.5 s: $n ($(cat "$T/log"))"
gap=$(awk 'NR == 1 { a = $1 } NR == 2 { printf "%.1f", $1 - a }' "$T/starts" 2>/dev/null)
awk -v g="${gap:-0}" 'BEGIN { exit !(g >= 1.9) }' && pass "...after the delay, not at once (${gap}s between starts: 1 s running, 1 s delay)" \
    || fail "the second start came ${gap}s after the first"
head -1 "$T/starts" | grep -q ' 1:--flag$' && pass "...its Exec line's field codes (%U) are not passed" || fail "arguments: $(head -1 "$T/starts")"
kill "$SESSION"; SESSION=
sleep 2.5
n1=$(starts starts); sleep 2; n2=$(starts starts)
! kill -0 "$RUNNER" 2>/dev/null && [ "$n1" = "$n2" ] && pass "the session ends: sg-kiosk ends, nothing is started again" \
    || fail "after the session: running=$(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no), starts $n1 -> $n2"
stop_all

# --- MUTANT: not started again
session; run_kiosk SG_MUTANT_KIOSK_NO_RESTART=1
sleep 5.5
[ "$(starts starts)" -lt 2 ] && pass "MUTANT KIOSK_NO_RESTART (started once only) is caught" || fail "KIOSK_NO_RESTART not detected: $(starts starts)"
stop_all

# --- only for the account the automatic sign-in names
conf "user=someone-else" "kiosk-name=Stand-in" "kiosk-desktop=$T/app.desktop"
session; run_kiosk
sleep 2
[ "$(starts starts)" = 0 ] && ! kill -0 "$RUNNER" 2>/dev/null && pass "another account's kiosk app: nothing is started here" || fail "started for another account"
stop_all
conf "user=$ME"
session; run_kiosk
sleep 2
[ "$(starts starts)" = 0 ] && ! kill -0 "$RUNNER" 2>/dev/null && pass "automatic sign-in without a kiosk app: nothing is started" || fail "started without a kiosk app"
stop_all

# --- a Windows program: through the launcher, its path, folder and arguments intact
conf "user=$ME" "kiosk-name=Sonos" 'kiosk-app=C:\Program Files (x86)\Sonos\Sonos.exe' 'kiosk-args=--kiosk "two words"' \
    'kiosk-dir=C:\Program Files (x86)\Sonos'
session; run_kiosk
sleep 3.5
first=$(sed -n '2,4p' "$T/wstarts" 2>/dev/null | tr '\n' '|')
[ "$first" = '[C:\Program Files (x86)\Sonos\Sonos.exe]|[C:\Program Files (x86)\Sonos]|[--kiosk "two words"]|' ] \
    && pass "a Windows program: the launcher gets its path, folder and arguments, intact" || fail "launcher arguments: $first"
[ "$(starts wstarts '^[0-9]')" -ge 2 ] && pass "...and is started again after it closes" || fail "Windows program starts: $(starts wstarts '^[0-9]')"
stop_all

# --- an app that keeps closing at once: five quick tries, then once a minute
conf "user=$ME" "kiosk-name=Stand-in" "kiosk-desktop=$T/app.desktop"
session; run_kiosk SG_KIOSK_QUICK=100 SG_KIOSK_DELAY=0.1 KIOSK_APP_RUN=0
sleep 4
n=$(starts starts)
[ "$n" -ge 5 ] && [ "$n" -le 6 ] && pass "an app that keeps closing at once is not started in a tight loop ($n starts in 4 s)" \
    || fail "quick exits: $n starts in 4 s"
stop_all

# --- the kiosk app taken away while it runs: not started again
conf "user=$ME" "kiosk-name=Stand-in" "kiosk-desktop=$T/app.desktop"
session; run_kiosk
sleep 0.5
conf "user=$ME"
sleep 3
[ "$(starts starts)" = 1 ] && ! kill -0 "$RUNNER" 2>/dev/null && pass "the kiosk app removed (Settings): not started again" || fail "removed: $(starts starts) starts"
stop_all

# --- prepare: the taskbar
cat > "$T/wine" <<EOF
#!/bin/sh
# wine reg query|add|delete KEY /v NAME [/t T /d DATA] /f -- one value, in a file
[ "\$1" = reg ] || exit 1
echo "\$*" >> "$T/reg.calls"
case "\$2" in
    query) [ -f "$T/autohide" ] || exit 1; printf '\nHKEY_CURRENT_USER\\\\Software\\\\Stained Glass\\\\Taskbar\n    AutoHide    REG_DWORD    0x%x\n\n' "\$(cat "$T/autohide")" ;;
    add) echo "\$9" > "$T/autohide" ;;
    delete) rm -f "$T/autohide" ;;
esac
EOF
chmod +x "$T/wine"
prep() { SG_AUTOLOGON_CONF="$T/autologon.conf" SG_KIOSK_WINE="$T/wine" SG_KIOSK_STATE="$T/state" python3 "$KIOSK" prepare 2>>"$T/log"; }
echo 0 > "$T/autohide"
conf "user=$ME" "kiosk-name=Stand-in" "kiosk-desktop=$T/app.desktop"
out=$(prep)
[ "$out" = kiosk ] && [ "$(cat "$T/autohide")" = 1 ] && [ "$(cat "$T/state/kiosk-taskbar")" = 0 ] \
    && pass "prepare: the kiosk account's taskbar hides itself; the person's setting is kept aside" || fail "prepare on: $out $(cat "$T/autohide") $(cat "$T/state/kiosk-taskbar" 2>&1)"
prep >/dev/null
[ "$(cat "$T/state/kiosk-taskbar")" = 0 ] && pass "...a second sign-in keeps the person's setting, not the kiosk's" || fail "second prepare saved $(cat "$T/state/kiosk-taskbar")"
conf "user=$ME"
out=$(prep)
[ -z "$out" ] && [ "$(cat "$T/autohide")" = 0 ] && [ ! -e "$T/state/kiosk-taskbar" ] \
    && pass "...no kiosk app any more: the person's own taskbar comes back" || fail "prepare off: $out $(cat "$T/autohide" 2>&1)"
: > "$T/reg.calls"; prep >/dev/null
[ ! -s "$T/reg.calls" ] && pass "...and an account that never had one: no registry work at sign-in" || fail "reg calls: $(cat "$T/reg.calls")"
rm -f "$T/autohide"
conf "user=$ME" "kiosk-name=Stand-in" "kiosk-desktop=$T/app.desktop"; prep >/dev/null
conf "user=$ME"; prep >/dev/null
[ ! -e "$T/autohide" ] && pass "...a setting that was never made is removed again, not left on" || fail "none restored as $(cat "$T/autohide")"

# --- the session runs it: prepare before the shell, run once the shell is up
awk '/sg-kiosk" prepare/ { p = NR } /^sg_supervise_shell/ { s = NR } /sg-kiosk" run/ { r = NR } END { exit !(p && s && r && p < s) }' \
    "$HERE/lib/sg-run-explorer" && pass "sg-run-explorer: prepare before the shell starts, run alongside it" || fail "sg-run-explorer does not run sg-kiosk"

[ $RC = 0 ] && echo "kiosk-test: PASS" || { echo "kiosk-test: FAIL"; sed 's/^/   /' "$T/log" | tail -20; }
exit $RC
