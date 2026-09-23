#!/bin/sh
# Unit test for sg_supervise_shell (multi-user debt D7): a fake `wine` replays
# exit codes, and the supervisor must restart on abnormal exits, end on a
# clean one, give up on a crash loop, and keep the geometry across restarts.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/wine" <<'W'
#!/bin/sh
echo "$*" >> "$Q.args"
code=$(head -n 1 "$Q"); sed -i 1d "$Q"; exit "${code:-0}"
W
chmod +x "$T/bin/wine"
RC=0
check() {   # name expect_rc expect_runs codes...
    _n=$1 _erc=$2 _eruns=$3; shift 3
    printf '%s\n' "$@" > "$T/q"; : > "$T/q.args"
    ( Q="$T/q" PATH="$T/bin:$PATH" SG_SHELL_MAX_RESTARTS=3 SG_SHELL_RESTART_WINDOW=60
      export Q PATH SG_SHELL_MAX_RESTARTS SG_SHELL_RESTART_WINDOW
      . "$HERE/lib/sg-common.sh"; sleep() { :; }; sg_supervise_shell 1280x800 ) 2>/dev/null
    _rc=$?; _runs=$(wc -l < "$T/q.args"); _geo=$(sort -u "$T/q.args")
    if { [ "$_erc" = nonzero ] && [ "$_rc" -ne 0 ] || [ "$_rc" = "$_erc" ]; } &&
       [ "$_runs" = "$_eruns" ] && [ "$_geo" = "explorer /desktop=shell,1280x800" ]; then
        echo "PASS  $_n"
    else
        echo "FAIL  $_n (rc=$_rc runs=$_runs geo=$_geo)"; RC=1
    fi
}
check "crashes are restarted, a clean exit ends the session" 0 3 139 1 0
check "a crash loop ends the session"                         nonzero 4 1 1 1 1 1 1
check "a clean first exit ends the session"                   0 1 0
exit $RC
