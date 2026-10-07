#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# The kiosk app in a real session: test/run-session-test.sh's headless
# session (compositor, Xwayland, the prefix, explorer as the shell), with an
# automatic-sign-in configuration (SG_AUTOLOGON_CONF) naming this account and
# a stand-in Linux app that records each start and closes after two seconds.
# Checked against the live session: the app was started once the shell was
# up, started again after it closed, and the account's taskbar hides itself
# (HKCU\Software\Stained Glass\Taskbar AutoHide = 1, set before the shell).
# --mutant: SG_MUTANT_KIOSK_NO_RESTART=1 -- the gate must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
K=$(mktemp -d /var/tmp/sg-kiosk-e2e.XXXXXX)
trap 'rm -rf "$K"' EXIT INT TERM
[ "${1:-}" = --mutant ] && { SG_MUTANT_KIOSK_NO_RESTART=1; export SG_MUTANT_KIOSK_NO_RESTART; }

cat > "$K/app.sh" <<EOF
#!/bin/sh
date +%s >> "$K/starts"
sleep 2
EOF
chmod +x "$K/app.sh"
printf '[Desktop Entry]\nType=Application\nName=Kiosk stand-in\nExec=%s\n' "$K/app.sh" > "$K/app.desktop"
printf 'user=%s\nkiosk-name=Kiosk stand-in\nkiosk-desktop=%s\n' "$(id -un)" "$K/app.desktop" > "$K/autologon.conf"
SG_AUTOLOGON_CONF="$K/autologon.conf"
SG_KIOSK_DELAY=2
export SG_AUTOLOGON_CONF SG_KIOSK_DELAY
# run against the live session, after sg-session-check, before the teardown
# shellcheck disable=SC2089  # a command line for sh -c, quotes and all
SG_TEST_HOLD="i=0; while [ \$i -lt 90 ] && [ \"\$(wc -l < '$K/starts' 2>/dev/null || echo 0)\" -lt 3 ]; do sleep 1; i=\$((i + 1)); done;
wine reg query 'HKCU\\Software\\Stained Glass\\Taskbar' /v AutoHide > '$K/autohide' 2>&1; echo held > '$K/held'"
export SG_TEST_HOLD

sh "$HERE/test/run-session-test.sh" > "$K/session.out" 2>&1
src=$?
RC=0
if [ "$src" = 77 ]; then tail -3 "$K/session.out"; exit 77; fi
[ "$src" = 0 ] || { echo "FAIL  the session did not come up (rc=$src)"; tail -40 "$K/session.out"; exit 1; }
[ -f "$K/held" ] || { echo "FAIL  the checks did not run"; exit 1; }
n=$(wc -l < "$K/starts" 2>/dev/null || echo 0)
if [ "$n" -ge 1 ]; then echo "PASS  the kiosk app was started in the session"; else echo "FAIL  the kiosk app was never started"; RC=1; fi
if [ "$n" -ge 3 ]; then echo "PASS  ...and started again each time it closed ($n starts)"; else echo "FAIL  started $n time(s), not again after closing"; RC=1; fi
if tr -d '\r' < "$K/autohide" | grep -Eq 'AutoHide +REG_DWORD +0x1$'; then echo "PASS  the kiosk account's taskbar hides itself"
else echo "FAIL  taskbar auto-hide: $(tr '\n' ' ' < "$K/autohide")"; RC=1; fi
[ "$RC" = 0 ] || grep -i kiosk "$HERE/test/tmp/log/session.log" 2>/dev/null | tail -10
echo "kiosk-e2e: $([ "$RC" = 0 ] && echo PASS || echo FAIL)"
exit $RC
