#!/usr/bin/python3
# Gate for "sg-settingsctl media", the media keys' half in sg-session: on a
# session bus of its own, two stand-in MPRIS players (as a Linux program, or a
# Windows one through wine-sg's transport-controls bridge, shows itself) record
# the methods they are called with. The checks: the list Settings and the
# volume flyout read, which player each key goes to (the one playing; else the
# one last controlled; else one paused), and the refusals.
# Mutant: SG_MUTANT_MEDIA_FIRST=1 (the first paused player, not the one last
# controlled) fails it (the Makefile's lint runs it so).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(HERE, "..", "bin", "sg-settingsctl")
FAILS = 0

CC = shutil.which("cc") or shutil.which("gcc")
if not shutil.which("dbus-daemon") or not shutil.which("busctl") or not CC:
    print("SKIP: no dbus-daemon, busctl or C compiler")
    sys.exit(77)


def check(what, ok, detail=""):
    global FAILS
    print("%s  %s%s" % ("PASS" if ok else "FAIL", what, "" if ok else ": " + str(detail)))
    if not ok:
        FAILS += 1


tmp = tempfile.mkdtemp(prefix="sg-media-keys-")
procs = []


def cleanup():
    for p in procs:
        p.kill()
    shutil.rmtree(tmp, ignore_errors=True)


try:
    run_dir = os.path.join(tmp, "run")
    os.makedirs(run_dir, mode=0o700)
    daemon = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                              stdout=subprocess.PIPE, text=True)
    procs.append(daemon)
    env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=daemon.stdout.readline().strip(),
               XDG_RUNTIME_DIR=run_dir)
    log = os.path.join(tmp, "calls")
    open(log, "w").close()
    standin = os.path.join(tmp, "mpris-standin")
    r = subprocess.run([CC, "-O1", "-o", standin, os.path.join(HERE, "mpris-standin.c"), "-lsystemd"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("SKIP: the stand-in player did not build (libsystemd-dev?): " + r.stderr.strip()[:200])
        sys.exit(77)

    def player(name, status, title):
        procs.append(subprocess.Popen([standin, name, status, title, log], env=env))

    def ctl(*args, extra=None):
        r = subprocess.run([sys.executable, CTL, "media"] + list(args), env=dict(env, **(extra or {})),
                           capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout

    def wait_players(n):
        for _ in range(100):
            if ctl()[1].count("PLAYER ") >= n:
                return True
            time.sleep(0.1)
        return False

    def last_call():
        with open(log) as f:
            lines = f.read().split("\n")
        return [x for x in lines if x][-1] if any(lines) else ""

    rc, out = ctl("next")
    check("no player: the key says so (notfound) and calls nothing", rc == 5 and "ERROR notfound" in out, out)

    player("aaa_paused", "Paused", "Song A")
    player("zzz_playing", "Playing", "Song Z")
    check("the stand-in players are on the bus", wait_players(2))
    rc, out = ctl()
    check("the list: each player, its state, title and artist",
          rc == 0 and "PLAYER aaa_paused\tPaused\tSong A\tArtist aaa_paused" in out
          and "PLAYER zzz_playing\tPlaying\tSong Z\tArtist zzz_playing" in out, out)

    rc, out = ctl("play-pause")
    check("Play/Pause goes to the one playing, not the first listed",
          rc == 0 and last_call() == "zzz_playing PlayPause", (out, last_call()))
    for verb, method in (("next", "Next"), ("previous", "Previous"), ("stop", "Stop")):
        ctl(verb)
        check("%s calls %s" % (verb, method), last_call() == "zzz_playing " + method, last_call())

    procs[-1].kill()            # the playing one goes away
    procs.pop().wait()
    player("mmm_paused", "Paused", "Song M")
    wait_players(2)
    ctl("play-pause")
    first = last_call()
    ctl("play-pause")
    check("with none playing, a paused one; then the same one again (the one last controlled)",
          first == last_call() and first.endswith(" PlayPause") and first.split()[0] in ("aaa_paused", "mmm_paused"),
          (first, last_call()))
    with open(os.path.join(run_dir, "sg-media-last"), "w") as f:
        f.write("org.mpris.MediaPlayer2.mmm_paused\n")
    ctl("play-pause")
    check("the one last controlled wins over the first one paused", last_call() == "mmm_paused PlayPause", last_call())
    rc, out = ctl("louder")
    check("an unknown key is refused (invalid)", rc == 2 and "ERROR invalid" in out, out)
    rc, out = ctl("next", "now")
    check("extra words are refused", rc == 2, out)
finally:
    cleanup()

print("media-keys-test: %s" % ("all passed" if FAILS == 0 else "%d FAILED" % FAILS))
sys.exit(1 if FAILS else 0)
