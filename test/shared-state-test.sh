#!/bin/sh
# sg-common.sh's sg_shared_state_hardened: the shared folders' own entries
# are the system's. Every person is in the Wine group, and the folders were
# group-writable without the sticky bit: a person could rename the prefix
# away, replace dosdevices\c: (the SYSTEM account's services then load
# "C:\windows" from a folder of theirs), replace the registry files, plant a
# stamp that skips a protection or another person's user-<uid>.reg. A scratch
# tree owned by this user (the machine account) with a second Unix user
# planting things as a person would.
#   sh test/shared-state-test.sh     (SG_OTHER: the second user, default sgconf)
# Needs passwordless sudo -u SG_OTHER, who must be in SG_GROUP (default
# sgconfgrp) and have uid >= 1000; exit 77 otherwise.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
OTHER=${SG_OTHER:-sgconf} GROUP=${SG_GROUP:-sgconfgrp}
id "$OTHER" >/dev/null 2>&1 && sudo -n -u "$OTHER" true 2>/dev/null || { echo "SKIP: needs sudo -u $OTHER"; exit 77; }
OU=$(id -u "$OTHER")
[ "$OU" -ge 1000 ] && id -nG "$OTHER" | tr ' ' '\n' | grep -qx "$GROUP" || { echo "SKIP: $OTHER is not a person in $GROUP"; exit 77; }
T=$(mktemp -d /var/tmp/sg-shared-state.XXXXXX); trap 'sudo -n -u "$OTHER" rm -rf "$T/r" "$T/m" 2>/dev/null; rm -rf "$T" 2>/dev/null' EXIT
chmod 755 "$T"
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
as() { sudo -n -u "$OTHER" sh -c "umask 002; $1" 2>/dev/null; }

mk() {   # the shared tree as it was: group-writable, setgid, not sticky
    _r=$1
    mkdir -p "$_r/prefix/dosdevices" "$_r/prefix/drive_c" "$_r/state/defaults" "$_r/.local/share/applications" \
        "$_r/.local/share/keyrings" "$_r/.config"
    chgrp -R "$GROUP" "$_r"
    chmod 2770 "$_r" "$_r/prefix" "$_r/state"; chmod 2775 "$_r/prefix/dosdevices" "$_r/state/defaults"
    chmod 2775 "$_r/.local" "$_r/.local/share" "$_r/.local/share/applications" "$_r/.config"
    chmod 2770 "$_r/.local/share/keyrings"
    ln -s ../drive_c "$_r/prefix/dosdevices/c:"
    ( umask 002; echo machine > "$_r/prefix/system.reg"; : > "$_r/prefix/.sg-system-prefix"
      echo app > "$_r/.local/share/applications/wine-extension-txt.desktop"; echo k > "$_r/.local/share/keyrings/x" )
    # what a person plants
    as "echo evil > '$_r/prefix/user-1999.reg'"
    as "mkdir '$_r/prefix/evilfolder' && chmod 700 '$_r/prefix/evilfolder'"
    as "ln -s /tmp '$_r/prefix/dosdevices/q:'"
    as ": > '$_r/state/windows-protected-1'; : > '$_r/state/defaults/80-x.reg.sha256'"
    as "echo DISPLAY=:9 > '$_r/state/session-$OU.env'"
    as "echo DISPLAY=:9 > '$_r/state/session-1999.env'"
    sudo -n -u "$OTHER" python3 -c "import socket,sys; [socket.socket(socket.AF_UNIX).bind(p) for p in sys.argv[1:]]" \
        "$_r/prefix/.sg-procagent.$OU" "$_r/prefix/.sg-procagent.1999"
}
run() { ( . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_log() { echo "LOG: $*" >> "$T/log"; }
          sg_shared_state_hardened "$1/" "$1/prefix" "$1/state" ) 2>/dev/null; }

mk "$T/r"
# before: what a person could do
as "mv '$T/r/prefix/system.reg' '$T/r/prefix/x' && mv '$T/r/prefix/x' '$T/r/prefix/system.reg'" \
    && pass "(before: a person could rename the system's registry file)" || fail "the old tree is not as it was"
run "$T/r"
R=$T/r
[ -k "$R" ] && [ -k "$R/prefix" ] && [ -k "$R/state" ] && [ -k "$R/.local" ] && [ -k "$R/.local/share" ] \
    && pass "the shared folders are sticky" || fail "sticky: $(stat -c '%A %n' "$R" "$R/prefix" "$R/state" | tr '\n' ' ')"
as "mv '$R/prefix/system.reg' '$R/prefix/x'"; [ -f "$R/prefix/system.reg" ] && [ ! -e "$R/prefix/x" ] \
    && pass "a person can no longer rename the system's registry file" || fail "system.reg could be renamed"
as "rm -f '$R/prefix/.sg-system-prefix'"; [ -e "$R/prefix/.sg-system-prefix" ] \
    && pass "nor delete the shared-prefix marker" || fail "the marker could be deleted"
as "mv '$R/prefix' '$R/gone'"; [ -d "$R/prefix" ] && pass "nor rename the prefix away" || fail "the prefix could be renamed away"
as "rm -f '$R/prefix/dosdevices/c:'; ln -s /tmp '$R/prefix/dosdevices/c:'"
[ "$(readlink "$R/prefix/dosdevices/c:")" = ../drive_c ] && pass "nor replace C: in dosdevices (the system's alone)" \
    || fail "c: now -> $(readlink "$R/prefix/dosdevices/c:")"
as "ln -s /tmp '$R/prefix/dosdevices/r:'"; [ ! -e "$R/prefix/dosdevices/r:" ] && [ ! -L "$R/prefix/dosdevices/r:" ] \
    && pass "nor add a drive letter" || fail "a person added r:"
moved() { [ ! -e "$1" ] && [ ! -L "$1" ] && ls -a "${1%/*}" | grep -q "^\.untrusted\.[0-9]*\.${1##*/}\$"; }
moved "$R/prefix/user-1999.reg" && pass "another person's planted hive is moved aside" || fail "user-1999.reg: $(ls -la "$R/prefix" | tr '\n' ' ')"
moved "$R/prefix/evilfolder" && pass "a folder a person made among the system's files too (it was not ours to empty)" || fail "evilfolder"
moved "$R/prefix/dosdevices/q:" && pass "the drive letter a person had added" || fail "q:"
moved "$R/state/windows-protected-1" && moved "$R/state/defaults/80-x.reg.sha256" \
    && pass "the stamps a person planted (they would have skipped a protection or a default)" || fail "stamps: $(ls -la "$R/state" "$R/state/defaults" | tr '\n' ' ')"
moved "$R/state/session-1999.env" && moved "$R/prefix/.sg-procagent.1999" \
    && pass "a session file or agent socket under another person's number too" || fail "wrong-uid files kept"
[ -S "$R/prefix/.sg-procagent.$OU" ] && [ -f "$R/state/session-$OU.env" ] \
    && pass "a person's own agent socket and session file stay" || fail "own files removed"
grep -q "moved aside .*user-1999.reg" "$T/log" && pass "each is said in the log" || fail "log: $(head -3 "$T/log")"
[ "$(stat -c %a "$R/prefix/system.reg")" = 644 ] && ! [ -n "$(find "$R/.local/share/applications/wine-extension-txt.desktop" -perm -g=w)" ] \
    && pass "the system's files and desktop entries are not the group's to change" \
    || fail "group-writable still: $(stat -c '%a %n' "$R/prefix/system.reg" "$R/.local/share/applications/wine-extension-txt.desktop" | tr '\n' ' ')"
[ "$(stat -c %a "$R/.local/share/keyrings")" = 2770 ] && pass "the session user's keyring folder is left as it is" \
    || fail "keyrings: $(stat -c %a "$R/.local/share/keyrings")"
as "echo x > '$R/prefix/newfile'"; [ -f "$R/prefix/newfile" ] && pass "people can still make files of their own in the prefix (Wine's clients must)" \
    || fail "the prefix is no longer writable for the group"
run "$R"; moved "$R/prefix/newfile" && [ "$(ls -a "$R/prefix" | grep -c '^\.untrusted\.')" -ge 3 ] \
    && pass "at the next boot that is moved aside too, and what was moved stays where it was put" || fail "second boot"

# mutant: the function does nothing
mk "$T/m"
( export SG_MUTANT_SHARED_STATE_OPEN=1; run "$T/m" )
as "rm -f '$T/m/prefix/dosdevices/c:'; ln -s /tmp '$T/m/prefix/dosdevices/c:'"
[ "$(readlink "$T/m/prefix/dosdevices/c:")" = /tmp ] && pass "MUTANT SHARED_STATE_OPEN: a person replaces C: (the test catches it)" \
    || fail "the mutant was not caught"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
