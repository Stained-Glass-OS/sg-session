#!/bin/sh
# Unit test for sg_desktop_follow: a fake xwininfo replays root sizes, a fake
# wine records what it is asked; the title bars are sized to the screen first
# (--set metrics, David 2026-10-02); the desktop must be resized once per change
# of the output -- to the new size, never for an unchanged one -- and the
# watcher must stop when the session does.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/shell"
: > "$T/shell/sg-settings64.exe"
cat > "$T/bin/xwininfo" <<'W'
#!/bin/sh
s=$(head -n 1 "$Q"); [ -n "$s" ] && sed -i 1d "$Q"
[ -n "$s" ] || s=$(cat "$Q.last")
echo "$s" > "$Q.last"
printf '  Width: %s\n  Height: %s\n' "${s%x*}" "${s#*x}"
W
# (the display scale's registry reads after a change are not the desktop's)
cat > "$T/bin/wine" <<'W'
#!/bin/sh
case "$*" in *sg-settings64.exe*) echo "${*##*/}" >> "$Q.args" ;; esac
W
chmod +x "$T/bin/xwininfo" "$T/bin/wine"
printf '%s\n' 1280x800 1280x800 1920x1080 1920x1080 1920x1080 1024x768 > "$T/q"
: > "$T/q.args"
sleep 30 & SESSION=$!
# (no X server: the work area and the display scale's X resources and
# XSETTINGS, which follow a change too, are not this test's -- and never the
# real display's -- and their retries would outlast it)
( Q="$T/q" PATH="$T/bin:$PATH" SG_SHELL_DIR="$T/shell" SG_DESKTOP_WATCH_SECONDS=0.1 SG_METRICS_DELAY=0
  SG_WORKAREA_TRIES=1 XDG_RUNTIME_DIR="$T"
  export Q PATH SG_SHELL_DIR SG_DESKTOP_WATCH_SECONDS SG_METRICS_DELAY SG_WORKAREA_TRIES XDG_RUNTIME_DIR
  unset DISPLAY WAYLAND_DISPLAY
  . "$HERE/lib/sg-common.sh"; sg_desktop_follow 1280x800 "$SESSION" ) 2>/dev/null &
W=$!
sleep 2
got=$(cat "$T/q.args" | tr '\n' ' ')
RC=0
want="sg-settings64.exe --set metrics sg-settings64.exe --set desktop 1920x1080 sg-settings64.exe --set desktop 1024x768 "
if [ "$got" = "$want" ]; then echo "PASS  the title bars are sized to the screen at sign-in, and the desktop follows each output change once"
else echo "FAIL  resized: '$got' (want '$want')"; RC=1; fi
kill "$SESSION" 2>/dev/null; wait "$SESSION" 2>/dev/null
sleep 0.5
if kill -0 "$W" 2>/dev/null; then echo "FAIL  the watcher outlived the session"; kill "$W"; RC=1
else echo "PASS  the watcher ends with the session"; fi

# Over every monitor (HostMonitors=Y, wine-sg 7749) Wine follows the monitors
# itself: the desktop is not given the size of all of them as one mode (that
# made the primary monitor that wide); the scale goes by the primary monitor
# (xrandr's *: 2560x1440, 125%), not all of them (6400x2160: 200%); the
# title bars follow it (--set metrics).
cat > "$T/bin/wine" <<'W'
#!/bin/sh
case "$*" in
*sg-settings64.exe*) echo "${*##*/}" >> "$Q.args" ;;
*"reg query"*HostMonitors*) printf '    HostMonitors    REG_SZ    Y\r\n' ;;
*"reg add"*"/v LogPixels"*) echo "LogPixels ${*##*/d }" | sed 's/ \/f$//' >> "$Q.args" ;;
esac
W
cat > "$T/bin/xrandr" <<'W'
#!/bin/sh
printf 'Monitors: 2\n 0: +*XWAYLAND0 2560/600x1440/340+0+0  XWAYLAND0\n 1: +XWAYLAND1 3840/600x2160/340+2560+0  XWAYLAND1\n'
W
chmod +x "$T/bin/wine" "$T/bin/xrandr"
printf '%s\n' 1280x800 6400x2160 > "$T/q"
: > "$T/q.args"; rm -f "$T/q.last"
sleep 30 & SESSION=$!
( Q="$T/q" PATH="$T/bin:$PATH" SG_SHELL_DIR="$T/shell" SG_DESKTOP_WATCH_SECONDS=0.1 SG_METRICS_DELAY=0
  SG_WORKAREA_TRIES=1 XDG_RUNTIME_DIR="$T"
  export Q PATH SG_SHELL_DIR SG_DESKTOP_WATCH_SECONDS SG_METRICS_DELAY SG_WORKAREA_TRIES XDG_RUNTIME_DIR
  unset DISPLAY WAYLAND_DISPLAY
  . "$HERE/lib/sg-common.sh"; sg_desktop_follow 1280x800 "$SESSION" ) 2>/dev/null &
W=$!
sleep 2
got=$(cat "$T/q.args" | tr '\n' ' ')
want="sg-settings64.exe --set metrics LogPixels 120 sg-settings64.exe --set metrics "
if [ "$got" = "$want" ]; then echo "PASS  over every monitor the desktop is not resized, and the scale follows the primary monitor"
else echo "FAIL  over every monitor: '$got' (want '$want')"; RC=1; fi
kill "$SESSION" 2>/dev/null; wait "$SESSION" 2>/dev/null
sleep 0.5; kill "$W" 2>/dev/null
# A monitor that comes back (woken from sleep, plugged in again) at another
# mode of the same size gets the mode Settings kept for it again (David's
# monitor woke at 165 Hz and stayed: the desktop's size had not changed).
# wlr-randr replays: 144 Hz at sign-in, gone, back at 165 Hz, then 144 again
# (restored). Mutant SG_MUTANT_NO_MODE_RESTORE.
modecase() {
    cat > "$T/bin/wlr-randr" <<'W'
#!/bin/sh
s=$(head -n 1 "$Q.w"); [ -n "$s" ] && sed -i 1d "$Q.w"
[ -n "$s" ] || s=$(cat "$Q.w.last")
echo "$s" > "$Q.w.last"
[ "$s" = gone ] && exit 0
printf 'DP-1 "Microstep Optix AG32C (DP-1)"\n  Modes:\n    1920x1080 px, %s Hz (current)\n' "$s"
W
    cat > "$T/bin/sg-settingsctl" <<'W'
#!/bin/sh
[ "$*" = "display restore" ] && echo "restore at $(cat "$Q.w.last")" >> "$Q.restore" && echo "RESTORED DP-1	mode	1920x1080@143.99"
W
    printf '#!/bin/sh\n' > "$T/bin/wine"
    chmod +x "$T/bin/wlr-randr" "$T/bin/sg-settingsctl" "$T/bin/wine"
    printf '%s\n' 1920x1080 > "$T/q"; rm -f "$T/q.last" "$T/q.w.last"; : > "$T/q.restore"
    printf '%s\n' 143.990005 143.990005 gone gone 164.970001 143.990005 143.990005 > "$T/q.w"
    sleep 30 & SESSION=$!
    ( Q="$T/q" PATH="$T/bin:$PATH" SG_SHELL_DIR="$T/shell" SG_DESKTOP_WATCH_SECONDS=0.1 SG_METRICS_DELAY=0
      SG_WORKAREA_TRIES=1 XDG_RUNTIME_DIR="$T" WAYLAND_DISPLAY=sg-test-wl
      export Q PATH SG_SHELL_DIR SG_DESKTOP_WATCH_SECONDS SG_METRICS_DELAY SG_WORKAREA_TRIES XDG_RUNTIME_DIR WAYLAND_DISPLAY
      unset DISPLAY
      . "$HERE/lib/sg-common.sh"; sg_desktop_follow 1920x1080 "$SESSION" ) 2>/dev/null &
    W=$!
    sleep 2
    kill "$SESSION" 2>/dev/null; wait "$SESSION" 2>/dev/null
    sleep 0.5; kill "$W" 2>/dev/null
}
modecase
if grep -q "^restore at 164.970001$" "$T/q.restore" && ! grep -q "^restore at gone$" "$T/q.restore" \
    && [ "$(head -1 "$T/q.restore")" = "restore at 164.970001" ]; then
    echo "PASS  a monitor back at another mode of the same size gets its kept mode again (once it is back, not at sign-in)"
else echo "FAIL  restores: '$(tr '\n' ' ' < "$T/q.restore")'"; RC=1; fi

# Over every monitor, the same monitors placed elsewhere by another tool (wlr-randr --pos):
# the move is kept as this set's layout (display layout), not undone by putting the kept one back
# (display restore) -- wlr-randr --pos had no effect in the session. A monitor plugged in (another
# set) still gets its kept layout back. wlr-randr replays: two monitors side by side, then DP-2
# moved down 300 (the root 3840x1380), then HDMI-1 plugged in (5760x1380). Mutant
# SG_MUTANT_MOVE_UNDONE.
movecase() {
    cat > "$T/bin/wlr-randr" <<'W'
#!/bin/sh
[ $# -gt 0 ] && exit 0
s=$(head -n 1 "$Q.w"); [ -n "$s" ] && sed -i 1d "$Q.w"
[ -n "$s" ] || s=$(cat "$Q.w.last")
echo "$s" > "$Q.w.last"
for o in $s; do
    printf '%s "Monitor (%s)"\n  Enabled: yes\n  Modes:\n    1920x1080 px, 60.000000 Hz (current)\n  Position: %s\n' "${o%%=*}" "${o%%=*}" "${o#*=}"
done
W
    cat > "$T/bin/sg-settingsctl" <<'W'
#!/bin/sh
echo "$*" >> "$Q.ctl"
W
    cat > "$T/bin/wine" <<'W'
#!/bin/sh
case "$*" in *"reg query"*HostMonitors*) printf '    HostMonitors    REG_SZ    Y\r\n' ;; esac
W
    cat > "$T/bin/xrandr" <<'W'
#!/bin/sh
printf 'Monitors: 1\n 0: +*DP-1 1920/600x1080/340+0+0  DP-1\n'
W
    chmod +x "$T/bin/wlr-randr" "$T/bin/sg-settingsctl" "$T/bin/wine" "$T/bin/xrandr"
    printf '%s\n' 3840x1080 3840x1080 3840x1380 3840x1380 3840x1380 5760x1380 > "$T/q"; rm -f "$T/q.last" "$T/q.w.last"; : > "$T/q.ctl"
    printf '%s\n' "DP-1=0,0 DP-2=1920,0" "DP-1=0,0 DP-2=1920,0" "DP-1=0,0 DP-2=1920,300" "DP-1=0,0 DP-2=1920,300" \
        "DP-1=0,0 DP-2=1920,300" "DP-1=0,0 DP-2=1920,300 HDMI-1=3840,0" > "$T/q.w"
    sleep 30 & SESSION=$!
    ( Q="$T/q" PATH="$T/bin:$PATH" SG_SHELL_DIR="$T/shell" SG_DESKTOP_WATCH_SECONDS=0.1 SG_METRICS_DELAY=0
      SG_WORKAREA_TRIES=1 XDG_RUNTIME_DIR="$T" WAYLAND_DISPLAY=sg-test-wl
      export Q PATH SG_SHELL_DIR SG_DESKTOP_WATCH_SECONDS SG_METRICS_DELAY SG_WORKAREA_TRIES XDG_RUNTIME_DIR WAYLAND_DISPLAY
      unset DISPLAY
      . "$HERE/lib/sg-common.sh"; sg_desktop_follow 3840x1080 "$SESSION" ) 2>/dev/null &
    W=$!
    sleep 2
    kill "$SESSION" 2>/dev/null; wait "$SESSION" 2>/dev/null
    sleep 0.5; kill "$W" 2>/dev/null
}
movecase
ctl=$(grep -v "^display restore$" "$T/q.ctl" | head -1 | tr ' ' '\n' | sed '1,2d' | paste -sd' ' | awk '{n = split($0, a, " "); for (i = 1; i <= n; i += 3) print a[i], a[i+1], a[i+2]}' | sort | tr '\n' ';')
first=$(head -1 "$T/q.ctl")
if [ "$ctl" = "DP-1 0 0;DP-2 1920 300;" ] && [ "${first%% *}" = display ] && [ "$(echo "$first" | cut -d' ' -f2)" = layout ] \
    && [ "$(grep -c "^display restore$" "$T/q.ctl")" -ge 1 ] && [ "$(tail -1 "$T/q.ctl")" = "display restore" ]; then
    echo "PASS  monitors moved by another tool keep their places (kept as the layout); a monitor plugged in gets the kept layout back"
else echo "FAIL  move kept: calls '$(tr '\n' '|' < "$T/q.ctl")'"; RC=1; fi
exit $RC
