#!/bin/sh
# Per-person privacy the way Windows has it (David 2026-11-23), lib/sg-common.sh:
#  sg_hive_private PREFIX: each person's registry hive (user-<uid>.reg, the prefix owner's
#    user.reg) and the server's temporary copies of one (reg*.tmp, *.reg.sg-temp-repair) are
#    closed to group and others -- they were 0644 in the Wine group, so every account could read
#    every other person's HKCU. Only the machine account's (or root's) regular single-link files:
#    the machine's system.reg too (wine-sg 9101), not userdef.reg (the Default User template),
#    not through a symlink or a hard link, not a file someone else owns. It names what it closed.
#  sg_system_profile_private DRIVE_C SYSTEM_USER: SYSTEM's profile (and its Temp, C:\users\SYSTEM)
#    is closed to group and others with no ACL entries; what other accounts put anywhere in it is
#    moved aside. sg_system_temp_private: SYSTEM's profile Temp is 0700 with no ACL entries
#    (it was 2775 in the Wine group); what another account left in it is moved aside
#    (.untrusted.<time>.<name>), never removed; SYSTEM's own files stay.
#  sg-prefix-init runs both at every boot, sg-services-start the profile one.
#   sh test/hive-private-test.sh     SG_MUTANT_HIVE_OPEN, _SYSTEM_HIVE_OPEN, _SYSTEM_TEMP_OPEN,
#                                    _SYSTEM_PROFILE_OPEN (=1): each must FAIL
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
[ "$(mode "$P/system.reg")" = 600 ] && pass "the machine's hive, system.reg, is closed to others too" || fail "system.reg is $(mode "$P/system.reg")"
[ "$(mode "$P/userdef.reg")" = 644 ] && pass "userdef.reg (the Default User template) keeps its mode" || fail "userdef.reg $(mode "$P/userdef.reg")"
[ "$(mode "$T/outside")" = 644 ] && pass "never through a symlink" || fail "the link's target became $(mode "$T/outside")"
[ "$(mode "$T/linked")" = 644 ] && pass "never a file with another link" || fail "the hard link's file became $(mode "$T/linked")"
if [ "$HAVE_OTHER" = 1 ]; then
    [ "$(mode "$P/user-77.reg")" = 644 ] && pass "not a file another account owns (wine-sg 1475 moves those aside)" \
        || fail "another account's file became $(mode "$P/user-77.reg")"
else echo "SKIP  another account's file (no sudo -u $OTHER)"; fi
out2=$(sg_hive_private "$P")
[ -z "$out2" ] && pass "a second run has nothing to close" || fail "second run: $out2"

# --- SYSTEM's profile ---------------------------------------------------------
C=$T/c; PP=$C/users/$ME; TT=$PP/AppData/Local/Temp; RO=$PP/AppData/Roaming
mkdir -p "$TT/mine.dir" "$RO/Vendor" "$PP/Desktop" "$C/users/SYSTEM/AppData"
chmod 2775 "$PP" "$TT" "$RO"; chmod 2755 "$C/users/SYSTEM"
if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "u:$ME:rwx" -m d:g::rwx "$TT" 2>/dev/null; setfacl -m "u:$ME:rwx" "$PP" 2>/dev/null
fi
echo x > "$TT/mine.tmp"; echo cfg > "$RO/Vendor/settings.ini"
if [ "$HAVE_OTHER" = 1 ]; then
    chmod 2777 "$TT" "$RO"
    sudo -n -u "$OTHER" sh -c "mkdir '$TT/theirs'; echo y > '$TT/theirs/payload.dll'; echo z > '$RO/evil.dll'"
fi
sg_system_profile_private "$C" "$ME" 2>"$T/temp.log"
closed() { [ -z "$(find "$1" -maxdepth 0 -perm /077)" ]; }
closed "$PP" && pass "SYSTEM's profile is SYSTEM's alone (no group or other access)" || fail "SYSTEM's profile is $(stat -c %A "$PP")"
closed "$TT" && pass "SYSTEM's Temp is SYSTEM's alone too" || fail "SYSTEM's Temp is $(stat -c %A "$TT")"
closed "$C/users/SYSTEM" && pass "and Wine's C:\\users\\SYSTEM" || fail "users/SYSTEM is $(stat -c %A "$C/users/SYSTEM")"
if command -v getfacl >/dev/null 2>&1; then
    if getfacl -cp "$PP" "$TT" 2>/dev/null | grep -qE '^(user|group):[^:]+:|^default:'; then fail "ACL entries left: $(getfacl -cp "$PP" "$TT" | tr '\n' ' ')"
    else pass "with no ACL entries"; fi
fi
[ -f "$TT/mine.tmp" ] && [ -d "$TT/mine.dir" ] && [ -f "$RO/Vendor/settings.ini" ] && pass "SYSTEM's own files stay" \
    || fail "SYSTEM's own files: $(ls -aR "$PP" | tr '\n' ' ')"
if [ "$HAVE_OTHER" = 1 ]; then
    if [ ! -e "$TT/theirs" ] && ls -a "$TT" | grep -q '^\.untrusted\.[0-9]*\.theirs$' \
        && [ ! -e "$RO/evil.dll" ] && ls -a "$RO" | grep -q '^\.untrusted\.[0-9]*\.evil\.dll$'; then
        pass "another account's files anywhere in it are moved aside where they are, not removed"
    else fail "another account's files: $(ls -a "$TT" "$RO" | tr '\n' ' ')"; fi
    grep -q "another account's file in SYSTEM's" "$T/temp.log" && pass "and said in the log" || fail "log: $(tail -2 "$T/temp.log")"
    sg_system_profile_private "$C" "$ME" 2>"$T/temp2.log"
    [ ! -s "$T/temp2.log" ] && pass "a second run moves nothing again" || fail "second run: $(cat "$T/temp2.log")"
else echo "SKIP  another account's files in SYSTEM's profile (no sudo -u $OTHER)"; fi
mkdir -p "$T/realprof" "$C/users"; chmod 755 "$T/realprof"; ln -s "$T/realprof" "$C/users/linked"
sg_system_profile_private "$C" linked 2>/dev/null
[ "$(mode "$T/realprof")" = 755 ] && pass "a profile that is a symlink is left alone" || fail "followed a symlinked profile"
mkdir -p "$T/realtemp/AppData/Local/Temp"; chmod 755 "$T/realtemp/AppData/Local/Temp"
mkdir -p "$C/users/linked2/AppData/Local"; ln -s "$T/realtemp/AppData/Local/Temp" "$C/users/linked2/AppData/Local/Temp"
sg_system_temp_private "$C" linked2 2>/dev/null
[ "$(mode "$T/realtemp/AppData/Local/Temp")" = 755 ] && pass "a Temp that is a symlink is left alone" || fail "followed a symlinked Temp"

# --- wiring ------------------------------------------------------------------
grep -q 'sg_hive_private "\$SG_PREFIX"' "$HERE/bin/sg-prefix-init" && [ "$(grep -c 'sg_system_profile_private ' "$HERE/bin/sg-prefix-init")" -ge 2 ] \
    && grep -q 'sg_system_profile_private ' "$HERE/bin/sg-services-start" \
    && pass "sg-prefix-init (every boot and a new prefix) and sg-services-start run them" || fail "not wired in"

exit $RC
