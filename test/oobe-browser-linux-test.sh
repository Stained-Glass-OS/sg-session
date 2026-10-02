#!/bin/sh
# shellcheck disable=SC2015  # pass/fail one-liners: both only print
# First-run setup's browser choice offers each browser's Linux build too
# (David 2026-10-01: they were all Windows programs). Every choice on the
# page is one sg-oobed accepts; a Linux build is installed by sg-admind's own
# apt install (its maker's apt source with it), and the request stays for the
# next boot when it did not install. Stand-ins: sg-admind, dpkg-query.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

ids=$(sed -n '/g_browsers\[\] = {/,/^};/p' "$HERE/setup/sg-oobe.c" | sed -n 's/^ *{ "\([^"]*\)".*/\1/p' | tr '\n' ' ')
offered=$(sed -n 's/^BROWSERS="\(.*\)"$/\1/p' "$HERE/setup/sg-oobed")
missing=""; for i in $ids; do case " $offered " in *" $i "*) ;; *) missing="$missing $i";; esac; done
[ -z "$missing" ] && pass "every browser on the page is one sg-oobed accepts ($(echo $ids | wc -w))" || fail "not accepted:$missing"
for b in linux:firefox linux:google-chrome-stable linux:microsoft-edge-stable; do
    case " $ids " in *" $b "*) ;; *) fail "the page does not offer $b";; esac
done
[ "${ids%% *}" = linux:firefox ] && pass "Firefox's Linux build comes first (the suggestion)" || fail "first: ${ids%% *}"

mkdir -p "$T/bin"
cat > "$T/admind" <<'PY'
import os
def op_apt_install(args):
    with open(os.environ["SG_TEST_LOG"], "a") as f:
        f.write("apt-install %s\n" % args[0])
    if os.environ.get("SG_TEST_INSTALLED") == "1":
        open(os.environ["SG_TEST_DONE"], "w").close()
    return ["%s 1.0" % args[0]]
PY
cat > "$T/bin/dpkg-query" <<'SH'
#!/bin/sh
[ -e "$SG_TEST_DONE" ] && printf installed || printf not-installed
SH
chmod +x "$T/bin/dpkg-query"
run() {  # id installed?
    rm -f "$T/done" "$T/log"; printf '%s\n' "$1" > "$T/req"
    env PATH="$T/bin:$PATH" SG_LIB="$HERE/lib" SG_ADMIND="$T/admind" SG_OOBE_BROWSER_REQ="$T/req" \
        SG_TEST_LOG="$T/log" SG_TEST_DONE="$T/done" SG_TEST_INSTALLED="$2" sh "$HERE/lib/sg-oobe-browser" >/dev/null 2>&1
}
run linux:firefox 1; rc=$?
[ "$(cat "$T/log" 2>/dev/null)" = "apt-install firefox" ] && [ $rc = 0 ] && [ ! -e "$T/req" ] \
    && pass "Firefox's Linux build: sg-admind's apt install of firefox, and the request is done" || fail "linux:firefox rc=$rc log='$(cat "$T/log" 2>/dev/null)' req=$([ -e "$T/req" ] && echo kept || echo gone)"
run linux:microsoft-edge-stable 0; rc=$?
[ "$(cat "$T/log" 2>/dev/null)" = "apt-install microsoft-edge-stable" ] && [ $rc != 0 ] && [ -e "$T/req" ] \
    && pass "not installed (offline): the request stays for the next boot" || fail "failure path rc=$rc req=$([ -e "$T/req" ] && echo kept || echo gone)"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
