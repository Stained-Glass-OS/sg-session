#!/bin/sh
# The display scale on high-resolution screens (lib/sg-common.sh; David
# 2026-10-05, a Surface Pro 7 at 2736x1824: "everything is tiny"; "the
# taskbar will take up the same % of screen as on a 1080p screen does").
#   - sg_scale_for: the shorter side over 1080 in Windows' 25% steps, never
#     below 100% -- the table sg-shell's test/hidpi-check.sh checks for
#     Settings' own copy of the rule
#   - sg_auto_scale, against a stand-in wine keeping the registry: a fresh
#     account at 2736x1824 gets 175%; at 1080p nothing is written; a pick
#     (ScaleChosen) sticks; one from before (LogPixels not 96 nor what the
#     automatic scale wrote) is adopted as the user's; the automatic one
#     follows the screen
#   - sg_taskbar_h: explorer's bar (wine-sg 0832), 40 px at 100%, 70 at 175%
#   - sg_linux_scale_env: the XSETTINGS GTK, Qt and the pointer follow
#     (xsettingsd's file: Xft/DPI, Gdk/WindowScalingFactor, Gdk/UnscaledDPI,
#     Gtk/CursorThemeSize) and Xft.dpi/Xcursor.size at 175%, 150%, 125%;
#     96 DPI and scale 1 at 100% (a 1080p session as before); none of the
#     fixed variables (GDK_SCALE, QT_SCALE_FACTOR ...) that stop GTK and Qt
#     following a change, and Qt told to take the exact scale
#   - sg_linux_scale: a new scale while the session runs -- the manager
#     started once, then told (SIGHUP) with the new values
#   - sg_ui_scale: the login screen's scale in its environment
#     (SG_LOGPIXELS), the size from the kernel, no Wine or X run before it;
#     nothing at 1080p
# Mutants (sed on a copy of the library): NO_STICK (the pick ignored),
# LINUX_NO_SCALE (Linux programs left at 100%), UI_REGISTRY (the scale
# written with wine reg first, as 0.1.0-120 did), UI_XSIZE (the size from
# the X server, starting Xwayland), RECOMMEND_100, LIVE_NO_HUP (a change not
# told to the running manager), QT_TWICE (QT_SCALE_FACTOR set as well: Qt
# scaled twice).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-display-scale.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
# the stand-in: reg query/add/delete of REG_DWORDs, kept in $T/reg (KEY|NAME|VALUE)
cat > "$T/bin/wine" <<'EOS'
#!/bin/sh
[ "$1" = reg ] || exit 1
op=$2 key=$3 name=$5
store="$SG_T/reg"; touch "$store"
case "$op" in
query) # one value (/v NAME), or all of the key's
       out=$(K="$key" N="$name" awk -F'|' '$1 == ENVIRON["K"] && (ENVIRON["N"] == "" || $2 == ENVIRON["N"]) {
                 printf "    %s    REG_DWORD    0x%x\r\n", $2, $3 }' "$store")
       [ -n "$out" ] || exit 1
       printf '\r\n%s\r\n%s\r\n' "$key" "$out" ;;
add)   d=$9
       grep -v -F "$key|$name|" "$store" > "$store.n"; echo "$key|$name|$d" >> "$store.n"; mv "$store.n" "$store"
       echo "wine reg add $name $d" >> "$SG_T/calls" ;;
delete) grep -v -F "$key|" "$store" > "$store.n"; mv "$store.n" "$store" ;;
esac
exit 0
EOS
# a stand-in XSETTINGS manager: says when it starts and when it is told
cat > "$T/bin/xsettingsd" <<'EOS'
#!/bin/sh
echo "start $2" >> "$SG_T/xsd"
trap 'echo hup >> "$SG_T/xsd"' HUP
i=0; while [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
EOS
chmod +x "$T/bin/xsettingsd"
for c in systemctl dbus-update-activation-environment xrdb; do
    printf '#!/bin/sh\ncase " $* " in *" -merge "*) cat >> "%s/xrdb" ;; *" -query "*) cat "%s/xrdb" 2>/dev/null ;; esac\nexit 0\n' "$T" "$T" > "$T/bin/$c"
    chmod +x "$T/bin/$c"
done
chmod +x "$T/bin/wine"
export SG_T="$T"

LIB="$HERE/lib/sg-common.sh"
run() {   # LIB CODE: the code run with the library loaded, in a clean environment
    env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" SG_T="$T" sh -c ". \"\$1\" >/dev/null 2>&1; $2" sh "$1" 2>/dev/null
}
lp() { awk -F'|' '$2 == "LogPixels" { print $3 }' "$T/reg" 2>/dev/null; }
chosen() { awk -F'|' '$2 == "ScaleChosen" { print $3 }' "$T/reg" 2>/dev/null; }
fresh() {
    _fp=$(cat "$T/sg-xsettings_sg_test.pid" 2>/dev/null)
    [ -n "$_fp" ] && kill "$_fp" 2>/dev/null && sleep 0.3
    rm -f "$T/reg" "$T/calls" "$T/xrdb" "$T/xsd" "$T"/sg-xsettings_sg_test.*
}
setlp() { echo "HKCU\\Control Panel\\Desktop|LogPixels|$1" >> "$T/reg"; }

table() {   # LIB: "" when the table holds, else what differs
    _bad=""
    for row in 1366x768:100 1920x1080:100 1920x1200:100 2560x1440:125 2560x1600:150 2736x1824:175 \
               3200x1800:175 3840x2160:200 1824x2736:175 1080x1920:100 7680x4320:400 800x600:100; do
        w=${row%%x*} h=${row#*x}; h=${h%:*}
        got=$(run "$1" "sg_scale_for $w $h")
        [ "$got" = "${row#*:}" ] || _bad="$_bad ${row%:*}=$got(want ${row#*:})"
    done
    echo "$_bad"
}
bad=$(table "$LIB")
[ -z "$bad" ] && pass "the recommended scale: 768/1080/1200 lines 100%, 1440 125%, 1600 150%, 1800/1824 175%, 2160 200%, portrait by its shorter side, at most 400%" \
    || fail "recommendations:$bad"

stick() {   # LIB: "" when the automatic scale and the user's pick behave, else what went wrong
    _w=""
    fresh; s=$(run "$1" "sg_auto_scale 2736 1824")
    [ "$(lp)" = 168 ] && [ "$s" = 175 ] || _w="$_w fresh-1824:lp=$(lp),says=$s"
    fresh; s=$(run "$1" "sg_auto_scale 1920 1080")
    [ -z "$(lp)" ] && [ ! -s "$T/calls" ] && [ "$s" = 100 ] || _w="$_w fresh-1080:lp=$(lp),says=$s"
    # the automatic scale follows the screen
    fresh; run "$1" "sg_auto_scale 2736 1824" >/dev/null; run "$1" "sg_auto_scale 1920 1080" >/dev/null
    [ "$(lp)" = 96 ] || _w="$_w follow-1080:lp=$(lp)"
    run "$1" "sg_auto_scale 3840 2160" >/dev/null
    [ "$(lp)" = 192 ] || _w="$_w follow-2160:lp=$(lp)"
    # the user's pick (Settings: ScaleChosen 1) stays
    fresh; setlp 144; echo "HKCU\\Software\\Stained Glass\\Display|ScaleChosen|1" >> "$T/reg"
    s=$(run "$1" "sg_auto_scale 2736 1824")
    [ "$(lp)" = 144 ] && [ "$s" = 150 ] || _w="$_w pick:lp=$(lp),says=$s"
    # one from before the automatic scale existed is the user's
    fresh; setlp 120
    run "$1" "sg_auto_scale 2736 1824" >/dev/null
    [ "$(lp)" = 120 ] && [ "$(chosen)" = 1 ] || _w="$_w earlier:lp=$(lp),chosen=$(chosen)"
    echo "$_w"
}
w=$(stick "$LIB")
[ -z "$w" ] && pass "sg_auto_scale: 175% for a new account at 2736x1824, nothing written at 1080p, it follows the screen; a pick, and one from before, stay" \
    || fail "sg_auto_scale:$w"

[ "$(run "$LIB" "sg_taskbar_h 100")" = 40 ] && [ "$(run "$LIB" "sg_taskbar_h 175")" = 70 ] && [ "$(run "$LIB" "sg_taskbar_h 200")" = 80 ] \
    && pass "the taskbar's height for the work area: 40 px at 100%, 70 at 175%, 80 at 200%" \
    || fail "sg_taskbar_h: $(run "$LIB" "sg_taskbar_h 100") $(run "$LIB" "sg_taskbar_h 175") $(run "$LIB" "sg_taskbar_h 200")"

linux() {   # LIB PERCENT: the environment, the XSETTINGS and the resources set
    fresh
    # (under set -eu, as sg-run-explorer runs it: a failing step there ended the session)
    run "$1" "set -eu; export DISPLAY=:sg-test XDG_RUNTIME_DIR=$T GDK_SCALE=2 QT_SCALE_FACTOR=2 XCURSOR_SIZE=48; sg_linux_scale_env $2; env" |
        grep -E '^(GDK_SCALE|GDK_DPI_SCALE|QT_SCALE_FACTOR|QT_AUTO_SCREEN_SCALE_FACTOR|XCURSOR_SIZE|QT_ENABLE_HIGHDPI_SCALING|QT_SCALE_FACTOR_ROUNDING_POLICY)=' | sort | tr '\n' ' '
    tr '\n' ' ' 2>/dev/null < "$T/sg-xsettings_sg_test.conf"
    tr '\n' ' ' 2>/dev/null < "$T/xrdb"
    kill "$(cat "$T/sg-xsettings_sg_test.pid" 2>/dev/null)" 2>/dev/null
}
QT="QT_ENABLE_HIGHDPI_SCALING=1 QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough"
l=$(linux "$LIB" 175)
[ "$l" = "$QT Xft/DPI 172032 Gdk/WindowScalingFactor 2 Gdk/UnscaledDPI 86016 Gtk/CursorThemeSize 42 Xft.dpi: 168 Xcursor.size: 42 " ] \
    && pass "Linux programs at 175%: $l" || fail "Linux programs at 175%: '$l'"
l=$(linux "$LIB" 150)
[ "$l" = "$QT Xft/DPI 147456 Gdk/WindowScalingFactor 2 Gdk/UnscaledDPI 73728 Gtk/CursorThemeSize 36 Xft.dpi: 144 Xcursor.size: 36 " ] \
    && pass "Linux programs at 150%: $l" || fail "Linux programs at 150%: '$l'"
l=$(linux "$LIB" 125)
[ "$l" = "$QT Xft/DPI 122880 Gdk/WindowScalingFactor 1 Gdk/UnscaledDPI 122880 Gtk/CursorThemeSize 30 Xft.dpi: 120 Xcursor.size: 30 " ] \
    && pass "Linux programs at 125%: $l" || fail "Linux programs at 125%: '$l'"
l=$(linux "$LIB" 100)
[ "$l" = "$QT Xft/DPI 98304 Gdk/WindowScalingFactor 1 Gdk/UnscaledDPI 98304 Gtk/CursorThemeSize 24 Xft.dpi: 96 Xcursor.size: 24 " ] \
    && pass "at 100%: 96 DPI, scale 1 (a 1080p session's Linux programs as before): $l" || fail "at 100%: '$l'"

live() {   # LIB: the manager's life over 100% -> 175% -> 125%: "start CONF hup hup" and the file's last values
    fresh; rm -f "$T/xsd"
    run "$1" "set -eu; export DISPLAY=:sg-test XDG_RUNTIME_DIR=$T; sg_linux_scale_env 100; sleep 0.3; sg_linux_scale 175; sleep 0.3; sg_linux_scale 125; sleep 0.3"
    sed "s|$T/||" "$T/xsd" 2>/dev/null | tr '\n' ' '
    grep -E '^(Xft/DPI|Gdk/WindowScalingFactor)' "$T/sg-xsettings_sg_test.conf" 2>/dev/null | tr '\n' ' '
    kill "$(cat "$T/sg-xsettings_sg_test.pid" 2>/dev/null)" 2>/dev/null
}
l=$(live "$LIB")
[ "$l" = "start sg-xsettings_sg_test.conf hup hup Xft/DPI 122880 Gdk/WindowScalingFactor 1 " ] \
    && pass "a new scale while the session runs: the XSETTINGS manager started once, then told: $l" \
    || fail "a new scale while the session runs: '$l'"

# sg_ui_scale (the login screen, Setup, the first-run setup): the scale in
# the program's environment, the screen's size from the kernel (a stand-in
# /sys/class/drm: a disconnected 4K output and the connected one), and no
# Wine or X program run before it -- wine reg as the greeter's account, and
# xwininfo starting the on-demand Xwayland, each left the greeter without
# its window (release s9's boot test, 2026-10-05). With "x" (the lock
# screen's own Xwayland) and no DRM output, the X server's size.
ui() {   # LIB WxH [x]: SG_LOGPIXELS as left, then the Wine and X calls made
    fresh
    rm -rf "$T/drm"; mkdir -p "$T/drm/card0-DP-1" "$T/drm/card0-eDP-1"
    echo disconnected > "$T/drm/card0-DP-1/status"; printf '3840x2160\n' > "$T/drm/card0-DP-1/modes"
    if [ "$2" != none ]; then echo connected > "$T/drm/card0-eDP-1/status"; printf '%s\n1024x768\n' "$2" > "$T/drm/card0-eDP-1/modes"; fi
    printf '#!/bin/sh\necho xwininfo >> "%s/calls"\nprintf "  Width: 2736\\n  Height: 1824\\n"\n' "$T" > "$T/bin/xwininfo"
    chmod +x "$T/bin/xwininfo"
    run "$1" "SG_DRM_SYSFS=$T/drm; sg_ui_scale ${3:-}; echo \"\${SG_LOGPIXELS:-none}\""
    [ -s "$T/calls" ] && sed 's/ .*//' "$T/calls" | sort -u
    rm -f "$T/bin/xwininfo"
}
u=$(ui "$LIB" 2736x1824 | tr '\n' ' ')
[ "$u" = "168 " ] && pass "the login screen at 2736x1824: SG_LOGPIXELS=168 in its environment, from the kernel's mode; no Wine or X run before it" \
    || fail "sg_ui_scale at 2736x1824: '$u' (want '168 ')"
u=$(ui "$LIB" 1920x1080 | tr '\n' ' ')
[ "$u" = "none " ] && pass "at 1920x1080: nothing set, nothing run" || fail "sg_ui_scale at 1080p: '$u'"
u=$(ui "$LIB" none x | tr '\n' ' ')
[ "$u" = "168 xwininfo " ] && pass "the lock screen's own X server, no DRM output: its size (2736x1824, 168)" || fail "sg_ui_scale x: '$u'"

# --- mutants: the checks above catch each --------------------------------------------------
mutant() {   # NAME SED CHECK
    sed "$2" "$LIB" > "$T/mut.sh"
    cmp -s "$LIB" "$T/mut.sh" && { fail "MUTANT $1 did not apply"; return; }
    if eval "$3"; then pass "MUTANT $1 caught"; else fail "MUTANT $1 not caught"; fi
}
mutant NO_STICK 's/if \[ "\${_as_chosen:-0}" != 0 \]; then/if false; then/; s/elif \[ -n "\$_as_lp" \] && \[ "\$_as_lp" != 96 \]/elif false/' \
    '[ -n "$(stick "$T/mut.sh")" ]'
mutant LINUX_NO_SCALE 's/^    sg_linux_scale "\${1:-100}"$/    :/' \
    '[ "$(linux "$T/mut.sh" 175)" != "$(linux "$LIB" 175)" ]'
mutant UI_REGISTRY 's/^    SG_LOGPIXELS=\$(( _us_pc \* 96 \/ 100 ))$/    sg_auto_scale "${_us_size%x*}" "${_us_size#*x}" >\/dev\/null; return 0/' \
    '[ "$(ui "$T/mut.sh" 2736x1824 | tr "\n" " ")" != "168 " ]'
mutant UI_XSIZE 's/^    _us_size=\$(sg_drm_size)$/    _us_size=$(sg_x_size)/' \
    '[ "$(ui "$T/mut.sh" 2736x1824 | tr "\n" " ")" != "168 " ]'
mutant RECOMMEND_100 's/echo \$(( _sq \* 25 ))/echo 100/' '[ -n "$(table "$T/mut.sh")" ]'
mutant LIVE_NO_HUP 's/kill -HUP "\$_xs_p" 2>\/dev\/null \&\& return 0/return 0/' \
    '[ "$(live "$T/mut.sh")" != "$(live "$LIB")" ]'
mutant QT_TWICE 's/^    QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough$/    QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough QT_SCALE_FACTOR=1.75; export QT_SCALE_FACTOR/' \
    '[ "$(linux "$T/mut.sh" 175)" != "$(linux "$LIB" 175)" ]'
exit $RC
