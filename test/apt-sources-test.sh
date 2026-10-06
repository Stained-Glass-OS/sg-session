#!/bin/sh
# Gate for lib/sg-apt-sources and the updater's use of it, with the real apt
# against a scratch apt root and local signed repositories (no network):
#  1. one repository twice with different Signed-By (SG Store's mozilla.list
#     and Mozilla's own instructions' line, David's VM 2026-10-06): apt cannot
#     read its sources -> heal -> `apt-get update` works, one entry remains,
#     the change is logged and the old file backed up
#  2. the same with Mozilla's deb822 mozilla.sources beside our .list
#  3. SG Store's adopt: the repository already there (a user's .sources) ->
#     ours is not added and update works; there with its keyring gone -> ours
#     replaces it
#  4. a vendor key that expired / was rotated: update of the others still
#     works and `problems` names the vendor and why
#  5. a malformed third-party line: turned off, the rest read
# Mutants: --mutant (SG_MUTANT=NO_HEAL: heal does nothing), --mutant-problems
# (SG_MUTANT=NO_PROBLEMS: problems reports nothing) -- each must fail the gate.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$HERE/lib/sg-apt-sources"
case "${1:-}" in --mutant-problems) export SG_MUTANT=NO_PROBLEMS ;; --mutant) export SG_MUTANT=NO_HEAL ;; esac
for t in apt-get apt-ftparchive gpg python3; do
    command -v $t >/dev/null 2>&1 || { echo "SKIP  $t missing"; exit 77; }
done
T=$(mktemp -d /var/tmp/sg-apt-sources-test.XXXXXX); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

export GNUPGHOME="$T/gnupg"; mkdir -m 700 "$GNUPGHOME"
key() {     # NAME [gpg options]: a signing key, exported to $T/NAME.asc
    _n=$1; shift
    gpg -q --batch "$@" --passphrase '' --quick-gen-key "$_n <$_n@example.invalid>" ed25519 sign "${EXPIRE:-never}" 2>/dev/null
    gpg -q --batch --armor --export "$_n@example.invalid" > "$T/$_n.asc"
}
repo() {    # DIR KEYNAME [gpg options]: a signed repository with one package list
    mkdir -p "$1/dists/stable/main/binary-amd64" "$1/dists/stable/main/binary-all"
    printf 'Package: sg-canary-%s\nVersion: 1.0\nArchitecture: all\nFilename: pool/x.deb\nSize: 1\nDescription: x\n\n' "$2" \
        > "$1/dists/stable/main/binary-amd64/Packages"
    : > "$1/dists/stable/main/binary-all/Packages"
    _d=$1 _k=$2; shift 2
    (cd "$_d/dists/stable" && apt-ftparchive -o APT::FTPArchive::Release::Suite=stable \
        -o APT::FTPArchive::Release::Architectures="amd64 all" -o APT::FTPArchive::Release::Components=main release . > Release &&
     gpg -q --batch "$@" --yes --local-user "$_k@example.invalid" --clearsign -o InRelease Release 2>/dev/null)
}
key vendor; key rotated
OLD="--faked-system-time 20200101T000000"
# the machine's copy of a vendor key whose expiry the vendor has since
# extended (the usual "EXPKEYSIG" after a key's yearly renewal)
EXPIRE=1y key expired $OLD
fpr=$(gpg --batch --with-colons --list-keys expired@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
gpg -q --batch --passphrase '' --quick-set-expire "$fpr" 0 2>/dev/null
repo "$T/repo-vendor" vendor
repo "$T/repo-other" rotated
repo "$T/repo-exp" expired

R="$T/root"
fresh_root() {
    rm -rf "$R"
    mkdir -p "$R/etc/apt/sources.list.d" "$R/etc/apt/keyrings" "$R/usr/share/keyrings" "$R/var/lib/apt/lists/partial" \
        "$R/var/cache/apt/archives/partial" "$R/var/lib/dpkg" "$R/etc/apt/preferences.d" "$R/etc/apt/apt.conf.d" "$R/etc/apt/trusted.gpg.d"
    : > "$R/var/lib/dpkg/status"
    cp "$T/vendor.asc" "$R/usr/share/keyrings/packages.vendor.asc"
    cp "$T/vendor.asc" "$R/etc/apt/keyrings/packages.vendor.asc"
    cp "$T/rotated.asc" "$R/usr/share/keyrings/other.asc"
    printf 'Dir "%s/";\nDir::Bin::Methods "/usr/lib/apt/methods/";\nDir::Etc::main "/dev/null";\nDebug::NoLocking "1";\nAPT::Sandbox::User "%s";\n' \
        "$R" "$(id -un)" > "$R/apt.conf"
}
export APT_CONFIG="$T/root/apt.conf" SG_APT_ROOT="$T/root"
# the keyrings as entries name them: absolute paths inside the scratch root
K="$R/usr/share/keyrings/packages.vendor.asc" UK="$R/etc/apt/keyrings/packages.vendor.asc"
update() { apt-get update -q 2>&1; }
read_ok() { apt-cache policy >/dev/null 2>"$T/err" && ! grep -q '^E:' "$T/err"; }
has_pkg() { apt-cache show "sg-canary-$1" >/dev/null 2>&1; }

# The tool resolves keyring paths under SG_APT_ROOT, apt reads them as given:
# entries here name the absolute scratch paths, and the tool's root is / for
# the keyring check ("rooted" of an absolute path inside $R is that path).
heal() { SG_APT_ROOT="$R" python3 "$TOOL" heal; }

# ---- 1: a .list with our line and Mozilla's appended one
fresh_root
{ echo "deb [signed-by=$K] file:$T/repo-vendor stable main"
  echo "deb [signed-by=$UK] file:$T/repo-vendor stable main"; } > "$R/etc/apt/sources.list.d/mozilla.list"
echo "deb [signed-by=$R/usr/share/keyrings/other.asc] file:$T/repo-other stable main" > "$R/etc/apt/sources.list.d/other.list"
if read_ok; then fail "case 1 setup: apt read conflicting sources"; else
    grep -q "Conflicting values set for option Signed-By" "$T/err" && pass "case 1: apt refuses the duplicate repository (as on David's VM)" \
        || fail "case 1 setup: unexpected apt error: $(cat "$T/err")"; fi
out=$(heal 2>&1)
if read_ok && update >/dev/null && has_pkg vendor && has_pkg rotated; then
    pass "case 1: healed; apt-get update works, both repositories' packages are there"
else fail "case 1: still broken after heal: $(cat "$T/err") / $out"; fi
n=$(grep -c '^deb ' "$R/etc/apt/sources.list.d/mozilla.list")
[ "$n" = 1 ] && pass "case 1: one entry left enabled, the repeat commented out" || fail "case 1: $n enabled entries left"
printf '%s\n' "$out" | grep -q "mozilla.list:2" && pass "case 1: what changed is logged" || fail "case 1: no log of the change: $out"
ls "$R/var/backups/sg-apt-sources/"mozilla.list.* >/dev/null 2>&1 && pass "case 1: the original is backed up" || fail "case 1: no backup"
out2=$(heal 2>&1)
[ -z "$out2" ] && pass "case 1: a second heal changes nothing" || fail "case 1: second heal not idempotent: $out2"

# ---- 2: our .list and Mozilla's deb822 .sources
fresh_root
echo "deb [signed-by=$K] file:$T/repo-vendor stable main" > "$R/etc/apt/sources.list.d/mozilla.list"
printf 'Types: deb\nURIs: file:%s/repo-vendor/\nSuites: stable\nComponents: main\nSigned-By: %s\n' "$T" "$UK" > "$R/etc/apt/sources.list.d/mozilla.sources"
read_ok && fail "case 2 setup: apt read conflicting sources"
heal >/dev/null 2>&1
if read_ok && update >/dev/null && has_pkg vendor; then pass "case 2: .list + deb822 .sources conflict healed, update works"
else fail "case 2: still broken: $(cat "$T/err")"; fi

# ---- 3: SG Store adopt
fresh_root
printf 'Types: deb\nURIs: file:%s/repo-vendor\nSuites: stable\nComponents: main\nSigned-By: %s\n' "$T" "$UK" > "$R/etc/apt/sources.list.d/mozilla.sources"
echo "deb [signed-by=$K] file:$T/repo-vendor stable main" > "$T/mozilla.list"
out=$(SG_APT_ROOT="$R" python3 "$TOOL" adopt "$T/mozilla.list" 2>&1)
if [ ! -e "$R/etc/apt/sources.list.d/mozilla.list" ] && printf '%s\n' "$out" | grep -q '^reuse ' && read_ok && update >/dev/null && has_pkg vendor; then
    pass "case 3: the Store reuses the repository already configured (no second entry); update works"
else fail "case 3: adopt added a second entry or broke apt: $out / $(cat "$T/err")"; fi
rm "$R/etc/apt/keyrings/packages.vendor.asc"
out=$(SG_APT_ROOT="$R" python3 "$TOOL" adopt "$T/mozilla.list" 2>&1)
if [ -e "$R/etc/apt/sources.list.d/mozilla.list" ] && grep -q '^Enabled: no' "$R/etc/apt/sources.list.d/mozilla.sources" && read_ok && update >/dev/null && has_pkg vendor; then
    pass "case 3: an existing entry whose keyring is gone is replaced by the Store's"
else fail "case 3: keyring-less entry not replaced: $out / $(cat "$T/err")"; fi

# ---- 4: an expired vendor key and a rotated one: the rest still updates, both reported
fresh_root
cp "$T/expired.asc" "$R/usr/share/keyrings/exp.asc"
echo "deb [signed-by=$R/usr/share/keyrings/exp.asc] file:$T/repo-exp stable main" > "$R/etc/apt/sources.list.d/exp.list"
echo "deb [signed-by=$K] file:$T/repo-other stable main" > "$R/etc/apt/sources.list.d/rot.list"   # signed by another key now
echo "deb [signed-by=$K] file:$T/repo-vendor stable main" > "$R/etc/apt/sources.list.d/good.list"
uo=$(update)
probs=$(printf '%s\n' "$uo" | python3 "$TOOL" problems)
if has_pkg vendor; then pass "case 4: a bad vendor key does not stop the other repositories updating"
else fail "case 4: good repository not updated: $uo"; fi
if printf '%s\n' "$probs" | grep -q "repo-exp.*expired"; then
    pass "case 4: the expired key is reported ($(printf '%s' "$probs" | grep expired | head -1))"
else fail "case 4: expired key not reported: '$probs' from: $uo"; fi
if [ "$(printf '%s\n' "$probs" | grep -c .)" -ge 2 ]; then pass "case 4: the rotated key is reported too"
else fail "case 4: rotated key not reported: '$probs'"; fi

# ---- 5: a malformed third-party line
fresh_root
{ echo "deb [signed-by=$K] file:$T/repo-vendor stable main"; echo "deb [broken"; } > "$R/etc/apt/sources.list.d/bad.list"
read_ok && fail "case 5 setup: apt read a malformed line"
heal >/dev/null 2>&1
if read_ok && update >/dev/null && has_pkg vendor; then pass "case 5: a malformed line is turned off, the rest read"
else fail "case 5: still unreadable: $(cat "$T/err")"; fi

# ---- the updater: heals before refreshing, publishes the problems, goes on
fresh_root
{ echo "deb [signed-by=$K] file:$T/repo-vendor stable main"
  echo "deb [signed-by=$UK] file:$T/repo-vendor stable main"; } > "$R/etc/apt/sources.list.d/mozilla.list"
cp "$T/expired.asc" "$R/usr/share/keyrings/exp.asc"
echo "deb [signed-by=$R/usr/share/keyrings/exp.asc] file:$T/repo-exp stable main" > "$R/etc/apt/sources.list.d/exp.list"
mkdir -p "$T/bin" "$T/state" "$T/archives/partial"
printf '#!/bin/sh\necho "pkcon $*" >> "%s/pkcon.log"\nexit 5\n' "$T" > "$T/bin/pkcon"; chmod +x "$T/bin/pkcon"
# no dpkg repair here: an empty dpkg-query
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dpkg-query"; chmod +x "$T/bin/dpkg-query"
uout=$(PATH="$T/bin:$PATH" SG_UPDATE_STATE="$T/state" SG_APT_ARCHIVES="$T/archives" SG_SYSTEM_UPDATE="$T/system-update" \
       SG_APT_SOURCES_TOOL="$TOOL" sh "$HERE/bin/sg-update-prepare" 2>&1); urc=$?
if [ $urc = 0 ] && read_ok && has_pkg vendor && grep -q "update --only-download" "$T/pkcon.log" 2>/dev/null &&
   printf '%s\n' "$uout" | grep -q "^\[sg-update\] \[sg-apt-sources\].*mozilla.list:2"; then
    pass "sg-update-prepare heals the duplicate source (logged), refreshes and downloads"
else fail "sg-update-prepare (rc $urc) did not heal and update: $uout"; fi
if grep -q "repo-exp.*expired" "$T/state/problems" 2>/dev/null && printf '%s\n' "$uout" | grep -q "cannot use .*repo-exp"; then
    pass "sg-update-prepare publishes the expired key for Settings > Updates and logs it"
else fail "sg-update-prepare did not publish the problem: $(cat "$T/state/problems" 2>&1)"; fi
exit $RC
