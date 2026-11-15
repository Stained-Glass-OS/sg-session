#!/bin/sh
# NVIDIA's own driver (sg-drivers): a card NVIDIA's open kernel modules run
# (Turing and later) is offered nvidia-open from NVIDIA's archive; an older
# one keeps what Debian's nvidia-detect names. Installing it writes NVIDIA's
# source -- its key alone (Signed-By) -- and a pin that lets the archive give
# only NVIDIA's driver packages: real apt, against a stand-in of the archive,
# takes nvidia-driver from it and never cuda-toolkit or dkms. At boot (Setup's
# --pending run) a running NVIDIA driver is not replaced.
#   --mutant pin|key|boot   the test must fail
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
D="$HERE/bin/sg-drivers"
KEY="$HERE/config/keyrings/nvidia-debian13.gpg"
MUTANT=""; [ "${1:-}" = --mutant ] && MUTANT=${2:?}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
case "$MUTANT" in
    pin) sed 's/^Pin-Priority: -1$/Pin-Priority: 500/' "$D" > "$T/sg-drivers"; D="$T/sg-drivers" ;;
    key) KEY=/usr/share/keyrings/debian-archive-keyring.gpg ;;
    boot) sed 's/if \[ "\$PENDING" = 1 \] && \[ -e "\$nvidia_running" \]; then/if false; then/' "$D" > "$T/sg-drivers"; D="$T/sg-drivers" ;;
esac

# the key sg-session ships is NVIDIA's Debian 13 archive key
fpr=$(gpg --show-keys --with-colons "$KEY" 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }')
[ "$fpr" = 02182E60104FCDC26EAE1B8597A5D4CB8793F200 ] && pass "the key is NVIDIA's Debian 13 archive key (…8793F200)" \
    || fail "the key's fingerprint is '$fpr'"

printf '#!/bin/sh\nprintf "It is recommended to install the\\n    nvidia-driver\\npackage.\\n"\n' > "$T/nvidia-detect"
chmod +x "$T/nvidia-detect"
printf '0000:01:00.0 10de 2204 030000\n0000:02:00.0 10de 1c82 030000\n' > "$T/pci"
mkdir -p "$T/q"; printf '#!/bin/sh\nexit 1\n' > "$T/q/dpkg-query"; chmod +x "$T/q/dpkg-query"
out=$(PATH="$T/q:$PATH" SG_DRIVERS_PCI="$T/pci" SG_DRIVERS_NVIDIA_DETECT="$T/nvidia-detect" SG_DRIVERS_DMI="$T/nodmi" sh "$D" --list 2>/dev/null)
row() { printf '%s\n' "$out" | awk -F'\t' -v s="DEVICE $1" '$1 == s { print $4 }'; }
[ "$(row 0000:01:00.0)" = "nvidia-open linux-image-amd64 linux-headers-amd64" ] \
    && pass "an RTX 3090 (Ampere) is offered NVIDIA's own driver, nvidia-open" || fail "RTX 3090: '$(row 0000:01:00.0)'"
[ "$(row 0000:02:00.0)" = "nvidia-driver firmware-misc-nonfree linux-image-amd64 linux-headers-amd64" ] \
    && pass "a GTX 1050 Ti (Pascal, older than the open modules) keeps Debian's, as nvidia-detect says" \
    || fail "GTX 1050 Ti: '$(row 0000:02:00.0)'"

# --install-recommended with stand-ins for apt: what it writes, what it installs
mkdir -p "$T/bin"
cat > "$T/bin/apt-get" <<'EOS'
echo "$*" >> "$SG_T/apt.log"
EOS
cat > "$T/bin/apt-cache" <<'EOS'
printf '%s:\n  Installed: (none)\n  Candidate: 1\n' "$2"
EOS
cp "$T/q/dpkg-query" "$T/bin/dpkg-query"
chmod +x "$T/bin/"*
printf '0000:01:00.0 10de 2204 030000\n' > "$T/pci1"
inst() {   # [env...]
    rm -rf "$T/apt" "$T/etc"; mkdir -p "$T/apt" "$T/etc"; : > "$T/apt.log"
    env SG_T="$T" PATH="$T/bin:$PATH" SG_DRIVERS_PCI="$T/pci1" SG_DRIVERS_APT="$T/apt" SG_DRIVERS_ETC="$T/etc" \
        SG_DRIVERS_NVIDIA_KEYRING="$KEY" SG_DRIVERS_FIRMWARE_LOOKUP=/nonexistent SG_DRIVERS_DMI="$T/nodmi" \
        SG_DRIVERS_NVIDIA_RUNNING="$T/no-nvidia-running" SG_DRIVERS_ENTRIES="$T/none" "$@" \
        sh "$D" --install-recommended 2> "$T/inst.err"
}
inst
S="$T/apt/sources.list.d/sg-nvidia.sources"
grep -qx "URIs: https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/" "$S" 2>/dev/null \
    && grep -qx "Signed-By: $KEY" "$S" && pass "NVIDIA's archive is added, its key pinned to it (Signed-By)" \
    || fail "source: $(cat "$S" 2>&1)"
grep -q "install linux-headers-amd64 linux-image-amd64 nvidia-open" "$T/apt.log" \
    && pass "nvidia-open is installed, with the kernel and headers DKMS builds for" || fail "apt: $(cat "$T/apt.log")"

# at boot with an NVIDIA driver running: not replaced there
: > "$T/nvidia-running"
inst SG_DRIVERS_NVIDIA_RUNNING="$T/nvidia-running"
: > "$T/etc/drivers.auto"
env SG_T="$T" PATH="$T/bin:$PATH" SG_DRIVERS_PCI="$T/pci1" SG_DRIVERS_APT="$T/apt" SG_DRIVERS_ETC="$T/etc" \
    SG_DRIVERS_NVIDIA_KEYRING="$KEY" SG_DRIVERS_FIRMWARE_LOOKUP=/nonexistent SG_DRIVERS_DMI="$T/nodmi" \
    SG_DRIVERS_NVIDIA_RUNNING="$T/nvidia-running" SG_DRIVERS_ENTRIES="$T/none" \
    sh "$D" --install-recommended --pending 2> "$T/boot.err"
tail -1 "$T/apt.log" | grep -q nvidia-open && fail "at boot, the running NVIDIA driver was replaced: $(tail -1 "$T/apt.log")" \
    || { grep -q "not at boot" "$T/boot.err" && pass "at boot a running NVIDIA driver is left for a run by hand (it says so)" \
        || fail "boot run: $(cat "$T/boot.err")"; }

# the pin, by real apt: a stand-in of NVIDIA's archive (Origin: NVIDIA) with
# its driver, CUDA and a dkms of its own; apt may take only the driver
R="$T/repo"; mkdir -p "$R" "$T/root/etc/apt/sources.list.d" "$T/root/etc/apt/preferences.d" \
    "$T/root/var/lib/apt/lists/partial" "$T/root/var/cache/apt/archives/partial" "$T/root/var/lib/dpkg"
: > "$T/root/var/lib/dpkg/status"
for p in nvidia-driver:620.70.06-1 libglx-nvidia0:620.70.06-1 cuda-toolkit:13.0.1-1 dkms:9.9-1; do
    printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: t\nFilename: ./x.deb\nSize: 1\nDescription: t\n\n' "${p%%:*}" "${p#*:}"
done > "$R/Packages"
( cd "$R" && apt-ftparchive -o APT::FTPArchive::Release::Origin=NVIDIA release . > Release )
printf 'Types: deb\nURIs: file:%s/\nSuites: /\nTrusted: yes\n' "$R" > "$T/root/etc/apt/sources.list.d/nv.sources"
cp "$T/apt/preferences.d/sg-nvidia.pref" "$T/root/etc/apt/preferences.d/" 2>/dev/null
A="-o Dir=$T/root -o Dir::State::status=$T/root/var/lib/dpkg/status -o Debug::NoLocking=1 -o APT::Architecture=amd64 -o APT::Sandbox::User=$(id -un)"
# shellcheck disable=SC2086
apt-get $A update >/dev/null 2>&1
cand() { apt-cache $A policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }'; }   # shellcheck disable=SC2086
[ "$(cand nvidia-driver)" = 620.70.06-1 ] && [ "$(cand libglx-nvidia0)" = 620.70.06-1 ] \
    && pass "apt takes NVIDIA's driver packages from it" || fail "driver candidates: '$(cand nvidia-driver)' '$(cand libglx-nvidia0)'"
[ "$(cand cuda-toolkit)" = "(none)" ] && [ "$(cand dkms)" = "(none)" ] \
    && pass "...and never anything else of it (CUDA, its dkms)" || fail "pinned out: cuda '$(cand cuda-toolkit)' dkms '$(cand dkms)'"

echo
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
