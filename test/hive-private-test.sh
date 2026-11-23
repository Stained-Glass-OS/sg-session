#!/bin/sh
# Per-person privacy the way Windows has it (David 2026-11-23), lib/sg-common.sh:
#  sg_hive_private PREFIX: each person's registry hive (user-<uid>.reg, the prefix owner's
#    user.reg) and the server's temporary copies of one (reg*.tmp, *.reg.sg-temp-repair) are
#    closed to group and others -- they were 0644 in the Wine group, so every account could read
#    every other person's HKCU. Only the machine account's (or root's) regular single-link files:
#    not system.reg or userdef.reg, not through a symlink or a hard link, not a file someone else
#    owns. It names what it closed.
#  sg_system_temp_private DRIVE_C SYSTEM_USER: SYSTEM's profile Temp is 0700 with no ACL entries
#    (it was 2775 in the Wine group); what another account left in it is moved aside
#    (.untrusted.<time>.<name>), never removed; SYSTEM's own files stay.
#  sg-prefix-init runs both at every boot, sg-services-start the Temp one.
#   sh test/hive-private-test.sh     SG_MUTANT_HIVE_OPEN=1 / SG_MUTANT_SYSTEM_TEMP_OPEN=1: must FAIL
# The other account's files need passwordless sudo -u SG_OTHER (default sgconf); without it
# those checks are skipped, the rest still run.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
OTHER=${SG_OTHER:-sgconf}
T=$(mktemp -d "${TMPDIR:-/tmp}/sg-hivepriv.XXXXXX")
chmod 755 "$T"   # the other account reaches its files in here
HAVE_OTHER=0
if id "$OTHER" >/dev/null 2>&1 && sudo -n -u "$OTHER" true 2>/dev/null; then HAVE_OTHER=1; fi
trap '[ "$HAVE_OTHER" = 1 ] && sudo -n -u "$OTHER" rm -rf "$T/p/user-77.reg" "$T/c/users/me/AppData/Local/Temp/theirs" "$T/c/users/me/AppData/Local/Temp"/.untrusted.*theirs* 2>/dev/null; rm -rf "$T"' EXIT INT TERM
# shellcheck source=lib/sg-common.sh
. "$HERE/lib/sg-common.sh"
mode() { stat -c %a "$1" 2>/dev/null; }
ME=$(id -un)

# --- hives ---------------------------------------------------------------
P=$T/p
mkdir -p "$P"; chmod 1777 "$P"
for f in user-1000.reg user.reg reg3f2a0001.tmp user-1000.reg.sg-temp-repair system.reg userdef.reg; do
    echo "WINE REGISTRY Version 2" > "$P/$f"; chmod 644 "$P/$f"
done
chmod 664 "$P/user.reg"
echo outside > "$T/outside"; chmod 644 "$T/outside"
ln -s "$T/outside" "$P/user-5.reg"
echo linked > "$T/linked"; chmod 644 "$T/linked"; ln "$T/linked" "$P/user-6.reg"
if [ "$HAVE_OTHER" = 1 ]; then
    sudo -n -u "$OTHER" sh -c "echo planted > '$P/user-77.reg'; chmod 644 '$P/user-77.reg'"
fi
out=$(sg_hive_private "$P")
ok=1
for f in user-1000.reg user.reg reg3f2a0001.tmp user-1000.reg.sg-temp-repair; do
    [ "$(mode "$P/$f")" = 600 ] || { ok=0; fail "$f is $(mode "$P/$f"), not 600"; }
done
[ "$ok" = 1 ] && pass "people's hives and the temporary copies of one are closed to others (600)"
printf '%s\n' "$out" | grep -q 'user-1000.reg$' && printf '%s\n' "$out" | grep -q '/user.reg$' \
    && pass "it names what it closed" || fail "output: $out"
[ "$(mode "$P/system.reg")" = 644 ] && [ "$(mode "$P/userdef.reg")" = 644 ] \
    && pass "system.reg and userdef.reg keep their modes" || fail "system.reg $(mode "$P/system.reg"), userdef.reg $(mode "$P/userdef.reg")"
[ "$(mode "$T/outside")" = 644 ] && pass "never through a symlink" || fail "the link's target became $(mode "$T/outside")"
[ "$(mode "$T/linked")" = 644 ] && pass "never a file with another link" || fail "the hard link's file became $(mode "$T/linked")"
if [ "$HAVE_OTHER" = 1 ]; then
    [ "$(mode "$P/user-77.reg")" = 644 ] && pass "not a file another account owns (wine-sg 1475 moves those aside)" \
        || fail "another account's file became $(mode "$P/user-77.reg")"
else echo "SKIP  another account's file (no sudo -u $OTHER)"; fi
out2=$(sg_hive_private "$P")
[ -z "$out2" ] && pass "a second run has nothing to close" || fail "second run: $out2"

# --- SYSTEM's Temp ---------------------------------------------------------
C=$T/c; TT=$C/users/$ME/AppData/Local/Temp
mkdir -p "$TT/mine.dir"; chmod 2775 "$TT"
if command -v setfacl >/dev/null 2>&1; then setfacl -m "u:$ME:rwx" -m d:g::rwx "$TT" 2>/dev/null; fi
echo x > "$TT/mine.tmp"
if [ "$HAVE_OTHER" = 1 ]; then
    chmod 2777 "$TT"
    sudo -n -u "$OTHER" sh -c "mkdir '$TT/theirs'; echo y > '$TT/theirs/payload.dll'"
fi
sg_system_temp_private "$C" "$ME" 2>"$T/temp.log"
[ -z "$(find "$TT" -maxdepth 0 -perm /077)" ] && pass "SYSTEM's Temp is SYSTEM's alone (no group or other access)" \
    || fail "SYSTEM's Temp is $(stat -c %A "$TT")"
if command -v getfacl >/dev/null 2>&1; then
    if getfacl -cp "$TT" 2>/dev/null | grep -qE '^(user|group):[^:]+:|^default:'; then fail "ACL entries left: $(getfacl -cp "$TT" | tr '\n' ' ')"
    else pass "with no ACL entries"; fi
fi
[ -f "$TT/mine.tmp" ] && [ -d "$TT/mine.dir" ] && pass "SYSTEM's own files stay" || fail "SYSTEM's own files: $(ls -a "$TT" | tr '\n' ' ')"
if [ "$HAVE_OTHER" = 1 ]; then
    if [ ! -e "$TT/theirs" ] && ls -a "$TT" | grep -q '^\.untrusted\.[0-9]*\.theirs$'; then
        pass "another account's file there is moved aside, not removed"
    else fail "another account's file: $(ls -a "$TT" | tr '\n' ' ')"; fi
    grep -q "another account's file in SYSTEM's Temp" "$T/temp.log" && pass "and said in the log" || fail "log: $(tail -2 "$T/temp.log")"
else echo "SKIP  another account's file in Temp (no sudo -u $OTHER)"; fi
mkdir -p "$T/realtemp/AppData/Local/Temp"; chmod 755 "$T/realtemp/AppData/Local/Temp"
mkdir -p "$C/users/linked/AppData/Local"; ln -s "$T/realtemp/AppData/Local/Temp" "$C/users/linked/AppData/Local/Temp"
sg_system_temp_private "$C" linked 2>/dev/null
[ "$(mode "$T/realtemp/AppData/Local/Temp")" = 755 ] && pass "a Temp that is a symlink is left alone" || fail "followed a symlinked Temp"

# --- wiring ------------------------------------------------------------------
grep -q 'sg_hive_private "\$SG_PREFIX"' "$HERE/bin/sg-prefix-init" && [ "$(grep -c 'sg_system_temp_private ' "$HERE/bin/sg-prefix-init")" -ge 2 ] \
    && grep -q 'sg_system_temp_private ' "$HERE/bin/sg-services-start" \
    && pass "sg-prefix-init (every boot and a new prefix) and sg-services-start run them" || fail "not wired in"

exit $RC
