#!/bin/sh
# sg-drivers chooses the right third-party drivers for the devices it sees.
#
# A fake PCI bus (SG_DRIVERS_PCI) and a stand-in for Debian's nvidia-detect
# that answers in its format: a current NVIDIA card gets nvidia-driver with
# the kernel and headers DKMS needs, a data-centre one what nvidia-detect
# says (the Tesla series), a Kepler card nothing (no driver in this release:
# nouveau stays), a PC with no NVIDIA card no NVIDIA driver at all; Wi-Fi and
# graphics firmware by vendor; Broadcom's wl only for the chips that need it.
# Without nvidia-detect the NVIDIA choice waits for it. With Secure Boot off
# there is no key enrollment. sg-image's install gate checks the real
# nvidia-detect and apt against the archive.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
D="$HERE/bin/sg-drivers"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

cat > "$T/nvidia-detect" <<'EOS'
#!/bin/sh
echo "Checking driver support for PCI ID [$1]"
case "$1" in
    10de1c82|10de2204) printf 'Your card is supported by the default drivers.\nIt is recommended to install the\n    nvidia-driver\npackage.\n'; exit 0 ;;
    10de1db4) printf 'It is recommended to install the\n    nvidia-tesla-535-driver\npackage.\n'; exit 0 ;;
    *) echo "Your card is only supported by the Tesla 470 drivers series, which is only available up to bookworm."; exit 1 ;;
esac
EOS
chmod +x "$T/nvidia-detect"
cat > "$T/pci" <<'EOS'
# slot vendor device class
0000:01:00.0 10de 1C82 030000
0000:02:00.0 10de 1180 030000
0000:03:00.0 10de 1db4 030200
0000:04:00.0 1002 73bf 030000
0000:05:00.0 8086 2723 028000
0000:06:00.0 14e4 43b1 028000
0000:07:00.0 14e4 4464 028000
0000:08:00.0 1af4 1050 030000
0000:09:00.0 10de 0e1b 040300
EOS
out=$(SG_DRIVERS_PCI="$T/pci" SG_DRIVERS_NVIDIA_DETECT="$T/nvidia-detect" sh "$D" --list)
row() { printf '%s\n' "$out" | awk -F'\t' -v s="DEVICE $1" '$1 == s { print $4 }'; }
expect() {
    if [ "$(row "$1")" = "$2" ]; then pass "$3"; else fail "$3: got '$(row "$1")'"; fi
}
expect 0000:01:00.0 "nvidia-driver firmware-misc-nonfree linux-image-amd64 linux-headers-amd64" \
    "a current NVIDIA card: nvidia-driver, its firmware, and the kernel and headers DKMS builds for"
expect 0000:02:00.0 "-" "a Kepler card: no driver in this release, nouveau stays"
expect 0000:03:00.0 "nvidia-tesla-535-driver firmware-misc-nonfree linux-image-amd64 linux-headers-amd64" \
    "a data-centre card: the series nvidia-detect names"
expect 0000:04:00.0 "firmware-amd-graphics" "AMD graphics: its firmware"
expect 0000:05:00.0 "firmware-iwlwifi" "Intel Wi-Fi: its firmware"
expect 0000:06:00.0 "broadcom-sta-dkms linux-image-amd64 linux-headers-amd64" "a Broadcom chip only wl runs: Broadcom's driver"
expect 0000:07:00.0 "firmware-brcm80211" "another Broadcom chip: brcmfmac's firmware"
if printf '%s\n' "$out" | grep -q -e 1af4:1050 -e 10de:0e1b; then fail "devices that need nothing were listed: $out"
else pass "a virtual GPU, and an NVIDIA card's audio function, need nothing"; fi

printf '0000:00:02.0 1af4 1050 030000\n' > "$T/pci-none"
if [ -z "$(SG_DRIVERS_PCI="$T/pci-none" SG_DRIVERS_NVIDIA_DETECT="$T/nvidia-detect" sh "$D" --recommended)" ]; then
    pass "a PC with nothing that needs a third-party driver gets none"
else fail "drivers recommended for a PC that needs none"; fi

out2=$(SG_DRIVERS_PCI="$T/pci" sh "$D" --list 2>/dev/null)
if [ ! -x /usr/bin/nvidia-detect ]; then
    if printf '%s\n' "$out2" | awk -F'\t' '$1 == "DEVICE 0000:01:00.0" { print $4 }' | grep -qx nvidia-detect; then
        pass "without nvidia-detect, the NVIDIA choice waits for it"
    else fail "without nvidia-detect: $out2"; fi
fi

mkdir -p "$T/root/etc"
if [ -z "$(SG_SECUREBOOT=0 sh "$D" --secure-boot-enroll --root "$T/root")" ] && [ ! -e "$T/root/var/lib/dkms/mok.key" ]; then
    pass "with Secure Boot off, no key is made or enrolled"
else fail "a key was made with Secure Boot off"; fi

exit "$RC"
