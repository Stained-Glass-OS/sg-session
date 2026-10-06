#!/bin/sh
# Later kernels get boot entries, and a bad one falls back (sg-kernel-entries).
#
# A machine Setup installed had no loader/entries.srel and no directory named
# after its entry token, so kernel-install chose layout "other" and Debian's
# kernel updates -- security updates too -- got no boot entry: installed,
# never started. Here, with the real kernel-install and bootctl on a scratch
# boot partition (a user namespace's tmpfs):
#
#   1. a new system (--configure --root): install.conf layout=bls, tries 3;
#   2. an installed machine running the image's kernel, a newer Debian kernel
#      installed without an entry, an older one too (--apply, the postinst):
#      the newer gets an entry on trial (+3) and is the default, the older
#      none, the running kernel's entry is untouched; with its tries used up
#      (+0-3) the running kernel is the default again;
#   3. a machine whose layout is set already, and a live boot: untouched;
#   4. Setup without third-party drivers (sg-drivers --platform-off --root):
#      a Surface gets hwsupport.off, a ThinkPad nothing; sg-install runs both.
#
# --mutant layout|tries|configured|newer|platformoff: must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KE="$HERE/bin/sg-kernel-entries"
DRV="$HERE/bin/sg-drivers"
MUTANT=""; [ "${1:-}" = --mutant ] && MUTANT=${2:?}
T=$(mktemp -d /var/tmp/sg-ke-test.XXXXXX); trap 'rm -rf "$T"' EXIT INT TERM
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
case "$MUTANT" in
    layout) sed '/^        printf .*layout=bls/d' "$KE" > "$T/ke" ;;
    tries) sed 's/^    \[ -s "\$ETC\/tries" \] || .*/    :/' "$KE" > "$T/ke" ;;
    configured) sed '/set already: not ours to change/d' "$KE" > "$T/ke" ;;
    newer) sed '/| sort -V | tail -1)" = "\$k" \] || continue/d' "$KE" > "$T/ke" ;;
    platformoff) sed 's/^    \[ -n "\$(platform)" \] || exit 0$/    :/' "$DRV" > "$T/drv"; DRV="$T/drv" ;;
esac
[ -f "$T/ke" ] && { chmod +x "$T/ke"; KE="$T/ke"; }
[ -z "$MUTANT" ] || [ -f "$T/ke" ] || [ -f "$T/drv" ] || { echo "unknown mutant $MUTANT"; exit 2; }

# --- 1. a new system ------------------------------------------------------------
mkdir -p "$T/new/etc"
sh "$KE" --configure --root "$T/new"
grep -qx 'layout=bls' "$T/new/etc/kernel/install.conf" 2>/dev/null && grep -qx 3 "$T/new/etc/kernel/tries" 2>/dev/null \
    && pass "a new system: kernel-install writes boot entries (layout=bls), each on trial (3 tries)" \
    || fail "a new system: $(cat "$T/new/etc/kernel/install.conf" "$T/new/etc/kernel/tries" 2>&1)"

# --- 2./3. an installed machine ------------------------------------------------------
if command -v kernel-install >/dev/null 2>&1 && command -v bootctl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
    && [ -x /usr/lib/kernel/install.d/90-loaderentry.install ] && unshare -rm true 2>/dev/null; then
    mkdir -p "$T/esp" "$T/files"
    for v in 6.12.100+deb13-amd64 6.12.111+deb13-amd64 6.12.112+deb13-amd64; do
        echo k > "$T/files/vmlinuz-$v"; echo i > "$T/files/initrd.img-$v"
    done
    cat > "$T/ki" <<EOS
#!/bin/sh
echo "\$*" >> "$T/ki.log"
SYSTEMD_RELAX_ESP_CHECKS=1 KERNEL_INSTALL_CONF_ROOT="\$SG_KE_ETC" \\
KERNEL_INSTALL_PLUGINS="/usr/lib/kernel/install.d/90-loaderentry.install $HERE/kernel/91-sg-recovery.install" \\
SG_BOOT_SPLASH="$HERE/bin/sg-boot-splash" KERNEL_INSTALL_MACHINE_ID=0123456789abcdef0123456789abcdef \\
    exec kernel-install --esp-path="$T/esp" --entry-token=literal:debian "\$@"
EOS
    chmod +x "$T/ki"
    cat > "$T/run.sh" <<EOS
set -u
mount -t tmpfs tmpfs "$T/esp" || exit 3
machine() {   # a machine Setup installed: the image's entry, its kernel running
    rm -rf "$T/esp/"* "$T/etc"; mkdir -p "$T/esp/loader/entries" "$T/esp/stained-glass/6.12.111+deb13-amd64" "$T/etc"
    printf '# Stained Glass OS\ndefault debian-*\ntimeout 0\n' > "$T/esp/loader/loader.conf"
    printf 'title Stained Glass OS\nversion 6.12.111+deb13-amd64\nlinux /stained-glass/6.12.111+deb13-amd64/vmlinuz\noptions root=PARTUUID=1 rw quiet\n' \\
        > "$T/esp/loader/entries/debian-stained-glass-6.12.111+deb13-amd64.conf"
    echo debian > "$T/etc/entry-token"; echo "root=PARTUUID=1 rw quiet" > "$T/etc/cmdline"
    : > "$T/ki.log"
}
apply() { SG_KE_ETC="$T/etc" SG_KE_BOOT="$T/esp" SG_KE_FILES="$T/files" SG_KE_UNAME=6.12.111+deb13-amd64 \\
    SG_KE_CMDLINE="$T/cmdline" SG_KE_KERNEL_INSTALL="$T/ki" sh "$KE" --apply 2>>"$T/apply.err"; }
list() { SYSTEMD_RELAX_ESP_CHECKS=1 bootctl --esp-path="$T/esp" --no-variables list --json=short > "\$1" 2>/dev/null; }

echo "root=PARTUUID=1 rw quiet splash" > "$T/cmdline"
machine
md5sum < "$T/esp/loader/entries/debian-stained-glass-6.12.111+deb13-amd64.conf" > "$T/running.sum"
apply
ls "$T/esp/loader/entries" > "$T/entries.2"; cp "$T/etc/install.conf" "$T/install.conf.2" 2>/dev/null
md5sum < "$T/esp/loader/entries/debian-stained-glass-6.12.111+deb13-amd64.conf" > "$T/running.sum2"
list "$T/list.2"
for f in "$T"/esp/loader/entries/*+3.conf; do [ -f "\$f" ] && mv "\$f" "\${f%+3.conf}+0-3.conf"; done
list "$T/list.2b"

# set already (a layout of its own): untouched
machine; printf 'layout=other\n' > "$T/etc/install.conf"
apply; ls "$T/esp/loader/entries" > "$T/entries.3"; cat "$T/etc/install.conf" > "$T/install.conf.3"; cp "$T/ki.log" "$T/ki.3"
# a live boot: untouched
machine; echo "root=LABEL=SGLIVEROOT systemd.volatile=overlay quiet" > "$T/cmdline"
apply; ls "$T/esp/loader/entries" > "$T/entries.4"; ls "$T/etc" > "$T/etc.4"
exit 0
EOS
    if unshare -rm sh "$T/run.sh"; then
        default() { python3 -c 'import json,sys; print(" ".join(e["id"] for e in json.load(open(sys.argv[1])) if e.get("isDefault")))' "$1"; }
        grep -qx 'debian-6.12.112+deb13-amd64+3.conf' "$T/entries.2" && pass "the newer Debian kernel without an entry gets one, on trial (+3)" \
            || fail "entries after the update: $(tr '\n' ' ' < "$T/entries.2") $(cat "$T/apply.err")"
        grep -q '6.12.100' "$T/entries.2" && fail "an older kernel got an entry" || pass "an older kernel gets none"
        cmp -s "$T/running.sum" "$T/running.sum2" && grep -qx 'debian-stained-glass-6.12.111+deb13-amd64.conf' "$T/entries.2" \
            && pass "the running kernel's entry is untouched" || fail "the running kernel's entry changed"
        [ "$(default "$T/list.2")" = debian-6.12.112+deb13-amd64.conf ] && pass "the new kernel is the boot loader's default" \
            || fail "default after the update: '$(default "$T/list.2")'"
        [ "$(default "$T/list.2b")" = debian-stained-glass-6.12.111+deb13-amd64.conf ] \
            && pass "with its three tries used up, the running kernel is the default again" \
            || fail "default after three failed starts: '$(default "$T/list.2b")'"
        [ "$(cat "$T/install.conf.3")" = layout=other ] && [ ! -s "$T/ki.3" ] && [ "$(wc -l < "$T/entries.3")" = 1 ] \
            && pass "a machine whose layout is set already is left alone" \
            || fail "a configured machine was changed: $(cat "$T/install.conf.3") / $(cat "$T/ki.3")"
        [ "$(wc -l < "$T/entries.4")" = 1 ] && ! grep -qx install.conf "$T/etc.4" && pass "a live boot is left alone" \
            || fail "the live boot was changed: $(tr '\n' ' ' < "$T/etc.4")"
    else fail "the scratch boot partition could not be used"; fi
else
    echo "SKIP  kernel-install, bootctl or a user namespace missing"; [ -z "$MUTANT" ] || exit 77
fi

# --- 4. Setup without third-party drivers ----------------------------------------------
for m in surface:"Microsoft Corporation":"Surface Pro 7" thinkpad:LENOVO:20XWCTO1WW; do
    n=${m%%:*}; rest=${m#*:}; d="$T/dmi-$n"; mkdir -p "$d" "$T/root-$n/etc"
    printf '%s\n' "${rest%%:*}" > "$d/sys_vendor"; printf '%s\n' "${rest#*:}" > "$d/product_name"; : > "$d/product_family"
    SG_DRIVERS_DMI="$d" sh "$DRV" --platform-off --root "$T/root-$n" 2>/dev/null
done
[ -f "$T/root-surface/etc/stained-glass/hwsupport.off" ] && pass "drivers not chosen on a Surface: its touch and pen support is off" \
    || fail "no hwsupport.off on the Surface"
[ ! -e "$T/root-thinkpad/etc/stained-glass" ] && pass "on a ThinkPad nothing is written" || fail "the ThinkPad got $(ls -R "$T/root-thinkpad/etc")"
grep -q '^    sg-drivers --platform-off --root "\$R"' "$HERE/bin/sg-install" && grep -q '^sg-kernel-entries --configure --root "\$R"' "$HERE/bin/sg-install" \
    && pass "sg-install runs both into the new system" || fail "sg-install does not run --platform-off and --configure"
exit "$RC"
