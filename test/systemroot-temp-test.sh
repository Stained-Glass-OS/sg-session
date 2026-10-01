#!/bin/sh
# sg-common.sh's sg_systemroot_temp (C:\Windows\SystemTemp, SYSTEM's
# temporary folder) does not end a set -e caller when it cannot change the
# folder's owner: the image build's user namespace maps no other uid, and the
# chown -- the last command of an && list -- ended sg-prefix-init there
# ("postinst final returned 1"). Stand-ins: an id that says root and a chown
# that fails, as in the build.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/c/windows"
printf '#!/bin/sh\n[ "${1:-}" = -u ] && echo 0 || command id "$@"\n' > "$T/bin/id"
printf '#!/bin/sh\necho "chown: Invalid argument" >&2; exit 1\n' > "$T/bin/chown"
chmod +x "$T/bin/id" "$T/bin/chown"
out=$(env -i PATH="$T/bin:$PATH" sh -c "set -eu; . \"$HERE/lib/sg-common.sh\" >/dev/null 2>&1; sg_systemroot_temp \"$T/c\" sgsystem; echo after" 2>/dev/null)
RC=0
[ "$out" = after ] && echo "PASS  a chown that fails does not end a set -e caller (the image build)" || { echo "FAIL  the caller stopped: '$out'"; RC=1; }
[ -d "$T/c/windows/SystemTemp" ] && [ "$(stat -c %a "$T/c/windows/SystemTemp")" = 700 ] \
    && echo "PASS  SystemTemp is made, private (0700)" || { echo "FAIL  SystemTemp: $(stat -c %a "$T/c/windows/SystemTemp" 2>&1)"; RC=1; }
exit $RC
