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
#   - sg_linux_scale_env: GTK, Qt, Xcursor and Xft.dpi at 175% and 150%;
#     nothing at all at 100% (a 1080p session as before)
# Mutants (sed on a copy of the library): NO_STICK (the pick ignored),
# LINUX_NO_SCALE (Linux programs left at 100%), RECOMMEND_100.
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
for c in systemctl dbus-update-activation-environment xrdb; do
    printf '#!/bin/sh\n[ "$1" = -merge ] && cat >> "%s/xrdb"\n[ "$1" = -query ] && cat "%s/xrdb" 2>/dev/null\nexit 0\n' "$T" "$T" > "$T/bin/$c"
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
fresh() { rm -f "$T/reg" "$T/calls" "$T/xrdb"; }
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

linux() {   # LIB PERCENT: the environment and resources set
    fresh
    run "$1" "sg_linux_scale_env $2; env" | grep -E '^(GDK_SCALE|GDK_DPI_SCALE|QT_SCALE_FACTOR|XCURSOR_SIZE)=' | sort | tr '\n' ' '
    tr '\n' ' ' 2>/dev/null < "$T/xrdb"
}
l=$(linux "$LIB" 175)
[ "$l" = "GDK_DPI_SCALE=0.5 GDK_SCALE=2 QT_SCALE_FACTOR=1.75 XCURSOR_SIZE=42 Xft.dpi: 168 Xcursor.size: 42 " ] \
    && pass "Linux programs at 175%: $l" || fail "Linux programs at 175%: '$l'"
l=$(linux "$LIB" 150)
[ "$l" = "GDK_DPI_SCALE=0.5 GDK_SCALE=2 QT_SCALE_FACTOR=1.5 XCURSOR_SIZE=36 Xft.dpi: 144 Xcursor.size: 36 " ] \
    && pass "Linux programs at 150%: $l" || fail "Linux programs at 150%: '$l'"
l=$(linux "$LIB" 125)
[ "$l" = "GDK_DPI_SCALE=1 GDK_SCALE=1 QT_SCALE_FACTOR=1.25 XCURSOR_SIZE=30 Xft.dpi: 120 Xcursor.size: 30 " ] \
    && pass "Linux programs at 125%: $l" || fail "Linux programs at 125%: '$l'"
l=$(linux "$LIB" 100)
[ -z "$l" ] && pass "at 100% nothing is set: a 1080p session's Linux programs as before" || fail "at 100%: '$l'"

# --- mutants: the checks above catch each --------------------------------------------------
mutant() {   # NAME SED CHECK
    sed "$2" "$LIB" > "$T/mut.sh"
    cmp -s "$LIB" "$T/mut.sh" && { fail "MUTANT $1 did not apply"; return; }
    if eval "$3"; then pass "MUTANT $1 caught"; else fail "MUTANT $1 not caught"; fi
}
mutant NO_STICK 's/if \[ "\${_as_chosen:-0}" != 0 \]; then/if false; then/; s/elif \[ -n "\$_as_lp" \] && \[ "\$_as_lp" != 96 \]/elif false/' \
    '[ -n "$(stick "$T/mut.sh")" ]'
mutant LINUX_NO_SCALE 's/\[ "\${1:-100}" -gt 100 \] 2>\/dev\/null || return 0/return 0/' \
    '[ "$(linux "$T/mut.sh" 175)" != "$(linux "$LIB" 175)" ]'
mutant RECOMMEND_100 's/echo \$(( _sq \* 25 ))/echo 100/' '[ -n "$(table "$T/mut.sh")" ]'
exit $RC
