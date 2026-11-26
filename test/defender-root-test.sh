#!/bin/sh
# SG Defender as root (bin/sg-defender), between two accounts: it must read
# for each person only what that person can read, and act only as them.
# Runs the service as root in a private mount and network namespace (sudo -n,
# or as root in CI), everything in a tmpfs of its own; a stand-in clamd finds
# the EICAR test string. Person A is the invoking user, person B "nobody".
#   1. the socket is root's and the Windows-side group's (0660), nobody else's
#   2. a scan runs as the person: a link in their Downloads to B's private
#      file is not followed, B's file is not read, reported or removed
#   3. the download watcher opens as the folder's person: a folder swapped for
#      a link into root's files after the download is written finds nothing
#      there (root never opens a path in someone's folders)
#   4. the machine's part of a scan runs as the SYSTEM account: A's private
#      file named in a Run key is not read; a file SYSTEM can read but not
#      remove is reported "not removed", and left
#   5. a person's notices are theirs alone (root's folder, their group or ACL)
# Mutants: ROOT_OPENS (the watcher's opener stays root), SCAN_AS_ROOT (scan
# children keep root).
#   defender-root-test.sh [--mutant ROOT_OPENS|SCAN_AS_ROOT]
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MUTANT=""; [ "${1:-}" = --mutant ] && MUTANT=$2
if [ "$(id -u)" != 0 ]; then
    sudo -n true 2>/dev/null || { echo "SKIP: needs root (sudo -n)"; exit 77; }
    exec sudo -n env SG_ROOT_TEST_A="$(id -u)" SG_ROOT_TEST_NS=1 unshare -m -n --propagation private -- sh "$0" "$@"
fi
if [ -z "${SG_ROOT_TEST_NS:-}" ]; then     # root already (CI): namespaces of its own, if it may
    unshare -m -n --propagation private true 2>/dev/null || { echo "SKIP: no namespaces here"; exit 77; }
    exec env SG_ROOT_TEST_NS=1 unshare -m -n --propagation private -- sh "$0" "$@"
fi
# root, in its own namespaces (or CI's container)
A=${SG_ROOT_TEST_A:-1000}
getent passwd "$A" >/dev/null || A=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $3; exit }')
B=$(id -u nobody)
[ -n "$A" ] && [ -n "$B" ] || { echo "SKIP: no ordinary account to test with"; exit 77; }
AG=$(getent passwd "$A" | cut -d: -f4)
T=$(mktemp -d /var/tmp/sg-defender-root.XXXXXX)
mount -t tmpfs -o mode=755 tmpfs "$T" || { rmdir "$T"; echo "SKIP: no tmpfs"; exit 77; }
CP= DP=
cleanup() { kill $DP $CP 2>/dev/null; sleep 0.3; umount "$T" 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
ip link set lo up 2>/dev/null
EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
mkdir -p "$T/a/Downloads" "$T/a/Desktop" "$T/b" "$T/rootonly" "$T/prefix/drive_c/users" "$T/prefix/dosdevices" "$T/run"
ln -s ../drive_c "$T/prefix/dosdevices/c:"
chown -R "$A:$AG" "$T/a"; chmod 700 "$T/a"
chown "$B" "$T/b"; chmod 700 "$T/b"; chmod 700 "$T/rootonly"
printf 'MZ%s B private' "$EICAR" > "$T/b/private.exe"; chown "$B" "$T/b/private.exe"; chmod 600 "$T/b/private.exe"
printf 'MZ%s root only' "$EICAR" > "$T/rootonly/x.exe"; chmod 600 "$T/rootonly/x.exe"
# A's Downloads: a link to B's private file, and one of A's own
ln -s "$T/b/private.exe" "$T/a/Downloads/link.exe"
printf 'MZ%s mine' "$EICAR" > "$T/a/Downloads/mine.exe"; chown -h "$A:$AG" "$T/a/Downloads/"*
# the machine's: a Run key naming A's private file, and a file SYSTEM may read but not remove
printf 'MZ%s A private' "$EICAR" > "$T/a/secret.exe"; chown "$A" "$T/a/secret.exe"; chmod 600 "$T/a/secret.exe"
mkdir -p "$T/prefix/drive_c/Tools"; printf 'MZ%s readonly' "$EICAR" > "$T/prefix/drive_c/Tools/ro.exe"
chmod 755 "$T/prefix/drive_c/Tools"; chmod 644 "$T/prefix/drive_c/Tools/ro.exe"
ln -s "$T/a" "$T/prefix/drive_c/users/a"
printf 'WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1700000000\n"A"="C:\\\\users\\\\a\\\\secret.exe"\n"Ro"="C:\\\\Tools\\\\ro.exe"\n' \
    > "$T/prefix/system.reg"; chmod 600 "$T/prefix/system.reg"

SRC="$HERE/bin/sg-defender"
case "$MUTANT" in
ROOT_OPENS) sed 's/^    sock, pid = as_user(uid, child, path)$/    sock, pid = as_user(0, child, path)/' "$SRC" > "$T/mut.py"; SRC="$T/mut.py" ;;
SCAN_AS_ROOT) sed 's/^            become(cred)$/            pass/' "$SRC" > "$T/mut.py"; SRC="$T/mut.py" ;;
esac
python3 "$HERE/test/defender-fake-clamd.py" "$T/clamd.sock" "$T/scanned" & CP=$!
SG_DEFENDER_CONF="$T/defender.conf" SG_DEFENDER_STATE="$T/state" SG_DEFENDER_NOTICES="$T/notices" \
SG_DEFENDER_HOMES="$T/a:$T/b" SG_DEFENDER_CLAMD="$T/clamd.sock" SG_DEFENDER_RUNTIME="$T/run" \
SG_DEFENDER_EXCLUSIONS="$T/exclusions" SG_DEFENDER_PREFIX="$T/prefix" SG_DEFENDER_SCHEDULE_HOURS=1000 \
SG_DEFENDER_SYSTEM_USER=nobody SG_DEFENDER_GROUP="$(getent group "$AG" | cut -d: -f1)" \
    python3 "$SRC" 2>"$T/log" & DP=$!
i=0; while [ ! -S "$T/run/socket" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
sleep 1

# 1. the socket
[ "$(stat -c '%U %g %a' "$T/run/socket")" = "root $AG 660" ] && pass "the socket is root's and the Windows-side group's (0660)" \
    || fail "socket: $(stat -c '%U %g %a' "$T/run/socket")"
if setpriv --reuid="$B" --regid=65534 --clear-groups python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])' "$T/run/socket" 2>/dev/null; then
    fail "someone outside the group can connect"
else pass "...nobody outside the group can connect"; fi

# 2. A's quick scan, as A
out=$(SG_DEFENDER_RUNTIME="$T/run" SG_DEFENDER_NOTICES="$T/notices" setpriv --reuid="$A" --regid="$AG" --init-groups \
      python3 "$HERE/bin/sg-defender-scan" quick --wait 2>&1)
echo "$out" | grep -q "mine.exe: Eicar-Test-Signature (removed)" && [ ! -e "$T/a/Downloads/mine.exe" ] \
    && pass "a person's scan finds and removes their own file" || fail "own file: $out"
[ -e "$T/b/private.exe" ] && ! echo "$out" | grep -q private.exe && ! grep -q "$T/b/private.exe" "$T/scanned" 2>/dev/null \
    && pass "...but a link to another person's private file is not followed: not read, not reported, not removed" \
    || fail "B's file: $(grep private "$T/scanned"; echo "$out" | grep private)"

# 3. the watcher: a folder swapped for a link into root's files
mkdir "$T/a/Downloads/sub"; chown "$A:$AG" "$T/a/Downloads/sub"; sleep 1.5
setpriv --reuid="$A" --regid="$AG" --init-groups sh -c "printf 'MZ%s' '$EICAR' > '$T/a/Downloads/sub/x.exe'; mv '$T/a/Downloads/sub' '$T/a/Downloads/sub.old'; ln -s '$T/rootonly' '$T/a/Downloads/sub'"
sleep 3
[ -e "$T/rootonly/x.exe" ] && ! grep -q "$T/rootonly" "$T/scanned" 2>/dev/null \
    && pass "the download watcher opens as the person: a link swapped in leads nowhere (root's file not read or moved)" \
    || fail "the watcher followed into root's files: $(ls "$T/rootonly"; grep rootonly "$T/scanned")"

# 4. the machine's part, as the SYSTEM account (here: nobody)
kill $DP 2>/dev/null; sleep 0.5; : > "$T/scanned"
printf 'MZ%s A private' "$EICAR" > "$T/a/secret.exe"; chown "$A" "$T/a/secret.exe"; chmod 600 "$T/a/secret.exe"
mkdir -p "$T/state"; touch -d '2 days ago' "$T/state/last-scheduled-scan"
SG_DEFENDER_CONF="$T/defender.conf" SG_DEFENDER_STATE="$T/state" SG_DEFENDER_NOTICES="$T/notices" \
SG_DEFENDER_HOMES="$T/a:$T/b" SG_DEFENDER_CLAMD="$T/clamd.sock" SG_DEFENDER_RUNTIME="$T/run" \
SG_DEFENDER_EXCLUSIONS="$T/exclusions" SG_DEFENDER_PREFIX="$T/prefix" SG_DEFENDER_SCHEDULE_HOURS=0.0003 \
SG_DEFENDER_SYSTEM_USER=nobody SG_DEFENDER_GROUP="$(getent group "$AG" | cut -d: -f1)" \
    python3 "$SRC" 2>"$T/log2" & DP=$!
i=0; while [ $i -lt 90 ] && ! grep -q '"name": "ro.exe"' "$T/notices/$B/scans.json" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
sleep 1
grep -q "$T/a/secret.exe" "$T/scanned" && fail "the SYSTEM account's scan read a person's private file" \
    || pass "the scheduled scan's machine part runs as the SYSTEM account: a person's private file is not read"
python3 - "$T/notices/$B/scans.json" <<'PY' && pass "...a file it can read but not remove is reported, not removed" || fail "SYSTEM scan record: $(cat "$T/notices/$B/scans.json" 2>&1 | head -30)"
import json, sys
s = json.load(open(sys.argv[1]))[0]
t = [x for x in s["threats"] if x["name"] == "ro.exe"]
sys.exit(0 if t and not t[0]["removed"] else 1)
PY
[ -e "$T/prefix/drive_c/Tools/ro.exe" ] || fail "ro.exe was removed (root?)"

# 5. notices
d="$T/notices/$A"
[ "$(stat -c '%U %a' "$d" 2>/dev/null)" = "root 750" ] && { [ "$(stat -c %g "$d")" = "$AG" ] || getfacl -p "$d" 2>/dev/null | grep -q "^user:[^:]*$A\|^user:$(getent passwd "$A" | cut -d: -f1):r-x"; } \
    && pass "a person's notices: root's folder, readable by them alone" || fail "notices: $(stat -c '%U %g %a' "$d")"
[ -n "$MUTANT" ] && echo "(mutant $MUTANT)"
exit $RC
