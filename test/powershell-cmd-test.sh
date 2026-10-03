#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# powershell (bin/powershell): from bash, PowerShell on this account's
# Windows side; as root, the machine's as SYSTEM (David 2026-10-03: ssh in,
# su - USER, powershell, for remote help). Stand-ins for wine and runuser say
# what they were asked.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
RC=0
mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "wine $WINEPREFIX|$*"\n' > "$T/bin/wine"
printf '#!/bin/sh\necho "runuser $*"\n' > "$T/bin/runuser"
chmod +x "$T/bin/wine" "$T/bin/runuser"
run() { PATH="$T/bin:$PATH" SG_LIB="$HERE/lib" SG_TEST_UID="$1" SG_WINE_DIR=/nonexistent sh "$HERE/bin/powershell" -Command 'Get-Date'; }
u=$(run 1000)
case "$u" in "wine "*"|C:\\Program Files\\PowerShell\\7\\pwsh.exe -Command Get-Date") echo "PASS  as a user: PowerShell 7 on the account's Windows side, the arguments passed on" ;; *) echo "FAIL  user: $u"; RC=1 ;; esac
r=$(run 0)
case "$r" in "runuser -u sgsystem -- "*"/bin/powershell -Command Get-Date") echo "PASS  as root: the machine's, as SYSTEM (sgsystem)" ;; *) echo "FAIL  root: $r"; RC=1 ;; esac
exit $RC
