#!/bin/sh
# Unit test for sg-shared-home: /home/<user> becomes a link to the user's
# Windows profile. Unprivileged: stand-in getent and runuser, homes and the
# prefix in a scratch directory, the "user" is whoever runs this (so the
# profile's owner matches) -- no real home is ever touched.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ME=$(id -un); UID_=$(id -u)
[ "$UID_" -ge 1000 ] || { echo "SKIP: run as an ordinary user"; exit 77; }
mkdir -p "$T/bin" "$T/homes" "$T/prefix/drive_c/users/$ME" "$T/skel"
cat > "$T/bin/getent" <<W
#!/bin/sh
case "\$1" in
passwd) [ "\$2" = "$ME" ] && echo "$ME:x:$UID_:$UID_::$T/homes/$ME:/bin/sh" ;;
group) echo "sgwine:x:900:$ME" ;;
esac
W
cat > "$T/bin/runuser" <<'W'
#!/bin/sh
shift 3; exec "$@"
W
chmod +x "$T/bin/getent" "$T/bin/runuser"
P="$T/prefix/drive_c/users/$ME"
run() { PATH="$T/bin:$PATH" SG_LIB="$HERE/lib" SG_PREFIX="$T/prefix" SG_HOMES="$T/homes" SG_SYSTEM_USER=nobody \
        SG_PROFILE_CREATE=/nonexistent SG_NO_SHARED_HOME="$T/off" sh "$HERE/bin/sg-shared-home" "$@" 2>/dev/null; }
RC=0
ok() { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; RC=1; }

# 1. a home in use, at sign-in: left for the next boot
mkdir -p "$T/homes/$ME/.config"; echo mine > "$T/homes/$ME/notes.txt"; chmod 700 "$T/homes/$ME"
command -v setfacl >/dev/null 2>&1 && setfacl -m u:nobody:rwx -m d:u:nobody:rwx "$P"
echo profile > "$P/notes.txt"; mkdir -p "$P/Documents"
run --login "$ME"
[ -d "$T/homes/$ME" ] && [ ! -L "$T/homes/$ME" ] && ok "a home in use is not moved at sign-in" || bad "moved at sign-in"
# 2. at boot: kept, copied without overwriting, linked
run --boot
if [ -L "$T/homes/$ME" ] && [ "$(readlink "$T/homes/$ME")" = "$P" ]; then ok "at boot the home becomes a link to the profile"; else bad "not linked: $(ls -ld "$T/homes/$ME")"; fi
[ -d "$T/homes/.$ME.pre-shared-home" ] && [ -f "$T/homes/.$ME.pre-shared-home/notes.txt" ] && ok "the old home is kept" || bad "old home not kept"
[ -d "$P/.config" ] && [ "$(cat "$P/notes.txt")" = profile ] && ok "its files are copied in, never over the profile's" || bad "copy: $(ls -a "$P")"
[ -d "$P/Documents" ] && [ ! -L "$P/Documents" ] && ok "the profile stays ordinary folders" || bad "profile changed"
# the SYSTEM account (here "nobody") keeps the profile: cp -a gave it the old
# home's 0700, which emptied the ACL mask, and elevated programs could read
# nothing in it
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    getfacl -p "$P" 2>/dev/null | grep -q '^user:nobody:rwx$' && ! getfacl -p "$P" 2>/dev/null | grep -q '^user:nobody:rwx.*#effective' \
        && ok "the SYSTEM account keeps the profile after the home is merged in" || bad "profile ACL: $(getfacl -p "$P" 2>/dev/null | tr '\n' ' ')"
    getfacl -p "$P/.config" 2>/dev/null | grep -q '^user:nobody:rwx' \
        && ok "and the files merged in from the old home" || bad "merged files' ACL: $(getfacl -p "$P/.config" 2>/dev/null | tr '\n' ' ')"
fi
# 3. again: nothing changes
run --boot
[ ! -e "$T/homes/.$ME.pre-shared-home.2" ] && [ -L "$T/homes/$ME" ] && ok "running again changes nothing" || bad "not idempotent"
# 4. a new account (no home yet) at sign-in: linked at once
rm "$T/homes/$ME"
run --login "$ME"
[ -L "$T/homes/$ME" ] && ok "a new account's home is linked at its first sign-in" || bad "new account not linked"
# 5. turned off
rm "$T/homes/$ME"; : > "$T/off"
run --boot
[ ! -e "$T/homes/$ME" ] && ok "no-shared-home turns it off" || bad "ran while turned off"
exit $RC
