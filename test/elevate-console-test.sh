#!/bin/sh
# An elevated console program (PowerShell, cmd) gets a console window: it is
# started through wineconsole, a GUI program as it is. Started by `wine` with
# no console to inherit, pwsh ran with nowhere to show, read end-of-file and
# ended -- "nothing appears after consent". sg-elevated-run finds the program
# in the prefix (Windows paths are case-insensitive) and reads its PE
# subsystem. A fake prefix holds a console and a GUI program.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
cat > "$T/driver.c" <<EOC
#define main elevated_run_main
#include "$HERE/broker/sg-elevated-run.c"
#undef main
int main(int argc, char **argv) { int i; for (i = 1; i < argc; i++) printf("%s=%d\n", argv[i], is_console_program(argv[i])); return 0; }
EOC
cc -O1 -o "$T/driver" "$T/driver.c" 2>"$T/cc.log" || { echo "SKIP: cannot build the driver"; cat "$T/cc.log"; exit 77; }
# a PE header: MZ, e_lfanew = 0x80, "PE\0\0", Subsystem at 0x80 + 24 + 68
pe() { python3 -c "
import sys
b = bytearray(0x200); b[0:2] = b'MZ'; b[0x3c] = 0x80; b[0x80:0x84] = b'PE\0\0'
b[0x80 + 24 + 68] = int(sys.argv[2]); open(sys.argv[1], 'wb').write(b)" "$1" "$2"; }
P="$T/prefix"; mkdir -p "$P/drive_c/Program Files/PowerShell/7" "$P/drive_c/windows/system32" "$P/dosdevices"
ln -s ../drive_c "$P/dosdevices/c:"
pe "$P/drive_c/Program Files/PowerShell/7/pwsh.exe" 3
pe "$P/drive_c/windows/system32/cmd.exe" 3
pe "$P/drive_c/windows/system32/control.exe" 2
printf 'not a program' > "$P/drive_c/windows/system32/notes.exe"
out=$(WINEPREFIX="$P" "$T/driver" 'C:\Program Files\PowerShell\7\pwsh.exe' 'c:\PROGRAM FILES\powershell\7\PWSH.EXE' \
      'C:\windows\system32\control.exe' cmd.exe cmd control 'C:\windows\system32\notes.exe' 'C:\missing\x.exe' 'D:\x.exe')
printf "%s\n" "$out" | sed 's/^/      /'
v() { printf "%s\n" "$out" | grep -F -x "$1=$2" >/dev/null; }
v 'C:\Program Files\PowerShell\7\pwsh.exe' 1 && pass "PowerShell is a console program" || fail "pwsh"
v 'c:\PROGRAM FILES\powershell\7\PWSH.EXE' 1 && pass "found whatever the case of its path" || fail "case-insensitive lookup"
v 'C:\windows\system32\control.exe' 0 && pass "Control Panel is not (no console window for it)" || fail "control.exe"
{ v cmd.exe 1 && v cmd 1 && v control 0; } && pass "a bare name is looked for in system32" || fail "bare names"
{ v 'C:\windows\system32\notes.exe' 0 && v 'C:\missing\x.exe' 0 && v 'D:\x.exe' 0; } \
    && pass "not a program, not there, no such drive: started as given" || fail "fallbacks"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
