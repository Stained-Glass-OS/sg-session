#!/bin/sh
# Unit test for sg-update-prepare's progress (Settings > Updates shows each
# update's download): stand-in pkcon and apt-get; while the download runs the
# published progress must show a file partly here, and at the end every file
# whole and the state "ready" (a restart installs them).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/archives/partial" "$T/state"
cat > "$T/bin/apt-get" <<'W'
#!/bin/sh
echo "'http://x/a.deb' alpha_1.0_amd64.deb 3000 SHA256:0"
echo "'http://x/b.deb' beta_2%3a1.0_all.deb 5000 SHA256:0"
W
cat > "$T/bin/pkcon" <<'W'
#!/bin/sh
case "$*" in
*"update --only-download"*)
    head -c 3000 /dev/zero > "$SG_APT_ARCHIVES/alpha_1.0_amd64.deb"
    head -c 2000 /dev/zero > "$SG_APT_ARCHIVES/partial/beta_2%3a1.0_all.deb"
    sleep 2.5
    head -c 5000 /dev/zero > "$SG_APT_ARCHIVES/beta_2%3a1.0_all.deb"; rm "$SG_APT_ARCHIVES/partial/beta_2%3a1.0_all.deb"
    echo "downloaded" ;;
*offline-trigger*) touch "$SG_SYSTEM_UPDATE" ;;
esac
exit 0
W
chmod +x "$T/bin/apt-get" "$T/bin/pkcon"
export PATH="$T/bin:$PATH" SG_UPDATE_STATE="$T/state" SG_APT_ARCHIVES="$T/archives" SG_SYSTEM_UPDATE="$T/system-update"
sh "$HERE/bin/sg-update-prepare" >/dev/null 2>&1 & P=$!
sleep 1.8
MID=$(cat "$T/state/progress" 2>/dev/null); MIDSTATE=$(cat "$T/state/state" 2>/dev/null)
wait "$P"; RC=0
if [ "$MIDSTATE" = downloading ] && printf '%s\n' "$MID" | grep -qx 'beta_2%3a1.0_all.deb 5000 2000' &&
   printf '%s\n' "$MID" | grep -qx 'alpha_1.0_amd64.deb 3000 3000'; then
    echo "PASS  while downloading: each file's bytes, a partial one counted"
else echo "FAIL  while downloading: state '$MIDSTATE', progress '$MID'"; RC=1; fi
END=$(cat "$T/state/progress"); ENDSTATE=$(cat "$T/state/state")
if [ "$ENDSTATE" = ready ] && printf '%s\n' "$END" | grep -qx 'beta_2%3a1.0_all.deb 5000 5000'; then
    echo "PASS  when done: every file whole, ready for a restart"
else echo "FAIL  when done: state '$ENDSTATE', progress '$END'"; RC=1; fi
exit $RC
