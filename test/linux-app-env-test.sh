#!/bin/sh
# Linux programs are started on X11 (lib/sg-common.sh sg_linux_app_env,
# called by sg-session-start). A native Wayland toplevel is shown full screen
# over the taskbar (GNOME Calculator from SG Store's Open, D-Bus-activated),
# so GTK, Qt, SDL, Firefox and Electron are told to use X11 in the session's
# environment, the user's systemd manager and D-Bus activation. With
# stand-ins for systemctl and dbus-update-activation-environment that record
# what they are given. Mutant: the function does nothing.
# Electron 39+ ignores ELECTRON_OZONE_PLATFORM_HINT and goes by
# XDG_SESSION_TYPE, which the compositor (wlroots) sets to wayland for what it
# starts: the Claude desktop app came up native Wayland, over the taskbar,
# with no button (David 2026-10-06). So the session type is x11 for them, set
# again inside the compositor (sg-run-explorer). Mutant SESSION_TYPE: not set.
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
for kv in GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SDL_VIDEODRIVER=x11 SDL_VIDEO_DRIVER=x11 MOZ_ENABLE_WAYLAND=0 ELECTRON_OZONE_PLATFORM_HINT=x11 XDG_SESSION_TYPE=x11; do
    grep -qx "$kv" "$T/env" || { ok=0; fail "not exported: $kv"; }
done
[ $ok = 1 ] && pass "GTK, Qt, SDL, Firefox and Electron are told to use X11"
grep -q "^systemctl --user import-environment .*GDK_BACKEND.*QT_QPA_PLATFORM" "$T/calls" 2>/dev/null &&
    pass "and the user's systemd manager gets them" || fail "systemctl calls: $(cat "$T/calls" 2>/dev/null)"
grep -q "^dbus-update-activation-environment .*GDK_BACKEND" "$T/calls" 2>/dev/null &&
    pass "and D-Bus activation (D-Bus-activated apps such as GNOME Calculator)" || fail "dbus calls: $(cat "$T/calls" 2>/dev/null)"
awk '/sg-common.sh"$/{c=NR} /^sg_linux_app_env$/{if (c && NR > c) f=1} END{exit !f}' "$HERE/bin/sg-session-start" &&
    pass "sg-session-start calls it" || fail "sg-session-start does not call sg_linux_app_env"
# Chromium's choice ("auto", Electron 39+): wayland when XDG_SESSION_TYPE is
# wayland. The compositor runs sg-run-explorer with it so; what the shell
# starts must not have it.
chromium_platform() { # the environment file -> wayland | x11
    if grep -qx XDG_SESSION_TYPE=wayland "$1"; then echo wayland
    elif grep -qx XDG_SESSION_TYPE=x11 "$1"; then echo x11
    elif grep -q '^WAYLAND_DISPLAY=' "$1"; then echo wayland
    else echo x11; fi
}
explorer_env() { # LIB -> the environment sg-run-explorer's programs get, the compositor's on entry
    sed -n '1,/^sg_linux_app_env$/p' "$HERE/lib/sg-run-explorer" | grep -v '^set -eu$' |
        sed 's/^sg_wine_env$/:/' > "$T/prelude.sh"
    echo 'env' >> "$T/prelude.sh"
    env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" SG_LIB="$1" DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 \
        XDG_SESSION_TYPE=wayland sh "$T/prelude.sh" > "$T/xenv" 2>/dev/null
}
mkdir -p "$T/lib"; cp "$HERE/lib/sg-common.sh" "$T/lib/"
explorer_env "$T/lib"
[ "$(chromium_platform "$T/xenv")" = x11 ] && grep -q '^WAYLAND_DISPLAY=wayland-0$' "$T/xenv" &&
    pass "what the shell starts (Start, SG Store's Run) gets XDG_SESSION_TYPE=x11: Electron 39+ opens on X11; WAYLAND_DISPLAY stays for the compositor's helpers" ||
    fail "sg-run-explorer's programs: $(grep -E '^(XDG_SESSION_TYPE|WAYLAND_DISPLAY)=' "$T/xenv" | tr '\n' ' ')"
grep -q "^systemctl --user import-environment .*XDG_SESSION_TYPE" "$T/calls" 2>/dev/null &&
    pass "and from inside the compositor, the user's systemd manager and D-Bus get it too" || fail "no import from sg-run-explorer: $(cat "$T/calls" 2>/dev/null)"
# mutant SESSION_TYPE: the session type left out
sed 's/ XDG_SESSION_TYPE=x11"/"/' "$HERE/lib/sg-common.sh" > "$T/lib/sg-common.sh"
explorer_env "$T/lib"
[ "$(chromium_platform "$T/xenv")" = wayland ] && pass "MUTANT SESSION_TYPE: Electron would open on Wayland (test catches it)" ||
    fail "MUTANT SESSION_TYPE not detected"
# mutant: the function does nothing
sed '/^sg_linux_app_env() {/,/^}/c\sg_linux_app_env() { :; }' "$HERE/lib/sg-common.sh" > "$T/mut.sh"
check "$T/mut.sh"
grep -qx GDK_BACKEND=x11 "$T/env" && fail "MUTANT NOENV not detected" || pass "MUTANT NOENV leaves the apps on Wayland (test catches it)"
exit $RC
