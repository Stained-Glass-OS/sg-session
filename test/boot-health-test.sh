#!/bin/sh
# Gate for "a start that did not finish shows the boot menu at the next one"
# (in make lint; no root, no UEFI): sg-boot-health against a stand-in bootctl
# that keeps systemd-boot's oneshot menu timeout the way the loader does (the
# loader shows the menu when it is set at a start, and forgets it).
#
#   - a start that fails (begin, never ok): the next start shows the menu;
#   - the start after that, if it succeeds (begin, ok): no menu at the one after;
#   - a good start leaves no request, start after start;
#   - not asked for on a live medium, the offline update's start, without UEFI;
#   - a boot loader that cannot be asked (not systemd-boot) is no failure;
#   - the units: begin early (before sysinit), ok after multi-user.target and
#     graphical.target, Type=simple (nothing waits for it), packaged enabled.
#
#   sh test/boot-health-test.sh [--mutant NO_BEGIN|NO_OK|UPDATE_ARMS|UNIT_ORDER|NO_WINDOW]   (a mutant must fail it)
# shellcheck disable=SC2015
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
case "${1:-}" in
    --mutant) export "SG_MUTANT_BOOTHEALTH_$2=1" ;;
esac
T=$(mktemp -d /var/tmp/sg-boot-health.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/efi"
cat > "$T/bootctl" <<'EOF'
#!/bin/sh
# set-timeout-oneshot SECONDS: the loader's LoaderConfigTimeoutOneShot; "" removes it
[ "$1" = set-timeout-oneshot ] || exit 1
[ -e "$SG_T/not-systemd-boot" ] && exit 1
if [ -n "$2" ]; then echo "$2" > "$SG_T/oneshot"; else rm -f "$SG_T/oneshot"; fi
EOF
chmod 755 "$T/bootctl"
export SG_T="$T" SG_BOOTHEALTH_BOOTCTL="$T/bootctl" SG_BOOTHEALTH_EFI="$T/efi" SG_BOOTHEALTH_CMDLINE="$T/cmdline" \
    SG_BOOTHEALTH_UPDATE="$T/system-update" SG_BOOTHEALTH_GRACE=0 SG_BOOTHEALTH_SECONDS=10
echo "BOOT_IMAGE=/vmlinuz root=PARTUUID=feed rw quiet" > "$T/cmdline"
HB="$HERE/bin/sg-boot-health"

# the loader at a start: the menu is shown if asked for, and the request is used up
menu=""
loader() { if [ -e "$T/oneshot" ]; then menu=yes; rm -f "$T/oneshot"; else menu=no; fi; }

loader; sh "$HB" begin                 # start 1: fails (no ok)
loader                                 # start 2: the menu?
[ "$menu" = yes ] && pass "after a start that did not finish: the menu is shown at the next one" || fail "no menu after a failed start"
sh "$HB" begin; sh "$HB" ok            # start 2 succeeds
loader
[ "$menu" = no ] && pass "...and not at the one after a start that succeeded" || fail "the menu again after a good start"
for n in 1 2 3; do sh "$HB" begin; sh "$HB" ok; loader; [ "$menu" = no ] || fail "good start $n: a menu"; done
[ "$menu" = no ] && pass "good starts, one after the other: never a menu"
sh "$HB" begin; loader; sh "$HB" begin; loader
[ "$menu" = yes ] && pass "starts that keep failing: the menu every time, until one succeeds" || fail "no menu after two failed starts"
[ "$(cat "$T/oneshot" 2>/dev/null)" = "" ] && pass "(the loader used the request up: nothing stays asked for between starts)" || fail "request left"

# the menu is timed (not waiting forever), and long enough to read
sh "$HB" begin
[ "$(cat "$T/oneshot")" = 10 ] && pass "the menu waits 10 seconds, then starts the default" || fail "timeout: $(cat "$T/oneshot")"
sh "$HB" ok

# starts that are not asked for
echo "BOOT_IMAGE=/vmlinuz root=live:LABEL=SG systemd.volatile=overlay sg.live=1 quiet" > "$T/cmdline"
sh "$HB" begin; [ ! -e "$T/oneshot" ] && pass "a live medium: not asked for" || fail "live medium asked for the menu"
echo "BOOT_IMAGE=/vmlinuz root=PARTUUID=feed rw quiet" > "$T/cmdline"
touch "$T/system-update"
sh "$HB" begin; [ ! -e "$T/oneshot" ] && pass "the offline update's start (ends in a restart by design): not asked for" || fail "offline update asked for the menu"
rm -f "$T/system-update"
echo "BOOT_IMAGE=/vmlinuz root=PARTUUID=feed rw systemd.unit=system-update.target" > "$T/cmdline"
sh "$HB" begin; [ ! -e "$T/oneshot" ] && pass "...by its unit on the command line too" || fail "system-update.target asked for the menu"
echo "BOOT_IMAGE=/vmlinuz root=PARTUUID=feed rw quiet" > "$T/cmdline"
SG_BOOTHEALTH_EFI="$T/no-efi" sh "$HB" begin; [ ! -e "$T/oneshot" ] && pass "without UEFI: not asked for" || fail "no-EFI asked for the menu"
touch "$T/not-systemd-boot"
sh "$HB" begin >/dev/null 2>&1 && sh "$HB" ok && pass "a boot loader that is not systemd-boot: begin and ok still succeed" || fail "not systemd-boot made begin/ok fail"
rm -f "$T/not-systemd-boot"
sh "$HB" bogus 2>/dev/null && fail "an unknown verb succeeded" || pass "an unknown verb is refused"

# the menu is reachable at every start: a hidden menu (timeout 0) looks for a held key for 0.1 s only
export SG_BOOTHEALTH_LOADERCONF="$T/loader.conf"
printf '# Stained Glass OS\ndefault debian-*\ntimeout 0\n' > "$T/loader.conf"
sh "$HB" window
grep -qx 'timeout 3' "$T/loader.conf" && grep -qxF 'default debian-*' "$T/loader.conf" \
    && pass "a machine installed with a hidden menu (timeout 0) gets 3 seconds at every start (Space or an arrow key reaches it)" || fail "window: $(cat "$T/loader.conf")"
printf '# Stained Glass OS\ndefault debian-*\ntimeout 5\n' > "$T/loader.conf"; sh "$HB" window
grep -qx 'timeout 5' "$T/loader.conf" && pass "a menu already shown (another system on the disk: 5 seconds) is left alone" || fail "timeout 5 changed"
printf 'default x\ntimeout 0\n' > "$T/loader.conf"; sh "$HB" window
grep -qx 'timeout 0' "$T/loader.conf" && pass "a loader.conf that is not ours is left alone" || fail "foreign loader.conf changed"
unset SG_BOOTHEALTH_LOADERCONF

# the units
U="$HERE/systemd"
if [ -n "${SG_MUTANT_BOOTHEALTH_UNIT_ORDER:-}" ]; then sed 's/^After=multi-user.target graphical.target$/After=multi-user.target/' "$U/sg-boot-ok.service" > "$T/ok.service"; else cp "$U/sg-boot-ok.service" "$T/ok.service"; fi
if grep -q '^After=multi-user.target graphical.target$' "$T/ok.service" && grep -q '^Type=simple$' "$T/ok.service" \
        && grep -q '^ExecStart=/usr/bin/sg-boot-health ok$' "$T/ok.service" && grep -q '^WantedBy=multi-user.target$' "$T/ok.service"; then
    pass "sg-boot-ok.service: after multi-user.target and graphical.target, Type=simple (graphical.target is not delayed)"
else fail "sg-boot-ok.service: $(cat "$T/ok.service")"; fi
if grep -q '^Before=sysinit.target$' "$U/sg-boot-health.service" && grep -q '^ExecStart=/usr/bin/sg-boot-health begin$' "$U/sg-boot-health.service" \
        && grep -q '^DefaultDependencies=no$' "$U/sg-boot-health.service" && grep -q '^ConditionKernelCommandLine=!systemd.volatile$' "$U/sg-boot-health.service" \
        && grep -q '^WantedBy=sysinit.target$' "$U/sg-boot-health.service"; then
    pass "sg-boot-health.service: early (before sysinit.target), not on a live boot"
else fail "sg-boot-health.service"; fi
grep -q '	dh_installsystemd --no-start sg-boot-health.service$' "$HERE/debian/rules" && grep -q '	dh_installsystemd --no-start sg-boot-ok.service$' "$HERE/debian/rules" \
    && grep -q 'bin/sg-boot-health' "$HERE/Makefile" && grep -q 'systemd/sg-boot-health.service' "$HERE/Makefile" \
    && pass "packaged: installed and enabled by the package (reaches installed machines by apt upgrade)" || fail "packaging"

[ $RC = 0 ] && echo "boot-health-test: PASS" || echo "boot-health-test: FAIL"
exit $RC
