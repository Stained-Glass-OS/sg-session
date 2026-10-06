#!/bin/sh
# sg-common.sh's sg_windows_protected: C:\windows is the system's, as on
# Windows -- users read and run what is there and change none of it. The
# prefix was made with the Wine group's write (umask 002): every user could
# replace a DLL in system32 that SYSTEM's services load, or put one beside
# explorer.exe in C:\windows (older notes: David 2026-10-02 #34). Users still
# write in Temp, Tasks, Installer and Logs, each their own files (sticky);
# the print spool is left as it is. A scratch tree, the user's own group
# standing in for the Wine group.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v setfacl >/dev/null && command -v getfacl >/dev/null || { echo "SKIP: needs acl (setfacl, getfacl)"; exit 77; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
grp=$(id -gn)
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
gw() { [ -n "$(find "$1" -maxdepth 0 -perm -g=w 2>/dev/null)" ]; }

mk() {   # a prefix as the SYSTEM account makes it: umask 002, setgid folders
    _p=$1
    mkdir -p "$_p/drive_c/windows/system32/spool/printers" "$_p/drive_c/windows/system32/spool/drivers/x64/3" \
        "$_p/drive_c/windows/system32/catroot" "$_p/drive_c/windows/syswow64" \
        "$_p/drive_c/windows/temp" "$_p/drive_c/windows/Installer" "$_p/state"
    ( umask 002
      : > "$_p/drive_c/windows/system32/kernel32.dll"; : > "$_p/drive_c/windows/explorer.exe"
      : > "$_p/drive_c/windows/syswow64/user32.dll"; : > "$_p/drive_c/windows/Installer/cached.msi"
      : > "$_p/.update-timestamp" )
    chmod 2775 "$_p/drive_c/windows" "$_p/drive_c/windows/system32" "$_p/drive_c/windows/syswow64"
    chmod 3770 "$_p/drive_c/windows/system32/spool/printers"
    chmod 2775 "$_p/drive_c/windows/system32/spool/drivers" "$_p/drive_c/windows/system32/spool/drivers/x64/3"
    setfacl -m g::rwx "$_p/drive_c/windows/temp" 2>/dev/null || { echo "SKIP: the file system here has no ACLs"; exit 77; }
}
mk "$T/p"
C="$T/p/drive_c"
( . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_windows_protected "$C" "$grp" "$T/p/state" )

! gw "$C/windows" && ! gw "$C/windows/system32" && ! gw "$C/windows/syswow64" \
    && pass "C:\\windows, system32, syswow64: the users' group may not add or remove anything" \
    || fail "folders still group-writable: $(stat -c '%A %n' "$C/windows" "$C/windows/system32" "$C/windows/syswow64" | tr '\n' ' ')"
! gw "$C/windows/system32/kernel32.dll" && ! gw "$C/windows/explorer.exe" && ! gw "$C/windows/syswow64/user32.dll" \
    && pass "nor change a system DLL or program" \
    || fail "files still group-writable: $(stat -c '%A %n' "$C/windows/system32/kernel32.dll" "$C/windows/explorer.exe" | tr '\n' ' ')"
[ -g "$C/windows/system32" ] && pass "the folders stay setgid" || fail "setgid lost"
( umask 002; : > "$C/windows/system32/later.dll" )
! gw "$C/windows/system32/later.dll" && pass "a DLL the system puts there later (umask 002) is not the group's to change either" \
    || fail "later file: $(getfacl -p "$C/windows/system32/later.dll" 2>/dev/null | tr '\n' ' ')"
for d in temp tasks Installer logs system32/catroot system32/catroot2; do
    if [ -d "$C/windows/$d" ] && [ -k "$C/windows/$d" ] && gw "$C/windows/$d"; then :; else
        fail "windows\\$d: $(stat -c '%A' "$C/windows/$d" 2>&1)"; d=bad; break
    fi
done
[ "$d" != bad ] && pass "Temp, Tasks, Installer, Logs, catroot, catroot2: the users may write there, sticky (their own files only)"
! gw "$C/windows/Installer/cached.msi" && pass "the system's cached package in Installer is not theirs to change" \
    || fail "cached.msi: $(stat -c '%A' "$C/windows/Installer/cached.msi")"
( umask 002; : > "$C/windows/temp/mine.tmp" )
! gw "$C/windows/temp/mine.tmp" && pass "what a user makes in Temp is not the group's to change" \
    || fail "temp file: $(getfacl -p "$C/windows/temp/mine.tmp" 2>/dev/null | tr '\n' ' ')"
[ "$(stat -c %a "$C/windows/system32/spool/printers")" = 3770 ] && gw "$C/windows/system32/spool/drivers/x64/3" \
    && pass "the print spool is left as it is (each session's winspool adds the printers' PPDs there)" \
    || fail "spool: $(stat -c '%a %n' "$C/windows/system32/spool/printers" "$C/windows/system32/spool/drivers/x64/3" | tr '\n' ' ')"
! gw "$T/p/.update-timestamp" && pass "Wine's record of the prefix's version is the system's" \
    || fail ".update-timestamp: $(stat -c '%A' "$T/p/.update-timestamp")"
[ -e "$T/p/state/windows-protected-1" ] && pass "the folders' inheritance is set once (stamp)" || fail "no stamp"
# at a later boot: a file a Wine update made group-writable is mended
chmod g+w "$C/windows/system32/kernel32.dll"
( . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_windows_protected "$C" "$grp" "$T/p/state" )
! gw "$C/windows/system32/kernel32.dll" && pass "at every boot: what was made group-writable since is mended" \
    || fail "not mended at the next boot"

# mutant: the function does nothing
mk "$T/m"
( SG_MUTANT_WINDOWS_WRITABLE=1; . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_windows_protected "$T/m/drive_c" "$grp" "$T/m/state" )
gw "$T/m/drive_c/windows/system32/kernel32.dll" && pass "MUTANT WINDOWS_WRITABLE leaves system32 writable (the test catches it)" \
    || fail "the mutant was not caught"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
