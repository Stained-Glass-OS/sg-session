#!/bin/sh
# sg-common.sh's sg_ssh_migrate: the image's lab-only SSH leftovers (sshd
# only with root's keys, passwords refused -- "start condition unmet" for
# David, 2026-10-01) go when they are exactly what the image put there; an
# administrator's own edits stay. And the package's 05- file allows
# passwords for people, keys only for root.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
lab() { mkdir -p "$(dirname "$1")"; cat > "$1" <<'LAB'
# Stained Glass OS: the OpenSSH server is for the lab only (the image gates).
# The image carries no key; a gate hands its key to the VM as a systemd
# credential (QEMU -smbios type=11: ssh.authorized_keys.root, written to
# /root/.ssh/authorized_keys by tmpfiles' provision.conf). Without one --
# every real PC -- nothing listens on port 22.
#
# An administrator who wants ssh: put keys in /root/.ssh/authorized_keys, or
# remove this file (and ssh.socket.d's) for users' own keys.
[Unit]
ConditionPathExists=/root/.ssh/authorized_keys
LAB
}
oldconf() { mkdir -p "$(dirname "$1")"; printf '# Lab access only. Key auth, no passwords, ever.\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUseDNS no\n' > "$1"; }
mig() { sh -c '. "$1/lib/sg-common.sh" >/dev/null 2>&1; sg_ssh_migrate "$2"' sh "$HERE" "$1"; }

R="$T/a"
lab "$R/etc/systemd/system/ssh.service.d/10-stained-glass-lab.conf"
lab "$R/etc/systemd/system/ssh.socket.d/10-stained-glass-lab.conf"
oldconf "$R/etc/ssh/sshd_config.d/10-stained-glass.conf"
mig "$R"
[ ! -e "$R/etc/systemd/system/ssh.service.d/10-stained-glass-lab.conf" ] && [ ! -e "$R/etc/systemd/system/ssh.socket.d/10-stained-glass-lab.conf" ] \
    && pass "the image's start condition is gone (service and socket)" || fail "the start condition stayed"
[ ! -e "$R/etc/ssh/sshd_config.d/10-stained-glass.conf" ] && pass "and its no-passwords file" || fail "the old sshd file stayed"

R="$T/b"
lab "$R/etc/systemd/system/ssh.service.d/10-stained-glass-lab.conf"
echo "# mine" >> "$R/etc/systemd/system/ssh.service.d/10-stained-glass-lab.conf"
oldconf "$R/etc/ssh/sshd_config.d/10-stained-glass.conf"
sed -i 's/UseDNS no/UseDNS yes/' "$R/etc/ssh/sshd_config.d/10-stained-glass.conf"
mig "$R"
[ -e "$R/etc/systemd/system/ssh.service.d/10-stained-glass-lab.conf" ] && [ -e "$R/etc/ssh/sshd_config.d/10-stained-glass.conf" ] \
    && pass "an administrator's edited files stay" || fail "edited files were removed"
mig "$T/none" && pass "nothing to migrate is fine" || fail "an empty root failed"

C="$HERE/config/ssh/05-stained-glass.conf"
first() { awk -v k="$1" '$1 == k { print $2; exit }' "$C"; }
[ "$(first PasswordAuthentication)" = yes ] && [ "$(first KbdInteractiveAuthentication)" = yes ] \
    && pass "the package's file allows passwords" || fail "passwords: $(first PasswordAuthentication)/$(first KbdInteractiveAuthentication)"
[ "$(first PermitRootLogin)" = prohibit-password ] && pass "root signs in with keys only" || fail "root: $(first PermitRootLogin)"
if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
    mkdir -p "$T/k"; ssh-keygen -q -t ed25519 -N '' -f "$T/k/host" >/dev/null 2>&1
    printf 'Include %s\nHostKey %s\n' "$C" "$T/k/host" > "$T/sshd_config"
    eff=$(/usr/sbin/sshd -T -f "$T/sshd_config" 2>/dev/null)
    echo "$eff" | grep -qx 'passwordauthentication yes' && echo "$eff" | grep -qx 'permitrootlogin without-password' \
        && pass "sshd reads it so (sshd -T)" || fail "sshd -T: $(echo "$eff" | grep -E 'passwordauth|permitroot')"
fi
exit $RC
