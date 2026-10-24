#!/bin/sh
# sg-app-defaults: Everything's folder index, seeded in a profile once -- a new
# profile gets it, one where Everything ran before (its empty folders=) gets it
# with every other line kept, folders the person chose stay, a deleted ini is
# not put back, and nothing while the person's Everything runs or when it is
# not installed for the machine (app_data=1).
# Mutant: SG_MUTANT_APPDEFAULTS_WHILE_RUNNING=1 (seeds while it runs) fails it.
#
#   sh test/app-defaults-test.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

T=$(mktemp -d /var/tmp/sg-appdefaults.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
P="$T/prefix/drive_c/users/u"
SYS="$T/prefix/drive_c/Program Files/Everything/Everything.ini"
INI="$P/AppData/Roaming/Everything/Everything.ini"
MARK="$P/AppData/Local/Stained Glass/everything-defaults"
mkdir -p "$P"
PS="$T/ps"
: > "$PS"
run() { env SG_TEST_PS="$PS" SG_LIB="$HERE/lib" SG_PREFIX="$T/prefix" SG_LOG_DIR="$T" sh "$HERE/bin/sg-app-defaults" "$P"; }
fresh() { rm -rf "$P/AppData"; }
seed=$(printf '[Everything]\r\nfolders="C:\\\\"\r\nfolder_monitor_changes=1\r\n' | od -An -c)

run
[ ! -e "$INI" ] && [ ! -e "$MARK" ] && pass "Everything not installed: nothing" || fail "seeded without Everything"

mkdir -p "$(dirname "$SYS")"
printf '[Everything]\r\napp_data=0\r\n' > "$SYS"
run
[ ! -e "$INI" ] && pass "app_data=0 (settings beside it): nothing" || fail "seeded an app_data=0 install"

printf '; Please make sure Everything is not running before modifying this file.\r\n[Everything]\r\napp_data=1\r\nallow_http_server=0\r\n' > "$SYS"
run
[ "$(od -An -c < "$INI" 2>/dev/null)" = "$seed" ] && pass "a new profile: folders=\"C:\\\\\", watched, CRLF" \
    || fail "seed: $(od -c < "$INI" 2>&1 | head -5)"
[ -e "$MARK" ] && pass "and its marker" || fail "no marker"

rm -f "$INI"
run
[ ! -e "$INI" ] && pass "an ini the person deleted is not put back" || fail "came back"

fresh
mkdir -p "$(dirname "$INI")"
printf '[Everything]\r\nrun_count=1\r\nfolders=\r\nfolder_monitor_changes=\r\nwindow_x=40\r\n' > "$INI"
run
want=$(printf '[Everything]\r\nrun_count=1\r\nfolders="C:\\\\"\r\nfolder_monitor_changes=1\r\nwindow_x=40\r\n' | od -An -c)
[ "$(od -An -c < "$INI")" = "$want" ] && pass "Everything ran before: the index goes in, the rest stays" \
    || fail "patched: $(od -c < "$INI" | head -6)"

fresh
mkdir -p "$(dirname "$INI")"
printf '[Everything]\r\nfolders="D:\\\\music"\r\nfolder_monitor_changes=0\r\n' > "$INI"
before=$(od -An -c < "$INI")
run
[ "$(od -An -c < "$INI")" = "$before" ] && pass "folders the person chose stay" || fail "overwrote: $(cat "$INI")"

fresh
printf '%s\n' 'C:\Program Files\Everything\Everything.exe -startup' > "$PS"
run
[ ! -e "$INI" ] && [ ! -e "$MARK" ] && pass "not while the person's Everything runs (it rewrites the ini at exit)" \
    || fail "seeded while Everything runs"
: > "$PS"
run
[ -e "$INI" ] && pass "and at the next sign-in after it" || fail "not seeded after it stopped"

[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
