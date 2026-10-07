#!/bin/sh
# An elevated program looks like the user's others (light or dark, accent):
# sg-elevate reads the user's choices and the broker passes them on;
# sg-elevated-run takes only exact values -- 0 or 1, eight hex digits -- and
# writes them into the SYSTEM account's settings through a file of its own,
# before the program starts. A stand-in wine records what it was given.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
cat > "$T/driver.c" <<EOC
#define main elevated_run_main
#include "$HERE/broker/sg-elevated-run.c"
#undef main
int main(void) { apply_user_look(); printf("left %s\n", getenv("SG_USER_ACCENT") ? "set" : "unset"); return 0; }
EOC
cc -O1 -o "$T/driver" "$T/driver.c" 2>"$T/cc.log" || { echo "SKIP: cannot build the driver"; cat "$T/cc.log"; exit 77; }
mkdir "$T/bin"
cat > "$T/bin/wine" <<EOW
#!/bin/sh
[ "\$1 \$2" = "reg import" ] || exit 2
cp "\${3#Z:}" "$T/imported.reg"
EOW
chmod 755 "$T/bin/wine"
run() { rm -f "$T/imported.reg"; env PATH="$T/bin:$PATH" "$@" "$T/driver"; }

out=$(run env SG_USER_APPS_LIGHT=0 SG_USER_SYSTEM_LIGHT=0 SG_USER_ACCENT=ff3e8910)
r=$(tr -d '\r' < "$T/imported.reg" 2>/dev/null)
echo "$r" | grep -qx '"AppsUseLightTheme"=dword:00000000' && echo "$r" | grep -qx '"SystemUsesLightTheme"=dword:00000000' \
    && echo "$r" | grep -qx '"AccentColor"=dword:ff3e8910' && echo "$r" | grep -q 'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\DWM' \
    && pass "the user's dark modes and green accent go into the SYSTEM account's settings" || fail "imported: $r"
[ "$out" = "left unset" ] && pass "and the variables do not reach the program" || fail "left: $out"
run env SG_USER_APPS_LIGHT='1"
[HKEY_LOCAL_MACHINE\Evil]' SG_USER_ACCENT='ff3e8910"=x' >/dev/null
# the file is written whatever was given (ShowSystray=0: no stand-in tray on
# the elevated display, b737bb8) -- but nothing hostile gets into it
r=$(tr -d '\r' < "$T/imported.reg" 2>/dev/null)
! echo "$r" | grep -q 'Evil\|=x\|AppsUseLightTheme\|AccentColor' \
    && pass "anything but 0, 1 or eight hex digits is ignored (no injection into the .reg)" \
    || fail "a hostile value was written: $r"
run env SG_USER_APPS_LIGHT=1 >/dev/null
r=$(tr -d '\r' < "$T/imported.reg" 2>/dev/null)
echo "$r" | grep -qx '"AppsUseLightTheme"=dword:00000001' && ! echo "$r" | grep -q AccentColor \
    && pass "only what was given is written" || fail "partial: $r"
run env >/dev/null
r=$(tr -d '\r' < "$T/imported.reg" 2>/dev/null)
echo "$r" | grep -qx '"ShowSystray"=dword:00000000' && ! echo "$r" | grep -q 'LightTheme\|AccentColor' \
    && pass "nothing given: only the elevated display's no-tray setting is written" || fail "nothing given: $r"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
