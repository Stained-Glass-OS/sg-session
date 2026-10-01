#!/bin/sh
# sg-common.sh's sg_x11_workarea: Linux programs learn the screen less the
# taskbar (_NET_WORKAREA, and _NET_SUPPORTED saying so) -- without it Qt and
# GTK took the whole screen, and SG Office's editors covered the taskbar.
# On a scratch X server (Xvfb) with a window manager's _NET_SUPPORTED.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
for t in xvfb-run xprop; do command -v $t >/dev/null || { echo "SKIP: needs $t"; exit 77; }; done
unset DISPLAY WAYLAND_DISPLAY
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/run.sh" <<RUN
#!/bin/sh
xprop -root -f _NET_SUPPORTED 32a -set _NET_SUPPORTED "_NET_WM_STATE, _NET_ACTIVE_WINDOW"
. "$HERE/lib/sg-common.sh" >/dev/null 2>&1
sg_x11_workarea 1024 700 2>/dev/null
sg_x11_workarea 1024 700 2>/dev/null
xprop -root _NET_WORKAREA _NET_SUPPORTED > "$T/props"
RUN
chmod +x "$T/run.sh"
timeout 60 xvfb-run -a -s '-noreset -screen 0 1024x700x24' "$T/run.sh"
RC=0
grep -qx '_NET_WORKAREA(CARDINAL) = 0, 0, 1024, 660' "$T/props" && echo "PASS  _NET_WORKAREA is the screen less the 40 px bar" ||
    { echo "FAIL  work area: $(cat "$T/props")"; RC=1; }
grep -qx '_NET_SUPPORTED(ATOM) = _NET_WM_STATE, _NET_ACTIVE_WINDOW, _NET_WORKAREA' "$T/props" &&
    echo "PASS  _NET_SUPPORTED says so, once, beside what the window manager said" ||
    { echo "FAIL  supported: $(grep SUPPORTED "$T/props")"; RC=1; }
exit $RC
