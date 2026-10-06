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
  unset DISPLAY
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
exit $RC
