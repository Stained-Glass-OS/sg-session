#!/bin/sh
# sg-common.sh's sg_programdata_shared: C:\ProgramData is shared as Windows
# shares it -- an elevated installer (the SYSTEM account) made its folder
# there 755 and the user's program could not write in it (Epic Games
# Launcher). The folder becomes the group's and setgid; the group gets write
# on what is there (once) and, by a default ACL, on what is made later.
# And sg_system_access: the SYSTEM account may write in the shared trees
# (Program Files, ProgramData, users\Public), files made later included.
# A scratch tree, the user's own group and name standing in for the Wine group
# and the SYSTEM account.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v setfacl >/dev/null && command -v getfacl >/dev/null || { echo "SKIP: needs acl (setfacl, getfacl)"; exit 77; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
grp=$(id -gn)
mkdir -p "$T/ProgramData/Epic/Launcher" "$T/state"
chmod 755 "$T/ProgramData" "$T/ProgramData/Epic" "$T/ProgramData/Epic/Launcher"
setfacl -m "g::r-x" "$T/ProgramData/Epic" 2>/dev/null || { echo "SKIP: the file system here has no ACLs"; exit 77; }
( . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_programdata_shared "$T/ProgramData" "$grp" "$T/state" )
has() { getfacl -p "$1" 2>/dev/null | grep -qx "$2"; }
has "$T/ProgramData/Epic" "group:$grp:rwx" && echo "PASS  a folder already there: the group may write in it" || { echo "FAIL  existing folder: $(getfacl -p "$T/ProgramData/Epic" 2>/dev/null | tr '\n' ' ')"; RC=1; }
[ -g "$T/ProgramData" ] && echo "PASS  ProgramData is setgid" || { echo "FAIL  not setgid"; RC=1; }
( umask 022; mkdir "$T/ProgramData/NewApp" )
has "$T/ProgramData/NewApp" "group:$grp:rwx" && echo "PASS  a folder made later (umask 022): the group may write in it" || { echo "FAIL  new folder: $(getfacl -p "$T/ProgramData/NewApp" 2>/dev/null | tr '\n' ' ')"; RC=1; }
[ -e "$T/state/programdata-shared-1" ] && echo "PASS  the existing tree is done once (stamp)" || { echo "FAIL  no stamp"; RC=1; }
# sg_system_access
me=$(id -un)
canw() { getfacl -p "$1" 2>/dev/null | grep -qE "^user:$me:rw"; }   # an entry for the account, with write
mkdir -p "$T/c/Program Files/App" "$T/c/users/Public" "$T/st2"
: > "$T/c/Program Files/App/app.exe"
( . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_system_access "$T/c" "$me" "$T/st2" )
canw "$T/c/Program Files/App/app.exe" && echo "PASS  a file already in Program Files: the SYSTEM account may write it" || { echo "FAIL  existing file: $(getfacl -p "$T/c/Program Files/App/app.exe" 2>/dev/null | tr '\n' ' ')"; RC=1; }
( umask 022; : > "$T/c/users/Public/later.txt" )
canw "$T/c/users/Public/later.txt" && echo "PASS  a file made later in users\\Public (umask 022): the SYSTEM account may write it" || { echo "FAIL  later file: $(getfacl -p "$T/c/users/Public/later.txt" 2>/dev/null | tr '\n' ' ')"; RC=1; }
exit $RC
