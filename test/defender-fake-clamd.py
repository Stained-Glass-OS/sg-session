#!/usr/bin/python3
# A stand-in for clamd, for the SG Defender tests: the same socket protocol
# (zPING, zVERSION, zFILDES with the descriptor passed) and it finds the EICAR
# test string -- never real malware.
#   defender-fake-clamd.py SOCKET LOG
#   FAKE_CLAMD_DB=FILE      the definitions' version is that file's text (a test changes it)
#   FAKE_CLAMD_DELAY=SECS   each scan takes this long (a stuck scan); FAKE_CLAMD_DELAY_FILE: from a file
# Each scan is logged: "<readlink of the descriptor> <size>".
# SPDX-License-Identifier: AGPL-3.0-or-later
import array
import os
import socket
import sys
import threading
import time

SOCK, LOG = sys.argv[1], sys.argv[2]
EICAR = b"EICAR-STANDARD-ANTIVIRUS-TEST-FILE"


def db():
    try:
        with open(os.environ["FAKE_CLAMD_DB"]) as f:
            return f.read().strip() or "1"
    except (KeyError, OSError):
        return "1"


def serve(c):
    try:
        msg, anc, _, _ = c.recvmsg(1024, socket.CMSG_SPACE(4))
        fds = []
        for lvl, typ, data in anc:
            if lvl == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
                a = array.array("i")
                a.frombytes(data)
                fds += list(a)
        cmd = msg.strip(b"z\0\n")
        if fds and msg in (b"zFILDES\0", b"nFILDES\n"):     # as clamd 1.4: a descriptor with the command itself is refused
            for fd in fds:
                os.close(fd)
            c.sendall(b"PROTOCOL ERROR: ancillary data sent without FILDES. ERROR\0")
            return
        if cmd == b"FILDES" and not fds:     # the descriptor comes next, in a message of its own
            m2, anc, _, _ = c.recvmsg(16, socket.CMSG_SPACE(4))
            for lvl, typ, data in anc:
                if lvl == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
                    a = array.array("i")
                    a.frombytes(data)
                    fds += list(a)
        if cmd == b"PING":
            out = b"PONG"
        elif cmd == b"VERSION":
            out = ("ClamAV 1.4.3/%s/test" % db()).encode()
        elif cmd == b"FILDES" and fds:
            fd = fds[0]
            data, off = b"", 0
            while True:
                b = os.pread(fd, 1 << 20, off)
                if not b:
                    break
                data += b
                off += len(b)
            try:
                where = os.readlink("/proc/self/fd/%d" % fd)
            except OSError:
                where = "?"
            with open(LOG, "a") as f:
                f.write("%s %d\n" % (where, len(data)))
            delay = float(os.environ.get("FAKE_CLAMD_DELAY", "0"))
            try:        # FAKE_CLAMD_DELAY_FILE: a delay a test sets for a while
                with open(os.environ["FAKE_CLAMD_DELAY_FILE"]) as f:
                    delay = float(f.read().strip() or 0)
            except (KeyError, OSError, ValueError):
                pass
            time.sleep(delay)
            newer = db().isdigit() and int(db()) >= 102 and b"SG-NEWSIG-TEST" in data    # a signature added later
            out = b"fd[%d]: %s" % (fd, b"Eicar-Test-Signature FOUND" if EICAR in data else
                                   b"Sg-NewSig-Test FOUND" if newer else b"OK")
        else:
            out = b"UNKNOWN COMMAND"
        for fd in fds:
            os.close(fd)
        c.sendall(out + b"\0")
    except OSError:
        pass
    finally:
        c.close()


try:
    os.unlink(SOCK)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(SOCK)
s.listen(16)
while True:
    conn, _ = s.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
