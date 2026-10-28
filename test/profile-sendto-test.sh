#!/bin/sh
# sg-profile-create plants Windows' Send to items in a profile, once: a new
# profile gets them, an existing one gets them at its next login, and an item
# the user deleted is not put back. And the SYSTEM account may read and write
# the profile (an elevated installer in Downloads), no one else.
#
#   sudo sh test/profile-sendto-test.sh [USER]    (USER: an account to own the profile; default sgconf)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root (the profile service runs as root)"; exit 77; }
user="${1:-sgconf}"
id "$user" >/dev/null 2>&1 || { echo "SKIP: no account $user"; exit 77; }
group=$(id -gn "$user")
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

T=$(mktemp -d /var/tmp/sg-profile.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
chmod 0755 "$T"
mkdir -p "$T/prefix/drive_c/users"
chown -R nobody "$T/prefix/drive_c/users"
run() {
    env SG_LIB="$HERE/lib" SG_PREFIX="$T/prefix" SG_SYSTEM_USER=nobody SG_WINE_GROUP="$group" SG_LOG_DIR="$T" \
        SG_APP_DEFAULTS="$HERE/bin/sg-app-defaults" PAM_TYPE=open_session PAM_USER="$user" sh "${SG_PROFILE_CREATE:-$HERE/bin/sg-profile-create}"
}
D="$T/prefix/drive_c/users/$user/AppData/Roaming/Microsoft/Windows/SendTo"

run
for f in "Compressed (zipped) Folder.ZFSendToTarget" "Desktop (create shortcut).DeskLink" "Documents.mydocs"; do
    [ -f "$D/$f" ] && [ ! -s "$D/$f" ] && pass "a new profile has Send to > $f" || fail "missing $D/$f"
done
[ "$(stat -c %U "$D/Documents.mydocs" 2>/dev/null)" = "$user" ] && pass "the items are the user's" || fail "owner: $(stat -c %U "$D/Documents.mydocs" 2>&1)"

rm -f "$D/Documents.mydocs"
run
[ ! -e "$D/Documents.mydocs" ] && pass "an item the user deleted stays deleted" || fail "Documents.mydocs came back"

# a profile made before: no marker, no SendTo items
rm -rf "$D" "$T/prefix/drive_c/users/$user/AppData/Local/Stained Glass"
run
[ -f "$D/Desktop (create shortcut).DeskLink" ] && pass "an existing profile gets them at its next login" || fail "existing profile: $(ls "$D" 2>&1)"

# the SYSTEM account (here: nobody) may read what the user downloads, as on
# Windows -- an elevated installer runs as SYSTEM
P="$T/prefix/drive_c/users/$user"
if command -v setfacl >/dev/null 2>&1; then
    runuser -u "$user" -- sh -c 'umask 077; printf x > "$1/Downloads/setup.exe"' sh "$P"
    runuser -u nobody -- test -r "$P/Downloads/setup.exe" && pass "the SYSTEM account can read a file the user downloaded after" \
        || fail "SYSTEM cannot read Downloads/setup.exe: $(getfacl -p "$P/Downloads" 2>&1 | tr '\n' ' ')"
    runuser -u nobody -- sh -c 'printf y > "$1/Downloads/by-system.txt"' sh "$P" && pass "and write in the profile" \
        || fail "SYSTEM cannot write in Downloads"
    # an elevated program is the person (wine-sg 7601): what it makes in the
    # profile, as SYSTEM on disk, stays theirs -- a file, and a folder of
    # settings with a file in it, as an installer's AppData
    runuser -u nobody -- sh -c 'umask 077; mkdir -p "$1/AppData/Roaming/Prog" && printf z > "$1/AppData/Roaming/Prog/settings.ini"' sh "$P"
    runuser -u "$user" -- sh -c 'cat "$1/Downloads/by-system.txt" >/dev/null && printf w >> "$1/Downloads/by-system.txt" &&
        printf v >> "$1/AppData/Roaming/Prog/settings.ini" && mkdir "$1/AppData/Roaming/Prog/more" &&
        rm "$1/AppData/Roaming/Prog/settings.ini"' sh "$P" \
        && pass "what SYSTEM made in the profile the person reads, changes and deletes" \
        || fail "the person cannot use SYSTEM's files: $(getfacl -p "$P/AppData/Roaming/Prog" 2>&1 | tr '\n' ' ')"
    # a profile from before (marker -2): its next sign-in gives the person's entry
    rm -f "$P/AppData/Local/Stained Glass/system-access-3"
    setfacl -R -x "d:u:$user" -x "u:$user" "$P" 2>/dev/null
    : > "$P/AppData/Local/Stained Glass/system-access-2"
    run
    runuser -u nobody -- sh -c 'umask 077; mkdir -p "$1/AppData/Roaming/Old" && printf z > "$1/AppData/Roaming/Old/a.ini"' sh "$P"
    runuser -u "$user" -- sh -c 'printf v >> "$1/AppData/Roaming/Old/a.ini"' sh "$P" \
        && pass "...in a profile from before too, after its next sign-in" || fail "older profile: $(getfacl -p "$P/AppData/Roaming" 2>&1 | tr '\n' ' ')"
    other=$(getent passwd | awk -F: -v u="$user" '$3 >= 1000 && $3 < 60000 && $1 != u {print $1; exit}')
    if [ -n "$other" ]; then
        runuser -u "$other" -- test -r "$P/Downloads/setup.exe" 2>/dev/null && fail "another user ($other) can read it" \
            || pass "another user ($other) still cannot"
    fi
else echo "      (no setfacl: skipped)"; fi

[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
