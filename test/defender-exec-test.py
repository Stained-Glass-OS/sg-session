#!/usr/bin/python3
# SG Defender on execute and its scans (bin/sg-defender's socket): what
# wine-sg asks before a program, DLL, package or script runs, and what
# sg-defender-scan starts. A stand-in clamd (defender-fake-clamd.py) finds
# the EICAR test string. As the test's own user; test/defender-root-test.sh
# runs the parts that need root (other accounts, setuid children).
#   defender-exec-test.py [--mutant NAME]   --list-mutants
# SPDX-License-Identifier: AGPL-3.0-or-later
import array
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EICAR = b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
MUTANTS = {
    # each: (what the service's source becomes, by a plain replace)
    "FDS_WITH_COMMAND": ("        s.sendall(b\"z\" + command + b\"\\0\")\n        if fd is not None:      # the descriptor after the command, in a message of its own (clamd refuses it before)\n            s.sendmsg([b\"\\0\"],",
                         "        if fd is None:\n            s.sendall(b\"z\" + command + b\"\\0\")\n        else:\n            s.sendmsg([b\"z\" + command + b\"\\0\"],"),
    "NO_CACHE": ("    if v is not None:\n        return v\n    if st.st_size > MAX_SCAN_SIZE:", "    if st.st_size > MAX_SCAN_SIZE:"),
    "CACHE_IGNORES_DB": ("if not found and db != engine[\"db\"]:", "if False:"),
    "START_WAITS": ("    v = verdicts.get(key, stale_ok=start)", "    v = verdicts.get(key, stale_ok=False)"),
    "ACCEPT_O_PATH": ("if fl & O_PATH or ", "if "),
    "TRUST_HINT": ("    where = fd_path(fd)\n    if excluded(where):", "    where = clean_hint(hint)\n    if excluded(where):"),
    "NO_REALTIME_CAP": ("    until = min(until, st.st_mtime + REALTIME_OFF_MAX)\n", ""),
    "AMSI_NOT_SCANNED": ("    if kind == \"amsi\":      # a script's text", "    if kind == \"amsi\":\n        return \"ALLOW\"\n    if kind == \"amsi\":      # a script's text"),
    "SCAN_FOLLOWS_LINKS": [("if e.is_dir(follow_symlinks=False):", "if e.is_dir():"),
                           ("elif e.is_file(follow_symlinks=False):", "elif e.is_file():"),
                           ("os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC, dir_fd=dfd)",
                            "os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC, dir_fd=dfd)"),
                           ("os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)",
                            "os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC, dir_fd=dfd)")],
    "NO_SCAN_REMOVE": ("                    os.unlink(name, dir_fd=dfd)\n                    self.sock.send(b\"R\")",
                       "                    self.sock.send(b\"K\")"),
    "NO_TASKS": ("            w.tasks(it[1])", "            pass"),
    "NO_SERVICES": (" or (n == \"imagepath\" and SERVICE_KEY.search(k))", ""),
    "NO_RUN_KEYS": ("    items = [(\"cmd\", p) for _, _, v in reg_commands(hive", "    items = [] and [(\"cmd\", p) for _, _, v in reg_commands(hive"),
}
RC = 0


def ok(cond, what):
    global RC
    print(("PASS  " if cond else "FAIL  ") + what)
    if not cond:
        RC = 1


def main():
    mutant = None
    if sys.argv[1:2] == ["--list-mutants"]:
        print("\n".join(MUTANTS))
        return 0
    if sys.argv[1:2] == ["--mutant"]:
        mutant = sys.argv[2]
    T = tempfile.mkdtemp(prefix="sgdef-")
    procs = []
    try:
        return run(T, mutant, procs)
    finally:
        for p in procs:
            p.kill()
            p.wait()
        shutil.rmtree(T, ignore_errors=True)


def run(T, mutant, procs):
    src = os.path.join(HERE, "bin", "sg-defender")
    if mutant:
        text = open(src).read()
        m = MUTANTS[mutant]
        for a, b in m if isinstance(m, list) else [m]:
            assert a in text, (mutant, a)
            text = text.replace(a, b)
        src = os.path.join(T, "mutant.py")
        with open(src, "w") as f:
            f.write(text)
    home = os.path.join(T, "home")
    me = os.environ.get("USER") or "me"
    import pwd
    me = pwd.getpwuid(os.getuid()).pw_name
    prefix = os.path.join(T, "prefix")
    drive_c = os.path.join(prefix, "drive_c")
    for d in ("Downloads", "Desktop"):
        os.makedirs(os.path.join(home, d))
    for d in ("windows/system32/tasks", "windows/syswow64", "Program Files/Maker", "ProgramData",
              "users/%s/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup" % me,
              "users/%s/AppData/Local/Temp" % me, "users/%s/AppData/Roaming/Evil" % me):
        os.makedirs(os.path.join(drive_c, d))
    os.makedirs(os.path.join(prefix, "dosdevices"))
    os.symlink("../drive_c", os.path.join(prefix, "dosdevices", "c:"))
    run_dir = os.path.join(T, "run")
    os.makedirs(run_dir)
    db = os.path.join(T, "db")
    with open(db, "w") as f:
        f.write("100")
    clog = os.path.join(T, "scanned")
    delay = os.path.join(T, "delay")
    env = dict(os.environ, FAKE_CLAMD_DB=db, FAKE_CLAMD_DELAY_FILE=delay, SG_DEFENDER_CONF=os.path.join(T, "defender.conf"),
               SG_DEFENDER_STATE=os.path.join(T, "state"), SG_DEFENDER_NOTICES=os.path.join(T, "notices"),
               SG_DEFENDER_HOMES=home, SG_DEFENDER_CLAMD=os.path.join(T, "clamd.sock"), SG_DEFENDER_RUNTIME=run_dir,
               SG_DEFENDER_EXCLUSIONS=os.path.join(T, "exclusions"), SG_DEFENDER_PREFIX=prefix,
               SG_DEFENDER_SCHEDULE_HOURS="1000", SG_DEFENDER_SCAN_TIMEOUT="2",
               SG_DEFENDER_ENGINE_CHECK="0.5")
    clamd = subprocess.Popen([sys.executable, os.path.join(HERE, "test", "defender-fake-clamd.py"), env["SG_DEFENDER_CLAMD"],
                              clog], env=env)
    procs.append(clamd)
    with open(os.path.join(T, "service.log"), "w") as lf:
        svc = subprocess.Popen([sys.executable, src], env=env, stderr=lf)
    procs.append(svc)
    sock = os.path.join(run_dir, "socket")
    for _ in range(100):
        if os.path.exists(sock) and os.path.exists(env["SG_DEFENDER_CLAMD"]):
            break
        time.sleep(0.05)
    ok(oct(os.stat(sock).st_mode & 0o777) == "0o600", "the socket is its owner's alone (as a user; root's is 0660 root:sgwine)")

    def ask(line, fd=None, timeout=10):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(sock)
        anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))] if fd is not None else []
        s.sendmsg([line.encode() + b"\n"], anc)
        data = b""
        while not data.endswith(b"\n"):
            b = s.recv(4096)
            if not b:
                break
            data += b
        s.close()
        return data.decode().strip()

    def scan(path, kind="image", hint=None, flags=os.O_RDONLY):
        fd = os.open(path, flags)
        try:
            return ask("SCAN1 %s %s" % (kind, hint if hint is not None else path), fd)
        finally:
            os.close(fd)

    def scans():
        try:
            with open(clog) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def notices():
        d = os.path.join(T, "notices", str(os.getuid()))
        out = []
        for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if n.endswith(".json") and n != "scans.json":
                with open(os.path.join(d, n)) as f:
                    out.append(json.load(f))
        return out

    w = os.path.join(T, "w")
    os.makedirs(w)
    bad, good = os.path.join(w, "setup.exe"), os.path.join(w, "tool.exe")
    with open(bad, "wb") as f:
        f.write(b"MZ" + EICAR)
    with open(good, "wb") as f:
        f.write(b"MZ clean program")

    # 1. on execute: found -> blocked, quarantined, told
    r = scan(bad)
    ok(r.startswith("BLOCK ") and r.endswith("Eicar-Test-Signature"), "an infected program is blocked (%s)" % r)
    qid = r.split()[1] if r.startswith("BLOCK") else "?"
    q = os.path.join(T, "state", "quarantine")
    ok(os.path.exists(os.path.join(q, qid + ".bin")) and open(os.path.join(q, qid + ".bin"), "rb").read() == b"MZ" + EICAR,
       "a copy of it is in the quarantine")
    n = [x for x in notices() if x["id"] == qid]
    ok(n and n[0]["how"] == "image" and n[0]["name"] == "setup.exe" and n[0]["action"] == "quarantined",
       "and its person is told (a notice: how, name, action)")
    # 2. clean, then known: one scan
    before = len(scans())
    r1, r2 = scan(good), scan(good)
    ok(r1 == "ALLOW" and r2 == "ALLOW" and len(scans()) == before + 1, "a clean program runs; the second start is not scanned again")
    r = scan(bad)
    ok(r.startswith("BLOCK"), "an infected one stays blocked at its next start")
    # 3. new definitions: a clean file is scanned again
    with open(db, "w") as f:
        f.write("101")
    time.sleep(1)       # (SG_DEFENDER_ENGINE_CHECK: the service looks at most this often)
    before = len(scans())
    with open(delay, "w") as f:      # a slow scan, as ClamAV's of a big program
        f.write("1.5")
    t = time.monotonic()
    r = scan(good)
    took = time.monotonic() - t
    time.sleep(2)
    os.unlink(delay)
    ok(r == "ALLOW" and len(scans()) == before + 1, "new definitions: a clean program starts and is scanned again")
    ok(took < 0.5, "...in the background: its start does not wait for it (%.2f s)" % took)
    # a program clean before, found by newer definitions (the stand-in knows SG-NEWSIG-TEST from 102 on):
    # that start goes on, the background scan tells its person, the next start is stopped
    turned = os.path.join(w, "turned.exe")
    with open(turned, "wb") as f:
        f.write(b"MZ turned SG-NEWSIG-TEST")
    ok(scan(turned) == "ALLOW", "a program clean under the definitions of the day runs")
    with open(db, "w") as f:
        f.write("102")
    time.sleep(1)
    ok(scan(turned) == "ALLOW", "...after new definitions its start goes on (scanned in the background)")
    time.sleep(1.5)
    ok(any(x.get("action") == "found" and x["name"] == "turned.exe" for x in notices()), "...what that scan finds is told")
    ok(scan(turned).startswith("BLOCK"), "...and its next start is stopped")
    before = len(scans())
    ok(scan(bad).startswith("BLOCK") and len(scans()) == before, "a known detection stays known")
    # 4. a changed file is scanned again
    with open(good, "ab") as f:
        f.write(b" v2")
    before = len(scans())
    ok(scan(good) == "ALLOW" and len(scans()) == before + 1, "a changed file is scanned again")
    # 5. descriptors that are not a readable regular file: never scanned (never reopened)
    before = len(scans())
    try:
        fd = os.open(bad, os.O_PATH)
        r = ask("SCAN1 image " + bad, fd)
        os.close(fd)
    except FileNotFoundError:
        r = "?"
    ok(r == "ALLOW" and len(scans()) == before, "an O_PATH descriptor is not read (root never reopens it)")
    wo = os.path.join(w, "wo.exe")
    with open(wo, "wb") as f:
        f.write(b"MZ" + EICAR)
    os.chmod(wo, 0o200)
    r = scan(wo, flags=os.O_WRONLY)
    ok(r == "ALLOW" and len(scans()) == before, "nor one opened for writing only (the caller could not read it)")
    fifo = os.path.join(w, "pipe")
    os.mkfifo(fifo)
    fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    t = time.monotonic()
    r = ask("SCAN1 image " + fifo, fd)
    os.close(fd)
    ok(r == "ALLOW" and time.monotonic() - t < 2 and len(scans()) == before, "nor a pipe (and it does not hang)")
    # 6. the caller's path is only a word: what is scanned is the descriptor
    other = os.path.join(w, "other.exe")
    with open(other, "wb") as f:
        f.write(b"MZ" + EICAR + b" other")
    r = scan(other, hint="/etc/shadow")
    ok(r.startswith("BLOCK") and scans()[-1].split()[0] == other, "the descriptor is scanned, not the path the caller names")
    # 7. exclusions (an administrator's), by where the file really is
    ex = os.path.join(T, "excl")
    os.makedirs(ex)
    ef = os.path.join(ex, "keep.exe")
    with open(ef, "wb") as f:
        f.write(b"MZ" + EICAR + b" excluded")
    with open(env["SG_DEFENDER_EXCLUSIONS"], "w") as f:
        f.write(ex + "\n")
    before = len(scans())
    ok(scan(ef) == "ALLOW" and len(scans()) == before, "a file in an excluded folder runs, unscanned")
    ok(scan(other, hint=ex + "/x.exe").startswith("BLOCK"), "a caller cannot claim an excluded folder for another file")
    os.unlink(env["SG_DEFENDER_EXCLUSIONS"])
    # 8. real-time protection off, for a while
    rt = os.path.join(run_dir, "realtime-off")
    with open(rt, "w") as f:
        f.write("%d\n" % (time.time() + 3600))
    ok(scan(bad) == "ALLOW", "real-time protection off: programs run")
    with open(rt, "w") as f:
        f.write("%d\n" % (time.time() + 10 * 3600))
    os.utime(rt, (time.time() - 5 * 3600, time.time() - 5 * 3600))
    ok(scan(bad).startswith("BLOCK"), "it comes back on by itself (at most 4 hours off)")
    os.unlink(rt)
    with open(env["SG_DEFENDER_CONF"], "w") as f:
        f.write("enabled=0\n")
    ok(scan(bad) == "ALLOW", "SG Defender off: programs run")
    os.unlink(env["SG_DEFENDER_CONF"])
    # 9. AMSI: a script's text, in a memfd
    def amsi(text, name="PowerShell_C:\\x.ps1"):
        fd = os.memfd_create("sg-defender-amsi")
        os.write(fd, text)
        try:
            return ask("SCAN1 amsi " + name, fd)
        finally:
            os.close(fd)
    before = len(scans())
    r = amsi(b"Write-Host '" + EICAR + b"'")
    ok(r.startswith("BLOCK"), "AMSI: script text with the test string is blocked")
    ok(any(x["how"] == "amsi" and x["action"] == "blocked" for x in notices()), "and told (nothing to quarantine)")
    ok(amsi(b"Write-Host hello") == "ALLOW", "AMSI: other script text is allowed")
    amsi(b"Write-Host hello")
    ok(len(scans()) == before + 2, "AMSI: the same text again is known (by its content)")
    # 10. clamd too slow or down: programs run
    clamd.kill()
    clamd.wait()
    slow = subprocess.Popen([sys.executable, os.path.join(HERE, "test", "defender-fake-clamd.py"), env["SG_DEFENDER_CLAMD"],
                             clog], env=dict(env, FAKE_CLAMD_DELAY="5"))
    procs.append(slow)
    time.sleep(0.5)
    fresh = os.path.join(w, "fresh.exe")
    with open(fresh, "wb") as f:
        f.write(b"MZ" + EICAR + b" fresh")
    t = time.monotonic()
    r = scan(fresh)
    ok(r == "ALLOW" and time.monotonic() - t < 4, "a stuck scan does not hang a start (allowed after the time limit)")
    slow.kill()
    slow.wait()
    os.unlink(env["SG_DEFENDER_CLAMD"])
    ok(scan(fresh) == "ALLOW", "clamd down: programs run")
    clamd2 = subprocess.Popen([sys.executable, os.path.join(HERE, "test", "defender-fake-clamd.py"), env["SG_DEFENDER_CLAMD"],
                               clog], env=env)
    procs.append(clamd2)
    time.sleep(0.5)

    # 11. scans: quick (Run key, Startup, a task, a service, Downloads), custom, full
    appdata = os.path.join(drive_c, "users", me, "AppData", "Roaming")
    with open(os.path.join(appdata, "Evil", "Updater.exe"), "wb") as f:
        f.write(b"MZ" + EICAR + b" run key")
    with open(os.path.join(appdata, "Microsoft/Windows/Start Menu/Programs/Startup/start.bat"), "wb") as f:
        f.write(b"@echo off\r\n" + EICAR)
    os.makedirs(os.path.join(drive_c, "Tools"))      # a folder no scan walks: found only through the task and the service
    with open(os.path.join(drive_c, "Tools/task.exe"), "wb") as f:
        f.write(b"MZ" + EICAR + b" task")
    with open(os.path.join(drive_c, "Tools/svc.exe"), "wb") as f:
        f.write(b"MZ" + EICAR + b" service")
    with open(os.path.join(drive_c, "Program Files/Maker/clean.exe"), "wb") as f:
        f.write(b"MZ fine")
    with open(os.path.join(home, "Downloads", "dl.exe"), "wb") as f:
        f.write(b"MZ" + EICAR + b" downloaded")
    with open(os.path.join(drive_c, "windows/system32/tasks/Updater"), "w", encoding="utf-16") as f:
        f.write('<?xml version="1.0"?><Task><Actions><Exec><Command>"C:\\TOOLS\\task.exe"</Command>'
                '</Exec></Actions></Task>')
    hive = os.path.join(prefix, "user-%d.reg" % os.getuid())
    with open(hive, "w") as f:
        f.write('WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1700000000\n'
                '"Updater"="\\"C:\\\\users\\\\%s\\\\AppData\\\\Roaming\\\\Evil\\\\updater.exe\\" /quiet"\n' % me)
    with open(os.path.join(prefix, "system.reg"), "w") as f:
        f.write('WINE REGISTRY Version 2\n\n[System\\\\CurrentControlSet\\\\Services\\\\MakerSvc] 1700000000\n'
                '"ImagePath"=str(2):"%SystemDrive%\\\\Tools\\\\svc.exe -service"\n')
    # a link in a scanned place, to a file elsewhere: not followed
    outside = os.path.join(T, "outside")
    os.makedirs(outside)
    with open(os.path.join(outside, "secret.exe"), "wb") as f:
        f.write(b"MZ" + EICAR + b" outside")
    os.symlink(outside, os.path.join(home, "Downloads", "link"))
    os.symlink(os.path.join(outside, "secret.exe"), os.path.join(home, "Downloads", "link.exe"))
    env_scan = dict(env)
    r = subprocess.run([sys.executable, os.path.join(HERE, "bin", "sg-defender-scan"), "quick", "--wait"], env=env_scan,
                       capture_output=True, text=True, timeout=120)
    out = r.stdout
    found = re.findall(r"^  (.*): Eicar-Test-Signature \((removed|not removed)\)$", out, re.M)
    names = {os.path.basename(p): how for p, how in found}
    ok(names.get("Updater.exe") == "removed", "quick scan: a Run key's program (found by its name without case) [%s]" % out.strip().replace("\n", " | "))
    ok(names.get("start.bat") == "removed", "quick scan: the Startup folder")
    ok(names.get("task.exe") == "removed", "quick scan: a scheduled task's action")
    ok(names.get("svc.exe") == "removed", "quick scan: a service's ImagePath (%SystemDrive% expanded)")
    ok(names.get("dl.exe") == "removed", "quick scan: Downloads")
    ok("secret.exe" not in names and os.path.exists(os.path.join(outside, "secret.exe")), "quick scan: links are not followed")
    ok(os.path.exists(os.path.join(drive_c, "Program Files/Maker/clean.exe")), "quick scan: a clean program is left")
    with open(os.path.join(T, "notices", str(os.getuid()), "scans.json")) as f:
        hist = json.load(f)
    ok(hist and hist[0]["type"] == "quick" and hist[0]["state"] == "done" and hist[0]["found"] == 5,
       "the scan is in the person's protection history")
    cust = os.path.join(T, "custom")
    os.makedirs(os.path.join(cust, "deep", "deeper"))
    with open(os.path.join(cust, "deep", "deeper", "x.dll"), "wb") as f:
        f.write(b"MZ" + EICAR + b" custom")
    with open(os.path.join(cust, "photo.jpg"), "wb") as f:
        f.write(b"\xff\xd8" + EICAR)
    r = subprocess.run([sys.executable, os.path.join(HERE, "bin", "sg-defender-scan"), "custom", cust, "--wait"], env=env_scan,
                       capture_output=True, text=True, timeout=120)
    ok("x.dll: Eicar" in r.stdout and "photo.jpg: Eicar" in r.stdout and not os.path.exists(os.path.join(cust, "deep/deeper/x.dll")),
       "custom scan: the folder, every file in it, by its descriptor [%s]" % r.stdout.strip().replace("\n", " | "))
    with open(os.path.join(home, "notes.txt"), "wb") as f:
        f.write(EICAR)
    r = subprocess.run([sys.executable, os.path.join(HERE, "bin", "sg-defender-scan"), "full", "--wait"], env=env_scan,
                       capture_output=True, text=True, timeout=300)
    ok("notes.txt: Eicar" in r.stdout, "full scan: every file in the home")
    return RC


if __name__ == "__main__":
    sys.exit(main())
