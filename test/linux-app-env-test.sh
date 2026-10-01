#!/bin/sh
# Linux programs are started on X11 (lib/sg-common.sh sg_linux_app_env,
# called by sg-session-start). A native Wayland toplevel is shown full screen
# over the taskbar (GNOME Calculator from SG Store's Open, D-Bus-activated),
# so GTK, Qt, SDL, Firefox and Electron are told to use X11 in the session's
# environment, the user's systemd manager and D-Bus activation. With
# stand-ins for systemctl and dbus-update-activation-environment that record
# what they are given. Mutant: the function does nothing.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-linux-app-env.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
for c in systemctl dbus-update-activation-environment; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$T" > "$T/bin/$c"
    chmod +x "$T/bin/$c"
done
check() { # LIB -> prints the environment the function leaves, then the calls
    rm -f "$T/calls"
    env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" SG_LIB="$HERE/lib" sh -c '. "$1"; sg_linux_app_env; env' sh "$1" > "$T/env" 2>/dev/null
}
check "$HERE/lib/sg-common.sh"
ok=1
for kv in GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SDL_VIDEODRIVER=x11 MOZ_ENABLE_WAYLAND=0 ELECTRON_OZONE_PLATFORM_HINT=x11; do
    grep -qx "$kv" "$T/env" || { ok=0; fail "not exported: $kv"; }
done
[ $ok = 1 ] && pass "GTK, Qt, SDL, Firefox and Electron are told to use X11"
grep -q "^systemctl --user import-environment .*GDK_BACKEND.*QT_QPA_PLATFORM" "$T/calls" 2>/dev/null &&
    pass "and the user's systemd manager gets them" || fail "systemctl calls: $(cat "$T/calls" 2>/dev/null)"
grep -q "^dbus-update-activation-environment .*GDK_BACKEND" "$T/calls" 2>/dev/null &&
    pass "and D-Bus activation (D-Bus-activated apps such as GNOME Calculator)" || fail "dbus calls: $(cat "$T/calls" 2>/dev/null)"
awk '/sg-common.sh"$/{c=NR} /^sg_linux_app_env$/{if (c && NR > c) f=1} END{exit !f}' "$HERE/bin/sg-session-start" &&
    pass "sg-session-start calls it" || fail "sg-session-start does not call sg_linux_app_env"
# mutant: the function does nothing
sed '/^sg_linux_app_env() {/,/^}/c\sg_linux_app_env() { :; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
check "$T/mut.sh"
grep -qx GDK_BACKEND=x11 "$T/env" && fail "MUTANT NOENV not detected" || pass "MUTANT NOENV leaves the apps on Wayland (test catches it)"
exit $RC
