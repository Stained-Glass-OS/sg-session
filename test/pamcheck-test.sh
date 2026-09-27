#!/bin/sh
# Blank passwords (sg-rdp-pamcheck): refused for remote sign-in, allowed at the
# lock screen, which is at the console -- Windows' "limit local account use of
# blank passwords to console logon only". The live system's account has no
# password; the lock screen refused it and locked people out of the live
# session. libpam is replaced by a recording stand-in: no account is touched.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ -x "$HERE/build/sg-rdp-pamcheck" ] || { echo "SKIP: sg-rdp-pamcheck not built (make rdp)"; exit 77; }
cc -shared -fPIC -o "$T/shim.so" "$HERE/test/pamcheck-shim.c" || { echo "SKIP: cannot build the shim"; exit 77; }
check() { # env... -> the shim's record
    : > "$T/out"
    printf 'someone\0\0' | env SG_PAMCHECK_SHIM_OUT="$T/out" LD_PRELOAD="$T/shim.so" "$@" "$HERE/build/sg-rdp-pamcheck" >/dev/null
    tr '\n' ' ' < "$T/out"
}
r=$(check env -u SG_PAMCHECK_CONSOLE)
case "$r" in *"auth_null=refused"*"rhost=rdp"*|*"rhost=rdp"*"auth_null=refused"*) pass "remote sign-in refuses a blank password ($r)";; *) fail "remote: $r";; esac
r=$(check env SG_PAMCHECK_CONSOLE=1 SG_REMOTE_PAM_SERVICE=stained-glass-lock)
case "$r" in *"auth_null=allowed"*) pass "the lock screen, at the console, allows one ($r)";; *) fail "console: $r";; esac
case "$r" in *rhost=*) fail "the console check claims to be remote";; *) pass "and does not claim to be remote";; esac
r=$(check env SG_PAMCHECK_CONSOLE=yes)
case "$r" in *"auth_null=refused"*) pass "only exactly SG_PAMCHECK_CONSOLE=1 counts";; *) fail "loose console flag: $r";; esac
grep -q 'setenv( "SG_PAMCHECK_CONSOLE", "1", 1 )' "$HERE/greeter/sg-lockd.c" && pass "sg-lockd asks for the console rule" || fail "sg-lockd does not set the console rule"
grep -q 'unsetenv( "SG_PAMCHECK_CONSOLE" )' "$HERE/greeter/sg-rdp-authd.c" && pass "sg-rdp-authd never passes it on" || fail "sg-rdp-authd may pass the console rule"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
