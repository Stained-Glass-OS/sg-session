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
export SG_APT_SOURCES_TOOL=/nonexistent PATH="$T/bin:$PATH" SG_UPDATE_STATE="$T/state" SG_APT_ARCHIVES="$T/archives" SG_SYSTEM_UPDATE="$T/system-update"
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

# A cut-short installation (dpkg "interrupted"): the stuck packages are
# replaced by newer versions, the rest configured, before PackageKit runs.
R="$T/repair"; mkdir -p "$R"
cat > "$T/bin/dpkg-query" <<'W'
#!/bin/sh
case "$*" in
*Status-Abbrev*) if [ -e "$R/fixed" ]; then printf 'ii  sg-session\nii  sg-shell\n'
                 else printf 'iF  sg-session\niU  sg-shell\nii  bash\n'; fi ;;
*sg-session*) printf '0.1.0-95' ;;
*sg-shell*) printf '0.1.0-99' ;;
esac
W
cat > "$T/bin/apt-get" <<'W'
#!/bin/sh
case "$*" in
*download*) for p in "$@"; do case $p in -*|download) ;; *) echo "$p" > "${p}_new.deb" ;; esac; done ;;
*print-uris*) ;;
esac
exit 0
W
cat > "$T/bin/dpkg-deb" <<'W'
#!/bin/sh
p=$(cat "$2"); case "$3" in Package) echo "$p" ;; Version) [ "$p" = sg-session ] && echo 0.1.0-98 || echo 0.1.0-99 ;; esac
W
cat > "$T/bin/dpkg" <<'W'
#!/bin/sh
case "$*" in
--compare-versions*) [ "$2" != "$4" ]; exit ;;   # the stand-in's versions only ever go up
*" -i "*) for a in "$@"; do case $a in *.deb) cat "$a" >> "$R/installed" ;; esac; done ;;
*--configure*) [ "${SG_MUTANT:-}" = NO_CONFIGURE ] || touch "$R/fixed"; echo configure >> "$R/order" ;;
esac
exit 0
W
cat > "$T/bin/pkcon" <<'W'
#!/bin/sh
[ -e "$R/fixed" ] || { echo "E: dpkg was interrupted"; exit 7; }
echo pkcon >> "$R/order"; exit 5
W
chmod +x "$T"/bin/*
for mutant in "" NO_CONFIGURE; do
    rm -f "$R"/*
    out=$(R="$R" SG_MUTANT="$mutant" sh "$HERE/bin/sg-update-prepare" 2>&1); rc=$?
    ok=0
    [ $rc = 0 ] && [ "$(cat "$R/installed" 2>/dev/null)" = sg-session ] && [ "$(head -1 "$R/order")" = configure ] &&
        grep -q "sg-session 0.1.0-95 is superseded by 0.1.0-98" <<OUT && ok=1
$out
OUT
    if [ -z "$mutant" ]; then
        [ $ok = 1 ] && echo "PASS  an interrupted installation: the superseded package replaced, the rest configured, then updates" \
            || { echo "FAIL  interrupted dpkg not repaired (rc $rc): $out"; RC=1; }
    else
        [ $ok = 0 ] && echo "PASS  MUTANT $mutant is caught" || { echo "FAIL  MUTANT $mutant survives"; RC=1; }
    fi
done
exit $RC
