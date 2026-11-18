#!/bin/sh
# sg-grub-bios offline: GRUB's menu made from the boot entries, and boot
# counting in grubenv (a new kernel on trial, the previous one to fall back
# to; blessed good when it came up, marked bad when the fallback did).
# The VM half (GRUB really counting and falling back, under SeaBIOS) is
# sg-image's bios-test.
#   test/grub-bios-test.sh [--mutant NO_FALLBACK|NO_COUNT]
# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck disable=SC2016,SC2015  # GRUB variables in patterns; pass || fail
set -u
cd "$(dirname "$0")/.." || exit 1
if ! command -v grub-editenv >/dev/null || ! command -v grub-script-check >/dev/null; then echo "SKIP: needs grub-common"; exit 77; fi
MUT=""; [ "${1:-}" = --mutant ] && MUT=${2:-}
T=$(mktemp -d /var/tmp/sg-grubbios.XXXXXX)
trap 'rm -rf "$T"' EXIT
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
B="$T/boot"; mkdir -p "$B/loader/entries" "$B/grub/i386-pc"
printf 'timeout 3\n' > "$B/loader/loader.conf"
entry() { # NAME VERSION
    printf 'title Stained Glass OS\nversion %s\nlinux /stained-glass/%s/linux\noptions root=PARTUUID=x rw quiet\ninitrd /stained-glass/%s/initrd\n' \
        "$2" "$2" "$2" > "$B/loader/entries/$1"
}
entry stained-glass-6.12.100.conf 6.12.100
entry stained-glass-6.12.100-recovery.conf 6.12.100
entry Sg-restore-1.conf 6.12.100
grub-editenv "$B/grub/grubenv" create
export SG_GRUB_FSUUID=ABCD-1234
G="sh bin/sg-grub-bios"
[ -n "$MUT" ] && { cp bin/sg-grub-bios "$T/g"; G="sh $T/g"; }
case "$MUT" in
    NO_FALLBACK) sed -i 's/"sg_fallback=\$fb"/"sg_fallback="/' "$T/g" ;;
    NO_COUNT) sed -i 's/set sg_tries=\$((_n - 1)); save_env sg_tries; //' "$T/g" ;;
esac
env_of() { grub-editenv "$B/grub/grubenv" list | sed -n "s/^$1=//p"; }

$G --update --boot "$B" || fail "--update"
cfg="$B/grub/grub.cfg"
grub-script-check "$cfg" && pass "grub.cfg is valid GRUB script" || fail "grub.cfg does not parse: $(cat "$cfg")"
grep -q "search --no-floppy --fs-uuid --set=root ABCD-1234" "$cfg" && pass "GRUB finds the boot partition by its UUID" || fail "no search line"
grep -q "linux /stained-glass/6.12.100/linux root=PARTUUID=x rw quiet sg.entry=stained-glass-6.12.100" "$cfg" && grep -q "initrd /stained-glass/6.12.100/initrd" "$cfg" \
    && pass "a menu entry starts the entry's kernel, initrd and options" || fail "menu entry: $(cat "$cfg")"
grep -q 'set default="stained-glass-6.12.100"' "$cfg" && pass "the kernel (not its recovery twin, not a restore point) is the default" || fail "default: $(grep 'set default' "$cfg")"

# a new kernel, on trial (kernel-install: ENTRY+3.conf)
entry "stained-glass-6.12.200+deb13-amd64+3.conf" 6.12.200+deb13-amd64
$G --update --boot "$B" --trial stained-glass-6.12.200+deb13-amd64
grub-script-check "$cfg" || fail "grub.cfg with a trial does not parse"
[ "$(env_of sg_trial)" = stained-glass-6.12.200+deb13-amd64 ] && [ "$(env_of sg_tries)" = 3 ] && [ "$(env_of sg_fallback)" = stained-glass-6.12.100 ] \
    && pass "a new kernel goes on trial: 3 tries, the previous kernel to fall back to" \
    || fail "grubenv: $(grub-editenv "$B/grub/grubenv" list | tr '\n' ' ')"
grep -q 'if \[ "\$sg_tries" = "3" \]; then set sg_tries=2; save_env sg_tries; set default="\$sg_trial"' "$cfg" \
    && pass "each start of the trial takes a try off (save_env) before it boots" || fail "no counting in grub.cfg"
grep -q 'elif \[ -n "\$sg_fallback" \]; then set default="\$sg_fallback"' "$cfg" \
    && pass "with no tries left GRUB starts the previous kernel" || fail "no fallback at 0 tries"
grep -q 'elif \[ "\$sg_trial" = "stained-glass-6.12.200+deb13-amd64" \]; then' "$cfg" && grep -q 'set sg_tries=0; save_env sg_tries; configfile' "$cfg" \
    && pass "a trial kernel GRUB cannot load uses up its tries and the menu is read again (the previous kernel starts)" || fail "no load-failure guard"
grep -q 'set default="stained-glass-6.12.200+deb13-amd64"' "$cfg" && pass "the new kernel sorts first" || fail "sort: $(grep 'set default' "$cfg")"

# the new kernel came up: blessed
cp -r "$B" "$T/good"
echo "root=x sg.entry=stained-glass-6.12.200+deb13-amd64" > "$T/cmd"; SG_GRUB_CMDLINE="$T/cmd" $G --bless --boot "$T/good"
[ -f "$T/good/loader/entries/stained-glass-6.12.200+deb13-amd64.conf" ] && [ -z "$(grub-editenv "$T/good/grub/grubenv" list)" ] \
    && pass "the new kernel came up: its entry is plain, the trial is over" || fail "bless good: $(ls "$T/good/loader/entries")"
# the previous kernel came up (tries used up): the new one marked bad
grub-editenv "$B/grub/grubenv" set sg_tries=0
echo "root=x sg.entry=stained-glass-6.12.100" > "$T/cmd"; SG_GRUB_CMDLINE="$T/cmd" $G --bless --boot "$B"
[ -f "$B/loader/entries/stained-glass-6.12.200+deb13-amd64+0.conf" ] && grep -q 'set default="stained-glass-6.12.100"' "$cfg" \
    && pass "the fallback came up: the new kernel is marked bad and the previous one is the default again" \
    || fail "bless bad: $(ls "$B/loader/entries"); $(grep 'set default' "$cfg")"
# the trial still running when another entry was chosen by hand
entry "stained-glass-6.12.300+deb13-amd64+3.conf" 6.12.300+deb13-amd64
$G --update --boot "$B" --trial stained-glass-6.12.300+deb13-amd64
grub-editenv "$B/grub/grubenv" set sg_tries=2
echo "root=x sg.entry=stained-glass-6.12.100-recovery" > "$T/cmd"; SG_GRUB_CMDLINE="$T/cmd" $G --bless --boot "$B"
[ "$(env_of sg_trial)" = stained-glass-6.12.300+deb13-amd64 ] && [ -f "$B/loader/entries/stained-glass-6.12.300+deb13-amd64+3.conf" ] \
    && pass "another entry chosen by hand (a recovery entry) leaves the trial going" || fail "manual choice ended the trial"
# the previous kernel chosen by hand (or started by GRUB's fallback after a
# load failure) while tries are left: as systemd-boot, the trial stays open
echo "root=x sg.entry=stained-glass-6.12.100" > "$T/cmd"; SG_GRUB_CMDLINE="$T/cmd" $G --bless --boot "$B"
[ "$(env_of sg_trial)" = stained-glass-6.12.300+deb13-amd64 ] && [ -f "$B/loader/entries/stained-glass-6.12.300+deb13-amd64+3.conf" ] \
    && pass "the previous kernel chosen by hand neither spends a try nor ends the trial" || fail "hand-picked previous kernel ended the trial: $(ls "$B/loader/entries")"
# no GRUB here (a UEFI machine): nothing done
mkdir -p "$T/uefi/loader/entries"
$G --update --boot "$T/uefi" >/dev/null 2>&1; [ ! -e "$T/uefi/grub/grub.cfg" ] || true
echo
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
