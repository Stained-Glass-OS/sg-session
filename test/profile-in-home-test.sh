#!/bin/sh
# A profile that is the person's home (/etc/stained-glass/profile-in-home: a
# Debian machine turned into a Stained Glass one keeps homes where they are):
#   - C:\users\<user> becomes a link to the home, nothing is copied or moved;
#   - the home stays not group-writable and ssh keys keep their rights (ssh
#     refuses a key, sshd a home, that the group may write);
#   - the SYSTEM account (an elevated installer) may work in AppData, Desktop,
#     Documents and Downloads, but not in private files there (no group or
#     other access) nor in the rest of the home;
#   - a second sign-in changes nothing; without the setting, the profile is
#     a folder of its own, as before.
#
#   sudo sh test/profile-in-home-test.sh     (makes and removes an account sgpih)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root (the profile service runs as root)"; exit 77; }
command -v setfacl >/dev/null 2>&1 || { echo "SKIP: no setfacl"; exit 77; }
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
U=sgpih
T=$(mktemp -d /var/tmp/sg-pih.XXXXXX)
cleanup() { userdel -r "$U" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT INT TERM
chmod 0755 "$T"
getent passwd "$U" >/dev/null && userdel -r "$U" >/dev/null 2>&1
useradd -m -d "$T/home/$U" -s /bin/sh "$U" 2>/dev/null || { mkdir -p "$T/home"; useradd -m -d "$T/home/$U" -s /bin/sh "$U"; }
H="$T/home/$U"; G=$(id -gn "$U")
runuser -u "$U" -- sh -c 'cd "$1" && umask 077 && mkdir -p .ssh Documents Projects && ssh-keygen -q -t ed25519 -N "" -f .ssh/id_ed25519 &&
    echo secret > Documents/private.txt && umask 022 && echo hello > Documents/public.txt && echo code > Projects/main.c &&
    chmod 755 . Projects' x "$H"
mkdir -p "$T/prefix/drive_c/users" && chown nobody "$T/prefix/drive_c/users"
: > "$T/profile-in-home"
run() {
    env SG_LIB="$HERE/lib" SG_PREFIX="$T/prefix" SG_SYSTEM_USER=nobody SG_WINE_GROUP="$G" SG_LOG_DIR="$T" \
        SG_PROFILE_IN_HOME="$T/profile-in-home" SG_SHARED_HOME=/bin/true SG_APP_DEFAULTS=/bin/true \
        PAM_TYPE=open_session PAM_USER="$U" sh "${SG_PROFILE_CREATE_UNDER_TEST:-$HERE/bin/sg-profile-create}"
}
P="$T/prefix/drive_c/users/$U"
run
[ -L "$P" ] && [ "$(readlink "$P")" = "$H" ] && pass "the profile is a link to the home" || fail "profile: $(ls -ld "$P" 2>&1)"
[ -d "$H" ] && [ ! -L "$H" ] && [ -f "$H/Projects/main.c" ] && pass "the home stays where it was, with its files" || fail "home moved"
[ -d "$H/AppData/Local/Temp" ] && [ -d "$H/Downloads" ] && pass "the Windows folders are made in the home" || fail "no AppData/Downloads in the home"
m=$(stat -c %a "$H"); case "$m" in ?[2367]?) fail "the home is group-writable ($m): sshd refuses keys under it" ;; *) pass "the home is not group-writable ($m)" ;; esac
[ "$(stat -c %a "$H/.ssh/id_ed25519")" = 600 ] && ! getfacl -cp "$H/.ssh/id_ed25519" 2>/dev/null | grep -q '^user:[^:]' \
    && pass "the ssh key keeps 0600 and no ACL" || fail "key: $(stat -c %a "$H/.ssh/id_ed25519") $(getfacl -cp "$H/.ssh/id_ed25519" 2>/dev/null | tr '\n' ' ')"
runuser -u "$U" -- ssh-keygen -y -f "$H/.ssh/id_ed25519" >/dev/null 2>&1 && pass "ssh still accepts the key" || fail "ssh refuses the key"
getfacl -cp "$H/Documents/public.txt" 2>/dev/null | grep -q '^user:nobody:rw' && pass "SYSTEM may write a shared file in Documents" || fail "no SYSTEM entry on Documents/public.txt"
getfacl -cp "$H/Downloads" 2>/dev/null | grep -q '^default:user:nobody:rwx' && pass "new files in Downloads are SYSTEM's to use too (default ACL)" || fail "no default ACL on Downloads"
[ "$(stat -c %a "$H/Documents/private.txt")" = 600 ] && ! getfacl -cp "$H/Documents/private.txt" 2>/dev/null | grep -q '^user:[^:]' \
    && pass "a private file in Documents keeps its rights" || fail "private.txt: $(getfacl -cp "$H/Documents/private.txt" 2>/dev/null | tr '\n' ' ')"
! getfacl -cp "$H/Projects/main.c" 2>/dev/null | grep -q '^user:nobody' && pass "the rest of the home is untouched" || fail "Projects got an ACL"
before=$(getfacl -RPp "$H" 2>/dev/null | md5sum)
run
[ "$(getfacl -RPp "$H" 2>/dev/null | md5sum)" = "$before" ] && [ -L "$P" ] && pass "a second sign-in changes nothing" || fail "second sign-in changed rights"
# the conversion's way: the home bind-mounted on the profile (/etc/fstab)
rm -f "$P"; mkdir -p "$P"
if mount --bind "$H" "$P" 2>/dev/null; then
    rm -f "$H/AppData/Local/Stained Glass/system-access-home-1"
    run
    [ -d "$P" ] && [ ! -L "$P" ] && [ -f "$P/Projects/main.c" ] && pass "a home bind-mounted on the profile is taken as the profile" || fail "bind mount: $(ls -ld "$P" 2>&1)"
    [ "$(stat -c %a "$H/.ssh/id_ed25519")" = 600 ] && ! getfacl -cp "$H/.ssh/id_ed25519" 2>/dev/null | grep -q '^user:[^:]' \
        && ! getfacl -cp "$H/Projects/main.c" 2>/dev/null | grep -q '^user:nobody' \
        && pass "and the same narrow rights (the key and the rest of the home untouched)" || fail "bind mount: the recursive pass ran over the home"
    SG_SHARED_HOME_RUN=$(env SG_LIB="$HERE/lib" SG_PREFIX="$T/prefix" SG_HOMES="$T/home" SG_PROFILE_IN_HOME="$T/profile-in-home" \
        SG_PROFILE_CREATE=/bin/true sh "$HERE/bin/sg-shared-home" --boot 2>&1)
    [ -d "$H" ] && [ ! -L "$H" ] && [ ! -e "$T/home/.$U.pre-shared-home" ] && pass "sg-shared-home leaves such a home alone" || fail "sg-shared-home moved it: $SG_SHARED_HOME_RUN"
    umount "$P"
else
    echo "SKIP  bind mount (mount --bind not permitted here)"
fi
rmdir "$P" 2>/dev/null
# without the setting: a profile folder of its own, as before
rm -f "$P" "$T/profile-in-home"
run
[ -d "$P" ] && [ ! -L "$P" ] && pass "without profile-in-home the profile is a folder of its own" || fail "without the setting: $(ls -ld "$P" 2>&1)"
exit $RC
