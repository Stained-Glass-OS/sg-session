#!/bin/sh
# sg-common.sh's sg_x11_workarea: Linux programs learn the screen less the
# taskbar (_NET_WORKAREA, and _NET_SUPPORTED saying so) -- without it Qt and
# GTK took the whole screen, and SG Office's editors covered the taskbar.
# _NET_SUPPORTED stays a list of atoms: the window manager's, each its own
# atom, then _NET_WORKAREA, then _GTK_FRAME_EXTENTS (GTK names its
# windows' shadows only for a window manager listing it). (xprop -set had made the whole list one atom
# named "_NET_WM_STATE, _NET_ACTIVE_WINDOW, _NET_WORKAREA": Qt saw no
# _NET_WM_MOVERESIZE, and SG Office's title bar could not be dragged.)
# On a scratch X server (Xvfb) with a window manager's _NET_SUPPORTED.
#   SG_COMMON=FILE: another sg-common.sh (the mutant's)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
COMMON=${SG_COMMON:-$HERE/lib/sg-common.sh}
for t in xvfb-run xprop python3; do command -v $t >/dev/null || { echo "SKIP: needs $t"; exit 77; }; done
unset DISPLAY WAYLAND_DISPLAY
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/run.sh" <<RUN
#!/bin/sh
. "$COMMON" >/dev/null 2>&1
# the window manager's list: two atoms, as wlroots writes its own
xprop -root -f _NET_SUPPORTED 32a -set _NET_SUPPORTED _NET_WM_STATE
sg_x11_add_supported _NET_WM_MOVERESIZE
sg_x11_workarea 1024 700 2>/dev/null
sg_x11_workarea 1024 700 2>/dev/null
xprop -root _NET_WORKAREA _NET_SUPPORTED > "$T/props"
xprop -root -f _NET_SUPPORTED 32x _NET_SUPPORTED > "$T/ids"
RUN
chmod +x "$T/run.sh"
timeout 60 xvfb-run -a -s '-noreset -screen 0 1024x700x24' "$T/run.sh"
RC=0
grep -qx '_NET_WORKAREA(CARDINAL) = 0, 0, 1024, 660' "$T/props" && echo "PASS  _NET_WORKAREA is the screen less the 40 px bar" ||
    { echo "FAIL  work area: $(cat "$T/props")"; RC=1; }
grep -qx '_NET_SUPPORTED(ATOM) = _NET_WM_STATE, _NET_WM_MOVERESIZE, _NET_WORKAREA, _GTK_FRAME_EXTENTS' "$T/props" &&
    echo "PASS  _NET_SUPPORTED says so, once, after what the window manager said -- and _GTK_FRAME_EXTENTS, for GTK's own title bars" ||
    { echo "FAIL  supported: $(grep SUPPORTED "$T/props")"; RC=1; }
n=$(sed -n 's/^_NET_SUPPORTED(ATOM) = //p' "$T/ids" | tr ',' '\n' | grep -c .)
[ "$n" = 4 ] && echo "PASS  each is an atom of its own (4), not one atom named after the list" ||
    { echo "FAIL  atoms in the list: $n ($(cat "$T/ids"))"; RC=1; }
exit $RC
