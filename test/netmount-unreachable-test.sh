#!/bin/sh
# shellcheck disable=SC2015  # pass/fail one-liners
# \\server\share with no file server answering (sg-netmountd): the server's
# address resolves, nothing listens for SMB -- a mistyped name, a PC that is
# off. Every mount failure was "access denied", so NET USE said "System error
# 5 has occurred. Access denied." (with a password: "The user name or
# password is incorrect."); Windows says "System error 53 has occurred. The
# network path was not found." sg-netmountd now answers ERR 113
# (EHOSTUNREACH), which ntlanman reports as ERROR_BAD_NETPATH (53), before
# trying to mount: MOUNT and LOGON, an address with nothing on the SMB port.
# Needs root and cifs-utils: run it on a Stained Glass machine or the QA VM.
#   test/netmount-unreachable-test.sh [SG_NETMOUNTD]
#   (mutant: built with -DSG_MUTANT_NO_REACH_CHECK, it must fail)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root"; exit 77; }
[ -x /usr/sbin/mount.cifs ] || [ -x /sbin/mount.cifs ] || { echo "SKIP: needs cifs-utils"; exit 77; }
ND="${1:-${SG_NETMOUNTD:-$HERE/build/sg-netmountd}}"; [ -x "$ND" ] || ND=/usr/libexec/stained-glass/sg-netmountd
[ -x "$ND" ] || { echo "SKIP: no sg-netmountd"; exit 77; }
# a port nothing listens on, on this machine's own address: refused at once
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export SG_NETMOUNTD_SMB_PORT="$PORT"
out=$("$ND" --uid 65534 MOUNT 127.0.0.1 nosuchshare 2>&1)
case "$out" in "ERR 113 "*) pass "no file server there: the network path was not found ($out)" ;; *) fail "MOUNT: $out (want ERR 113)" ;; esac
mountpoint -q /run/stained-glass-net/unc/127.0.0.1/nosuchshare 2>/dev/null && fail "something was mounted" || pass "nothing mounted"
out=$("$ND" --uid 65534 LOGON 127.0.0.1 nosuchshare someone secret 2>&1)
case "$out" in *"ERR 113 "*) pass "nor with a name and password: not called a wrong password ($out)" ;; *) fail "LOGON: $out (want ERR 113)" ;; esac
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
