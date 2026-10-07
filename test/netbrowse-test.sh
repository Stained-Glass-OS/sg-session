#!/bin/sh
# shellcheck disable=SC2015,SC2016
# sg-netbrowse's share lists (File Explorer's Network folder, wine-sg 0469 and
# 1471), with a stand-in smbclient: "shares" names a computer's shared
# folders, hidden ones ($) left out; "shares2" adds each one's comment after
# a tab -- a comment holding a | or a tab kept whole on its line.
#   sh test/netbrowse-test.sh [--mutant]
# --mutant runs a copy whose shares2 drops the comment (it must fail).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d /var/tmp/sg-netbrowse.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
HELPER=$HERE/../bin/sg-netbrowse
if [ "${1:-}" = --mutant ]; then
    sed 's/print \$2 "\\t" c/print $2 "\\t"/' "$HELPER" > "$T/sg-netbrowse"
    cmp -s "$HELPER" "$T/sg-netbrowse" && { echo "mutant: no change made"; exit 0; }
    HELPER=$T/sg-netbrowse
fi
mkdir "$T/bin"
cat > "$T/bin/smbclient" <<'EOS'
#!/bin/sh
printf 'Disk|Public|Shared files for everyone\n'
printf 'Disk|Music|\n'
printf 'Disk|ADMIN$|Remote Admin\n'
printf 'IPC|IPC$|IPC Service\n'
printf 'Disk|Odd|a | in it\tand a tab\n'
printf 'Printer|Laser|Office printer\n'
EOS
chmod 755 "$T/bin/smbclient"
PATH="$T/bin:$PATH" sh "$HELPER" shares "$T/plain" SERVER1
printf 'Public\nMusic\nOdd\n' | cmp -s - "$T/plain" && pass "shares: the disk shares' names, hidden ones left out" \
    || fail "shares: $(tr '\n' '/' < "$T/plain")"
PATH="$T/bin:$PATH" sh "$HELPER" shares2 "$T/full" SERVER1
printf 'Public\tShared files for everyone\nMusic\t\nOdd\ta | in it and a tab\n' | cmp -s - "$T/full" \
    && pass "shares2: each name, a tab, its comment" || fail "shares2: $(od -c "$T/full" | head -5 | tr -s ' ')"
PATH="$T/bin:$PATH" sh "$HELPER" shares2 "$T/bad" 'bad name'
[ -f "$T/bad" ] && [ ! -s "$T/bad" ] && pass "shares2: a server name not a name gives an empty list" || fail "shares2 with a bad name"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
