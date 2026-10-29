#!/bin/sh
# An elevated program is the person who asked, elevated (wine-sg 7601): sg-elevated-run
# asks Wine for the person's elevated identity (SG_ELEVATED_IDENTITY=1, USER and LOGNAME
# the person's), so it has their HKCU -- and with it their light or dark modes and accent,
# which are no longer copied anywhere. What it still writes, into that HKCU, is its own
# display's no-tray setting: under the elevated desktop's own key, never Explorer's global
# one, which would take the tray off the person's taskbar. A stand-in wine records the
# .reg it was given. Mutant SG_MUTANT_ELEVATED_AS_SYSTEM must fail the identity check.
# Also Decorated=N: the display's manager draws no title bars, so Wine draws its own
# (mutant SG_MUTANT_ELEVATED_NO_CAPTION).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
cat > "$T/driver.c" <<EOC
#define main elevated_run_main
#include "$HERE/broker/sg-elevated-run.c"
#undef main
int main(void)
{
    elevated_identity(getuid());
    apply_user_look("sg-elevated-7");
    printf("identity %s\nuser %s\nlogname %s\nleft %s\n", getenv("SG_ELEVATED_IDENTITY") ? getenv("SG_ELEVATED_IDENTITY") : "-",
           getenv("USER") ? getenv("USER") : "-", getenv("LOGNAME") ? getenv("LOGNAME") : "-",
           getenv("SG_USER_ACCENT") ? "set" : "unset");
    return 0;
}
EOC
cc -O1 -o "$T/driver" "$T/driver.c" 2>"$T/cc.log" || { echo "SKIP: cannot build the driver"; cat "$T/cc.log"; exit 77; }
cc -O1 -DSG_MUTANT_ELEVATED_AS_SYSTEM -o "$T/driver-mut" "$T/driver.c" 2>>"$T/cc.log" || { echo "FAIL  the mutant does not build"; exit 1; }
mkdir "$T/bin"
cat > "$T/bin/wine" <<EOW
#!/bin/sh
[ "\$1 \$2" = "reg import" ] || exit 2
cp "\${3#Z:}" "$T/imported.reg"
EOW
chmod 755 "$T/bin/wine"
me=$(id -un)
run() { d=$1; shift; rm -f "$T/imported.reg"; env PATH="$T/bin:$PATH" USER=sgsystem LOGNAME=sgsystem "$@" "$T/$d"; }
v() { printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1; }

out=$(run driver env SG_USER_APPS_LIGHT=0 SG_USER_SYSTEM_LIGHT=0 SG_USER_ACCENT=ff3e8910)
[ "$(v "$out" identity)" = 1 ] && pass "it asks Wine for the person's elevated identity (SG_ELEVATED_IDENTITY=1)" || fail "identity: $out"
[ "$(v "$out" user)" = "$me" ] && [ "$(v "$out" logname)" = "$me" ] \
    && pass "...under the person's name ($me), not the SYSTEM account's" || fail "name: $(v "$out" user) $(v "$out" logname)"
r=$(tr -d '\r' < "$T/imported.reg" 2>/dev/null)
echo "$r" | grep -qx '\[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\\Desktops\\sg-elevated-7\]' && echo "$r" | grep -qx '"ShowSystray"=dword:00000000' \
    && pass "its own display (sg-elevated-7) has no stand-in tray" || fail "imported: $r"
! echo "$r" | grep -qx '\[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\]' \
    && pass "...and the person's taskbar keeps its tray (Explorer's global setting untouched)" || fail "the global ShowSystray was written: $r"
echo "$r" | grep -qx '\[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver\]' && echo "$r" | grep -qx '"Decorated"="N"' \
    && pass "Wine draws its windows' title bars there (the display's manager draws none)" || fail "no Decorated=N: $r"
! echo "$r" | grep -q 'AppsUseLightTheme\|SystemUsesLightTheme\|AccentColor' \
    && pass "the person's own modes and accent are not overwritten with copies" || fail "look copied: $r"
[ "$(v "$out" left)" = unset ] && pass "and sg-elevate's copies do not reach the program" || fail "left: $out"

cc -O1 -DSG_MUTANT_ELEVATED_NO_CAPTION -o "$T/driver-nocap" "$T/driver.c" 2>>"$T/cc.log" || { echo "FAIL  the mutant does not build"; exit 1; }
run driver-nocap env >/dev/null
! tr -d '\r' < "$T/imported.reg" | grep -q Decorated \
    && pass "MUTANT ELEVATED_NO_CAPTION: no Decorated=N (gate catches it)" || fail "mutant NO_CAPTION still writes it"
out=$(run driver-mut env)
[ "$(v "$out" identity)" != 1 ] && [ "$(v "$out" user)" = sgsystem ] \
    && pass "MUTANT ELEVATED_AS_SYSTEM: the program stays the SYSTEM account (gate catches it)" || fail "mutant: $out"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
