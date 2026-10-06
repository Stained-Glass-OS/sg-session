#!/bin/sh
# A Microsoft Surface gets its touch screen and pen support; no other PC is
# touched (sg-drivers --install-platform, sg-hwsupport.service,
# kernel/90-sg-boot-tries.install).
#
# 1. The survey, from fake DMI tables (SG_DRIVERS_DMI): a Surface Pro 7 and a
#    Surface Go (by family) are offered the linux-surface kernel, iptsd and
#    libwacom; a ThinkPad and a Hyper-V virtual machine (also "Microsoft
#    Corporation") are not; the Surface packages are not in --recommended
#    (they have their own installer).
# 2. --install-platform with apt stood in: on the Surface, the archive's
#    source (Signed-By our key) and pin are written, kernel-install is told
#    to make boot entries, apt installs the three packages; on the ThinkPad,
#    Hyper-V, a Surface whose owner said no (hwsupport.off) and one whose
#    boot partition is too full, nothing is written and apt is not run.
#    Installed already: only the older Surface kernels are removed, never the
#    running or the newest.
# 3. The real apt, offline, on the real archive's signed index (fixtures:
#    its InRelease and Packages as published): the source and pin as
#    written verify with the key we ship (fingerprint 87DE FA4A ... AC42 1453)
#    and leave the archive only the kernel, iptsd and libwacom -- its other
#    packages (surface-control, the Secure Boot key package) are never
#    candidates.
# 4. Boot entries, by the real kernel-install and bootctl on a scratch ESP:
#    the Surface kernel's entry counts its tries (+3) and is the boot
#    loader's default beside the stock kernel; with its tries used up the
#    stock kernel is the default again; a Debian kernel gets no counting.
# 5. sg-hwsupport.service's ConditionFirmware parses, and is false here.
#
#    While it is on trial it has no recovery-mode twin (91-sg-recovery,
#    sg-boot-splash): the twin, uncounted, sorted first and was the default
#    (seen in a VM with a Surface's DMI), and stayed it after failures.
#
# --mutant dmi|pin|key|tries|twin: the check each part guards, broken; must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
D="$HERE/bin/sg-drivers"
PLUGIN="$HERE/kernel/90-sg-boot-tries.install"
RECOVERY="$HERE/kernel/91-sg-recovery.install"
SPLASH="$HERE/bin/sg-boot-splash"
KEY="$HERE/config/keyrings/linux-surface.gpg"
FIX="$HERE/test/fixtures/linux-surface"
FPR=87DEFA4AB94A99A4C8C3112556C464BAAC421453
MUTANT=""; [ "${1:-}" = --mutant ] && MUTANT=${2:?}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
skip() { printf 'SKIP  %s\n' "$*"; [ -z "$MUTANT" ] || exit 77; }

case "$MUTANT" in
    dmi) sed 's/^        Surface\*) ;;$/        *) ;;/' "$D" > "$T/sg-drivers"; D="$T/sg-drivers" ;;
    pin) sed 's/^Pin-Priority: -1$/Pin-Priority: 500/' "$D" > "$T/sg-drivers"; D="$T/sg-drivers" ;;
    key) KEY=/usr/share/keyrings/debian-archive-keyring.gpg ;;
    tries) sed 's/^mv -f .*/:/' "$PLUGIN" > "$T/tries.install"; chmod +x "$T/tries.install"; PLUGIN="$T/tries.install" ;;
    twin) sed '/^    if printf .*+\[0-9\]/d' "$SPLASH" > "$T/sg-boot-splash"; chmod +x "$T/sg-boot-splash"; SPLASH="$T/sg-boot-splash" ;;
esac

machine() {   # NAME VENDOR PRODUCT FAMILY
    mkdir -p "$T/dmi/$1"
    printf '%s\n' "$2" > "$T/dmi/$1/sys_vendor"
    printf '%s\n' "$3" > "$T/dmi/$1/product_name"
    printf '%s\n' "$4" > "$T/dmi/$1/product_family"
}
machine sp7 "Microsoft Corporation" "Surface Pro 7" "Surface"
machine go "Microsoft Corporation" "Microsoft Surface Go 2" "Surface"
machine thinkpad "LENOVO" "20XWCTO1WW" "ThinkPad X1 Carbon Gen 9"
machine hyperv "Microsoft Corporation" "Virtual Machine" "Virtual Machine"
printf '0000:00:02.0 1af4 1050 030000\n' > "$T/pci"
# nothing installed (dpkg-query stood in: no dkms, so no Surface headers)
mkdir -p "$T/q"; printf '#!/bin/sh\nexit 1\n' > "$T/q/dpkg-query"; chmod +x "$T/q/dpkg-query"
list() { PATH="$T/q:$PATH" SG_DRIVERS_DMI="$T/dmi/$1" SG_DRIVERS_PCI="$T/pci" sh "$D" --list 2>/dev/null; }
row() { list "$1" | awk -F'\t' '$1 == "DEVICE platform" { print $4 }'; }

# --- 1. the survey -------------------------------------------------------------
want="linux-image-surface iptsd libwacom-surface"
[ "$(row sp7)" = "$want" ] && list sp7 | grep -q 'Microsoft Surface Pro 7 touch screen and pen' \
    && pass "a Surface Pro 7 is offered the linux-surface kernel, iptsd and libwacom" || fail "Surface Pro 7: '$(list sp7)'"
[ "$(row go)" = "$want" ] && pass "a Surface Go (by its family) too" || fail "Surface Go: '$(row go)'"
[ -z "$(row thinkpad)" ] && pass "a ThinkPad is offered nothing of it" || fail "ThinkPad: '$(row thinkpad)'"
[ -z "$(row hyperv)" ] && pass "a Hyper-V virtual machine (Microsoft Corporation, not a Surface) is offered nothing" \
    || fail "Hyper-V: '$(row hyperv)'"
rec=$(PATH="$T/q:$PATH" SG_DRIVERS_DMI="$T/dmi/sp7" SG_DRIVERS_PCI="$T/pci" SG_DRIVERS_FIRMWARE_LOOKUP=/nonexistent sh "$D" --recommended 2>/dev/null)
case " $rec " in *surface*|*iptsd*) fail "the Surface packages are in --recommended: $rec" ;;
    *) pass "the third-party drivers' list leaves them to their own installer" ;; esac

# --- 2. --install-platform, apt stood in -----------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/apt-get" <<'EOS'
#!/bin/sh
echo "$*" >> "$SG_T/apt.log"
EOS
# dpkg-query: the installed packages are those in $SG_T/installed
cat > "$T/bin/dpkg-query" <<'EOS'
#!/bin/sh
f=""; for a; do case "$a" in -*|*'${'*) ;; *) f=$a ;; esac; done
case "$f" in
    *'*'*) sed -n "s/^\(linux-image-.*-surface-.*\)$/\1 install ok installed/p" "$SG_T/installed" ;;
    *) grep -qx "$f" "$SG_T/installed" 2>/dev/null && printf 'install ok installed' || exit 1 ;;
esac
EOS
chmod +x "$T/bin/"*
mkdir -p "$T/boot"
inst() {   # MACHINE [env...]: a fresh /etc and apt log, then --install-platform
    m=$1; shift
    rm -rf "$T/etc" "$T/apt" "$T/kernel"; mkdir -p "$T/etc" "$T/apt" "$T/kernel"; : > "$T/apt.log"
    env SG_T="$T" PATH="$T/bin:$PATH" SG_DRIVERS_DMI="$T/dmi/$m" SG_DRIVERS_ETC="$T/etc" SG_DRIVERS_APT="$T/apt" \
        SG_DRIVERS_KEYRING="$KEY" SG_DRIVERS_BOOT="$T/boot" SG_DRIVERS_KERNEL_ETC="$T/kernel" "$@" \
        sh "$D" --install-platform 2> "$T/inst.err"
}
: > "$T/installed"
inst sp7
src="$T/apt/sources.list.d/sg-linux-surface.sources"; pin="$T/apt/preferences.d/sg-linux-surface.pref"
if [ -f "$src" ] && grep -qx 'URIs: https://pkg.surfacelinux.com/debian' "$src" && grep -qx 'Suites: release' "$src" \
    && grep -qx "Signed-By: $KEY" "$src" && [ -f "$pin" ]; then
    pass "on the Surface: the archive's source, with our key only, and its pin"
else fail "the Surface archive's source or pin: $(cat "$src" "$pin" 2>&1) $(cat "$T/inst.err")"; fi
cp "$src" "$T/written.sources" 2>/dev/null; cp "$pin" "$T/written.pref" 2>/dev/null
grep -qx 'layout=bls' "$T/kernel/install.conf" 2>/dev/null && pass "new kernels get boot entries (kernel-install layout=bls)" \
    || fail "no layout=bls for kernel-install"
if grep -q 'update$' "$T/apt.log" && grep -q "install $want\$" "$T/apt.log"; then pass "apt installs $want"
else fail "apt: $(cat "$T/apt.log") $(cat "$T/inst.err")"; fi
for m in thinkpad hyperv; do
    inst "$m"
    if [ -z "$(find "$T/apt" "$T/kernel" -type f)" ] && [ ! -s "$T/apt.log" ]; then pass "$m: no archive, no pin, no apt, no kernel change"
    else fail "$m was changed: $(find "$T/apt" "$T/kernel" -type f) $(cat "$T/apt.log")"; fi
done
mkdir -p "$T/off"; : > "$T/off/hwsupport.off"
rm -rf "$T/apt"; mkdir -p "$T/apt"; : > "$T/apt.log"
env SG_T="$T" PATH="$T/bin:$PATH" SG_DRIVERS_DMI="$T/dmi/sp7" SG_DRIVERS_ETC="$T/off" SG_DRIVERS_APT="$T/apt" \
    SG_DRIVERS_KEYRING="$KEY" SG_DRIVERS_BOOT="$T/boot" SG_DRIVERS_KERNEL_ETC="$T/kernel" sh "$D" --install-platform 2>/dev/null
[ -z "$(find "$T/apt" -type f)" ] && [ ! -s "$T/apt.log" ] && pass "the owner said no (hwsupport.off): nothing" \
    || fail "installed despite hwsupport.off"
inst sp7 SG_DRIVERS_BOOT_ROOM_MB=999999999
[ -z "$(find "$T/apt" -type f)" ] && [ ! -s "$T/apt.log" ] && grep -q 'needs' "$T/inst.err" \
    && pass "a boot partition without room: no kernel, and it says why" || fail "too-full boot partition: $(cat "$T/apt.log")"
printf '%s\n' linux-image-surface iptsd libwacom-surface linux-image-6.18.7-surface-1 linux-image-6.19.8-surface-2 \
    linux-image-6.19.8-surface-3 > "$T/installed"
inst sp7 SG_DRIVERS_UNAME=6.19.8-surface-2
if [ "$(cat "$T/apt.log")" = "-q -y -o DPkg::Lock::Timeout=600 purge linux-image-6.18.7-surface-1" ]; then
    pass "installed already: only the older Surface kernel goes (the running and the newest stay)"
else fail "tidying: '$(cat "$T/apt.log")'"; fi

# --- 3. the real apt on the real archive's index ---------------------------------
if command -v gpg >/dev/null 2>&1; then
    got=$(gpg --batch --no-default-keyring --show-keys --with-colons "$KEY" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    [ "$got" = "$FPR" ] && pass "the key we ship is linux-surface's ($FPR)" || fail "the shipped key's fingerprint is '$got'"
else skip "gpg missing: fingerprint not checked"; fi
if command -v apt-get >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1; then
    A="$T/aptroot"; mkdir -p "$A/src" "$A/prefs" "$A/lists/partial" "$A/cache/archives/partial" "$A/etc"
    : > "$A/status"
    sed "s#^URIs: .*#URIs: file://$FIX#" "$T/written.sources" > "$A/src/sg-linux-surface.sources"
    cp "$T/written.pref" "$A/prefs/sg-linux-surface.pref"
    set -- -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$A/src" -o Dir::Etc::Preferences=/dev/null \
        -o Dir::Etc::PreferencesParts="$A/prefs" -o Dir::Etc::Parts="$A/etc" -o Dir::State::Lists="$A/lists" \
        -o Dir::State::status="$A/status" -o Dir::Cache="$A/cache" -o Debug::NoLocking=1 \
        -o APT::Sandbox::User="$(id -un)" -o Acquire::Languages=none
    apt-get "$@" update > "$A/update.log" 2>&1
    cand() { apt-cache "$@" policy "$P" 2>/dev/null | awk '/Candidate:/ { print $2; exit }'; }
    P=linux-image-surface; c1=$(cand "$@"); P=iptsd; c2=$(cand "$@"); P=libwacom-surface; c3=$(cand "$@")
    P=linux-image-6.19.8-surface-3; c4=$(cand "$@")
    if [ "$c1" = 6.19.8-surface-3 ] && [ "$c2" = 3.1.0-1 ] && [ "$c3" = 2.17.0-1 ] && [ "$c4" = 6.19.8-surface-3 ]; then
        pass "the archive's signed index verifies with our key; its kernel, iptsd and libwacom are candidates"
    else fail "candidates: '$c1' '$c2' '$c3' '$c4' ($(grep -E '^(E|W):' "$A/update.log" | head -3))"; fi
    P=surface-control; o1=$(cand "$@"); P=linux-surface-secureboot-mok; o2=$(cand "$@"); P=surface-dtx-daemon; o3=$(cand "$@")
    if [ "$o1" = "(none)" ] && [ "$o2" = "(none)" ] && [ "$o3" = "(none)" ]; then
        pass "the archive's other packages are never candidates (pinned to -1)"
    else fail "other packages of the archive are candidates: '$o1' '$o2' '$o3'"; fi
else skip "apt missing: the pin was not tried"; fi

# --- 4. boot entries -------------------------------------------------------------
if command -v kernel-install >/dev/null 2>&1 && command -v bootctl >/dev/null 2>&1 \
    && [ -x /usr/lib/kernel/install.d/90-loaderentry.install ] && unshare -rm true 2>/dev/null; then
    mkdir -p "$T/esp" "$T/kconf" "$T/k"
    echo "root=PARTUUID=00000000-0000-0000-0000-000000000001 rw quiet splash" > "$T/kconf/cmdline"
    echo "layout=bls" > "$T/kconf/install.conf"
    for v in 6.12.111+deb13-amd64 6.19.8-surface-3; do echo k > "$T/k/vmlinuz-$v"; echo i > "$T/k/initrd.img-$v"; done
    cat > "$T/esp.sh" <<EOS
set -u
mount -t tmpfs tmpfs "$T/esp" || exit 3
mkdir -p "$T/esp/loader/entries" "$T/esp/stained-glass/6.12.111+deb13-amd64"
printf '# Stained Glass OS\ndefault debian-*\ntimeout 0\n' > "$T/esp/loader/loader.conf"
# the entry Setup copies from the installation media (no sort key)
printf 'title Stained Glass OS\nversion 6.12.111+deb13-amd64\nlinux /stained-glass/6.12.111+deb13-amd64/vmlinuz\noptions root=PARTUUID=00000000-0000-0000-0000-000000000001 rw quiet\n' \
    > "$T/esp/loader/entries/debian-stained-glass-6.12.111+deb13-amd64.conf"
echo k > "$T/esp/stained-glass/6.12.111+deb13-amd64/vmlinuz"
for v in 6.12.111+deb13-amd64 6.19.8-surface-3; do
    SYSTEMD_RELAX_ESP_CHECKS=1 KERNEL_INSTALL_CONF_ROOT="$T/kconf" \
    KERNEL_INSTALL_PLUGINS="/usr/lib/kernel/install.d/90-loaderentry.install $PLUGIN $RECOVERY" SG_BOOT_SPLASH="$SPLASH" \
    KERNEL_INSTALL_MACHINE_ID=0123456789abcdef0123456789abcdef \
        kernel-install --esp-path="$T/esp" --entry-token=literal:debian add "\$v" "$T/k/vmlinuz-\$v" "$T/k/initrd.img-\$v" >/dev/null 2>&1 || exit 4
done
# the session's own pass over the entries (sg-session's postinst)
SG_ESP="$T/esp" SG_KERNEL_CMDLINE="$T/kconf/cmdline" SG_PLYMOUTHD_CONF="$T/plymouthd.conf" SG_THEME_DIR="$T/no-theme" SG_NO_INITRD=1 \
    sh "$SPLASH" apply
ls "$T/esp/loader/entries" > "$T/entries.1"
SYSTEMD_RELAX_ESP_CHECKS=1 bootctl --esp-path="$T/esp" --no-variables list --json=short > "$T/list.1" 2>/dev/null
# three failed starts: systemd-boot leaves the entry at +0-3
for f in "$T"/esp/loader/entries/*+3.conf; do [ -f "\$f" ] && mv "\$f" "\${f%+3.conf}+0-3.conf"; done
SYSTEMD_RELAX_ESP_CHECKS=1 bootctl --esp-path="$T/esp" --no-variables list --json=short > "$T/list.2" 2>/dev/null
exit 0
EOS
    if unshare -rm sh "$T/esp.sh"; then
        default() { python3 -c 'import json,sys; print(" ".join(e["id"] for e in json.load(open(sys.argv[1])) if e.get("isDefault")))' "$1"; }
        grep -qx 'debian-6.19.8-surface-3+3.conf' "$T/entries.1" && grep -qx 'debian-6.12.111+deb13-amd64.conf' "$T/entries.1" \
            && pass "the Surface kernel's entry counts its tries (+3); the Debian kernel's does not" \
            || fail "entries: $(tr '\n' ' ' < "$T/entries.1")"
        grep -qx 'debian-6.12.111+deb13-amd64-recovery.conf' "$T/entries.1" && ! grep -q 'surface.*recovery' "$T/entries.1" \
            && pass "a kernel on trial gets no recovery-mode twin yet (a Debian kernel does)" \
            || fail "recovery twins: $(tr '\n' ' ' < "$T/entries.1")"
        [ "$(default "$T/list.1")" = debian-6.19.8-surface-3.conf ] && pass "the Surface kernel is the boot loader's default" \
            || fail "default: '$(default "$T/list.1")'"
        case "$(default "$T/list.2")" in
            debian-6.12.111+deb13-amd64.conf|debian-stained-glass-6.12.111+deb13-amd64.conf)
                pass "after three failed starts the stock kernel is the default again ($(default "$T/list.2"))" ;;
            *) fail "after three failed starts the default is '$(default "$T/list.2")'" ;;
        esac
    else skip "kernel-install could not run on a scratch ESP"; fi
else skip "kernel-install, bootctl or a user namespace missing: boot entries not tried"; fi

# --- 5. the unit's condition ------------------------------------------------------
U="$HERE/systemd/sg-hwsupport.service"
cond=$(sed -n 's/^ConditionFirmware=//p' "$U")
if command -v systemd-analyze >/dev/null 2>&1 && [ -r /sys/class/dmi/id/sys_vendor ]; then
    here=$(cat /sys/class/dmi/id/sys_vendor)
    if [ "$here" != "Microsoft Corporation" ]; then
        systemd-analyze condition "ConditionFirmware=$cond" >/dev/null 2>&1 && fail "the unit's condition holds on a $here PC" \
            || pass "sg-hwsupport.service does not run on this $here PC"
        mine=$(printf '%s' "$cond" | sed "s/\"Microsoft Corporation\"/\"$here\"/")
        systemd-analyze condition "ConditionFirmware=$mine" >/dev/null 2>&1 && pass "its condition parses (with this PC's vendor, it holds)" \
            || fail "the condition does not parse: $cond"
    fi
else skip "systemd-analyze or DMI missing: the unit's condition not tried"; fi

exit "$RC"
