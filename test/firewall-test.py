#!/usr/bin/python3
# Unit gate for sg-firewall (Stained Glass Firewall), no root and no
# nftables needed: the rules it makes from its configuration, the registry's
# rules (what INetFwPolicy2 and netsh store), who owns a listening socket
# (a fake /proc), Wine's notice with the socket itself (SCM_RIGHTS, the real
# socket protocol), the person's question and their Cancel, the commands
# sg-admind runs, and an upgrade's migration (nothing in use is cut off).
#
#   firewall-test.py                  all checks; exit 1 on a failure
#   firewall-test.py --mutant NAME    the same against a broken copy: must fail
#
# The network-namespace gate (firewall-netns-test.sh) loads what this makes
# into a real kernel and sends packets through it.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import array
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "bin", "sg-firewall")
FAILS = 0

# name: (what the copy breaks, the text replaced, its replacement)
MUTANTS = {
    # the zones' last rule lets everything in
    "FW_ACCEPT_ALL": ('t.append("\\t\\tcounter drop")', 't.append("\\t\\taccept")'),
    # Public networks treated as Private
    "FW_PUBLIC_AS_PRIVATE": ('allowed -= blocked', 'allowed -= blocked\n        allowed |= {"public"} if "private" in allowed else set()'),
    # a block rule does not win over an allow rule
    "FW_BLOCK_LOSES": ('allowed -= blocked', 'pass'),
    # a person's program listening without a rule is never asked about
    "FW_NO_ASK": ('state = "ask"', 'state = "blocked"'),
    # the registry's rules are not read
    "FW_NO_REGISTRY": ('rules[reg_unescape(m.group(1))] = reg_unescape(m.group(2))', 'pass'),
    # Wine's notice is not taken: Windows programs are never known
    "FW_NOTICE_IGNORED": ('self.hints[st.st_ino] = {', '_ignored = {'),
    # the upgrade does not keep what listens reachable
    "FW_MIGRATE_NOTHING": ('            c.rules.append(r)\n            lines.append', '            lines.append'),
    # the Cancel is ignored
    "FW_CANCEL_IGNORED": ('if not known_program(c.rules, program):', 'if False:'),
    # a new network is Private
    "FW_NEW_NETWORK_PRIVATE": ('cat = conf.networks.get(uuid_, ["public"])[0]', 'cat = conf.networks.get(uuid_, ["private"])[0]'),
}


def check(cond, what):
    global FAILS
    if cond:
        print("PASS  " + what)
    else:
        print("FAIL  " + what)
        FAILS += 1


def load_module(path):
    loader = importlib.machinery.SourceFileLoader("sgfw", path)
    spec = importlib.util.spec_from_loader("sgfw", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


def fake_proc(root, sockets, procs):
    """sockets: [(file, local hex, state, uid, inode)]; procs: {pid: (exe, argv, uid, [inodes])}."""
    os.makedirs(os.path.join(root, "net"))
    head = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
    files = {}
    for fname, local, st, uid, ino in sockets:
        rem = "00000000:0000" if len(local.split(":")[0]) == 8 else "0" * 32 + ":0000"
        files.setdefault(fname, []).append("   0: %s %s %s 00000000:00000000 00:00000000 00000000  %5d        0 %d 1 0000000000000000 100 0 0 10 0"
                                           % (local, rem, st, uid, ino))
    for fname in ("tcp", "tcp6", "udp", "udp6"):
        with open(os.path.join(root, "net", fname), "w") as f:
            f.write(head + "".join(l + "\n" for l in files.get(fname, [])))
    for pid, (exe, argv, uid, inodes) in procs.items():
        d = os.path.join(root, str(pid))
        os.makedirs(os.path.join(d, "fd"))
        os.symlink(exe, os.path.join(d, "exe"))
        with open(os.path.join(d, "cmdline"), "wb") as f:
            f.write(b"".join(a.encode() + b"\0" for a in argv))
        with open(os.path.join(d, "status"), "w") as f:
            f.write("Name:\tx\nUid:\t%d\t%d\t%d\t%d\n" % (uid, uid, uid, uid))
        for i, ino in enumerate(inodes):
            os.symlink("socket:[%d]" % ino, os.path.join(d, "fd", str(10 + i)))


def main(argv):
    mutant = None
    if argv[:1] == ["--mutant"] and len(argv) > 1:
        mutant = argv[1]
    t = tempfile.mkdtemp(prefix="sgfw-test-")
    try:
        src = SRC
        if mutant:
            old, new = MUTANTS[mutant]
            text = open(SRC).read()
            if old not in text:
                print("FAIL  mutant %s: its text is not in sg-firewall" % mutant)
                return 1
            src = os.path.join(t, "sg-firewall-mutant")
            with open(src, "w") as f:
                f.write(text.replace(old, new, 1))
        env = {
            "SG_FIREWALL_CONF": os.path.join(t, "etc", "firewall.conf"),
            "SG_FIREWALL_STATE": os.path.join(t, "state"),
            "SG_FIREWALL_RUN": os.path.join(t, "run"),
            "SG_FIREWALL_SYSTEM_REG": os.path.join(t, "system.reg"),
            "SG_FIREWALL_ROLE": os.path.join(t, "role"),
            "SG_FIREWALL_PROC": os.path.join(t, "proc"),
            "SG_FIREWALL_NMCLI": os.path.join(t, "nmcli"),
            "SG_FIREWALL_NFT": "/bin/false",
            "SG_FIREWALL_TEST": "1",
            "SG_SYSTEM_USER": "sg-no-such-user",
        }
        os.environ.update(env)
        with open(os.path.join(t, "nmcli"), "w") as f:
            f.write("#!/bin/sh\n"
                    "case \"$*\" in\n"
                    "*--active*) printf 'u-home:eth0:802-3-ethernet:Home\\nu-cafe:wlan0:802-11-wireless:Cafe\\nu-lo:lo:loopback:lo\\n' ;;\n"
                    "*'connection show'*) printf 'u-home:802-3-ethernet:Home\\nu-cafe:802-11-wireless:Cafe\\nu-old:802-11-wireless:Airport\\nu-lo:loopback:lo\\n' ;;\n"
                    "esac\n")
        os.chmod(os.path.join(t, "nmcli"), 0o755)
        fw = load_module(src)
        run_checks(fw, t)
    finally:
        shutil.rmtree(t, ignore_errors=True)
    print("%d failed" % FAILS if FAILS else "all passed")
    return 1 if FAILS else 0


SONOS = "C:\\Program Files\\Sonos\\Sonos.exe"
ME = os.getuid() if 1000 <= os.getuid() < 60000 else 1000


def run_checks(fw, t):
    # --- ports and networks
    check(fw.parse_ports("80, 443,8000-8080") == [(80, 80), (443, 443), (8000, 8080)], "ports and ranges parse")
    check(fw.parse_ports("*") is None, "'*' is any port")
    for bad in ("0", "70000", "80-79", "http"):
        try:
            fw.parse_ports(bad)
            check(False, "%r is refused" % bad)
        except fw.Fail:
            check(True, "%r is refused" % bad)
    check(fw.parse_profiles("private,public") == {"private", "public"} and fw.parse_profiles("all") == set(fw.PROFILES),
          "networks parse")
    check(fw.program_key("C:\\Program Files\\Sonos\\SONOS.EXE") == fw.program_key(SONOS),
          "Windows paths compare without regard to case")
    check(fw.program_key("/usr/bin/App") != fw.program_key("/usr/bin/app"), "Linux paths compare exactly")

    # --- the configuration round trip
    c = fw.Config()
    c.profiles["public"] = False
    c.networks["u-home"] = ["private", "Home"]
    c.rules.append(fw.Rule("abcd1234", True, "allow", {"private"}, "any", None, SONOS, "Sonos", "prompt"))
    c.rules.append(fw.Rule("abcd5678", False, "block", {"public"}, "tcp", [(8080, 8090)], None, "Web", "user"))
    c.groups["file-sharing"] = set()
    c.overrides["{X}"] = {"removed": True}
    d = fw.parse_config("\n".join(c.lines()))
    check(d.lines() == c.lines(), "the configuration reads back as written")

    # --- the registry: what programs stored, as wineserver writes system.reg
    reg = os.path.join(t, "system.reg")
    with open(reg, "w") as f:
        f.write("WINE REGISTRY Version 2\n\n"
                "[System\\\\CurrentControlSet\\\\Services\\\\SharedAccess\\\\Parameters\\\\FirewallPolicy\\\\FirewallRules] 1759796000\n"
                "#time=1dc37a1b2c3d4e5\n"
                '"{S1}"="v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|Profile=Private|LPort=3400|LPort=3401|App=%ProgramFiles%\\\\Sonos\\\\Sonos.exe|Name=Sonos TCP|"\n'
                '"{S2}"="v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=17|App=C:\\\\Program Files\\\\Sonos\\\\Sonos.exe|Name=Sonos UDP|"\n'
                '"{OUT}"="v2.30|Action=Allow|Active=TRUE|Dir=Out|Protocol=6|App=C:\\\\x.exe|Name=out|"\n'
                '"{OFF}"="v2.30|Action=Allow|Active=FALSE|Dir=In|Protocol=6|LPort=9999|Name=Caf\\xe9 off|"\n'
                "\n[Software\\\\Other] 1\n"
                '"{S9}"="v2.30|Action=Allow|Dir=In|LPort=1|"\n')
    rr = fw.read_registry_rules(reg)
    check(set(rr) == {"{S1}", "{S2}", "{OUT}", "{OFF}"}, "only the FirewallRules key is read")
    r1 = fw.rule_from_registry("{S1}", rr["{S1}"])
    check(r1 and r1.program == SONOS and r1.ports == [(3400, 3400), (3401, 3401)] and r1.proto == "tcp"
          and r1.profiles == {"private"} and r1.name == "Sonos TCP", "a program's rule: its program (%ProgramFiles% expanded), ports, networks")
    check(fw.rule_from_registry("{OUT}", rr["{OUT}"]) is None, "an outbound rule is not ours")
    off = fw.rule_from_registry("{OFF}", rr["{OFF}"])
    check(off and not off.enabled and off.name == "Caf\u00e9 off", "an inactive rule is off; \\x escapes decode")
    # a rule pushed now (before wineserver writes the file) is in force; an older push is not
    os.makedirs(os.path.join(t, "state"), exist_ok=True)
    past = os.stat(reg).st_mtime - 100
    with open(fw.pushed_path(), "w") as f:
        f.write("%f\t{OLD}\tv2.30|Action=Allow|Dir=In|LPort=1|\n" % past)
        f.write("%f\t{NEW}\tv2.30|Action=Allow|Dir=In|Protocol=6|LPort=5000|Name=New|\n" % (time.time() + 5))
        f.write("%f\t{S2}\t\n" % (time.time() + 5))
    eff = fw.effective_registry(reg)
    check("{NEW}" in eff and "{OLD}" not in eff and "{S2}" not in eff, "pushed rules apply until the registry file is newer")
    os.unlink(fw.pushed_path())

    # --- who listens: a fake /proc
    proc = os.path.join(t, "proc")
    fake_proc(proc, [
        ("tcp", "00000000:0016", "0A", 0, 101),        # sshd 0.0.0.0:22
        ("tcp", "0100007F:0277", "0A", 0, 102),        # cups 127.0.0.1:631: loopback, ignored
        ("tcp", "00000000:0D48", "0A", 990, 103),      # wineserver-owned :3400 (Sonos, notice below)
        ("tcp", "00000000:1F90", "0A", 0, 104),        # nginx :8080, a system service with no rule
        ("udp", "00000000:E2D8", "07", ME, 105),       # a person's program, UDP :58072 (ephemeral)
        ("tcp", "00000000:2328", "0A", ME, 106),       # a person's Linux program :9000
        ("udp", "00000000:14E9", "07", 107, 107),      # avahi :5353
        ("tcp6", "00000000000000000000000000000000:0D3D", "0A", 0, 108),   # sg-rdpd [::]:3389
        ("tcp", "00000000:1B58", "0A", 990, 109),      # a Windows program nobody told us about :7000
        ("tcp", "0100007F:1B59", "01", ME, 110),       # a connection, not a listener
    ], {
        11: ("/usr/sbin/sshd", ["sshd: /usr/sbin/sshd -D"], 0, [101]),
        12: ("/usr/sbin/cupsd", ["/usr/sbin/cupsd"], 0, [102]),
        13: ("/usr/lib/wine/wineserver", ["/usr/lib/wine/wineserver"], 990, [103, 109]),
        14: ("/usr/sbin/nginx", ["nginx"], 0, [104]),
        15: ("/usr/bin/python3.13", ["python3", "/home/me/bin/chat.py"], ME, [105, 106]),
        16: ("/usr/sbin/avahi-daemon", ["avahi-daemon: running"], 107, [107]),
        17: ("/usr/libexec/stained-glass/sg-rdp-authd", ["sg-rdp-authd", "3389"], 0, [108]),
    })
    hints = {103: {"program": SONOS, "uid": ME, "pid": 4242, "proto": "tcp", "port": 3400, "time": time.time()}}
    ls = fw.identify(fw.scan_listeners(proc), hints)
    by = {(l.proto, l.port): l for l in ls}
    check(("tcp", 631) not in by and ("tcp", 7001) not in by, "loopback listeners and connections are not listeners")
    check(by[("tcp", 22)].kind == "system" and by[("tcp", 22)].program == "/usr/sbin/sshd", "sshd: a system service")
    check(by[("tcp", 3400)].kind == "windows" and by[("tcp", 3400)].program == SONOS and by[("tcp", 3400)].owner_uid == ME,
          "a wineserver-held socket is the Windows program Wine's notice named")
    check(by[("tcp", 7000)].kind == "unknown" and by[("tcp", 7000)].program is None, "without a notice: unknown, never guessed")
    check(by[("tcp", 9000)].kind == "linux-user" and by[("tcp", 9000)].program == "/home/me/bin/chat.py",
          "a person's script is known by the script, not the interpreter")
    check(by[("tcp", 3389)].kind == "system", "IPv6 listeners are seen")

    # --- deciding
    conf = fw.Config()
    rules = fw.all_rules(conf, {})
    plan = fw.evaluate(conf, rules, ls)
    state = {(l.proto, l.port): (s, a) for l, a, s in plan.decisions}
    check(state[("tcp", 22)] == ("allowed", set(fw.PROFILES)), "SSH: allowed on every network (the built-in group)")
    check(state[("tcp", 3389)] == ("allowed", set(fw.PROFILES)), "Remote Desktop: allowed on every network while it listens")
    check(state[("udp", 5353)] == ("allowed", {"domain", "private"}), "mDNS: Private (and Domain) only")
    check(state[("tcp", 8080)][0] == "blocked", "a system service without a rule: blocked, nobody asked")
    check(state[("tcp", 3400)][0] == "ask", "a Windows program listening without a rule: asked about")
    check(state[("tcp", 9000)][0] == "ask", "a person's Linux program listening without a rule: asked about too")
    check(state[("udp", 58072)][0] != "allowed", "an ephemeral UDP socket is not opened")
    check([l.port for l in plan.ask] == [3400, 9000] or sorted(l.port for l in plan.ask) == [3400, 9000],
          "one question per program (its ephemeral UDP socket asks nothing)")
    check(state[("tcp", 7000)][0] == "blocked", "an unknown program: blocked, not asked")
    check((22, 22) in plan.open["public"]["tcp"] and (5353, 5353) not in plan.open["public"]["udp"],
          "Public: SSH open, mDNS closed")

    # Sonos allowed on Private (the prompt's rule): its ports, all of them, on Private only
    conf.rules.append(fw.Rule("s0n0s000", True, "allow", {"private"}, "any", None, SONOS.upper(), "Sonos", "prompt"))
    plan = fw.evaluate(conf, fw.all_rules(conf, {}), ls)
    check((3400, 3400) in plan.open["private"]["tcp"] and (3400, 3400) not in plan.open["public"]["tcp"],
          "an allowed program's port opens on its networks only")
    check(all(l.port != 3400 for l in plan.ask), "a program with a rule is not asked about")
    # the registry's rule for Sonos UDP, a static port rule, and a block that wins
    conf.rules.append(fw.Rule("p0rt0000", True, "allow", {"public", "private"}, "tcp", [(8000, 8010)], None, "Web", "user"))
    conf.rules.append(fw.Rule("b10ck000", True, "block", {"private"}, "any", None, "/home/me/bin/chat.py", "Chat", "prompt"))
    conf.rules.append(fw.Rule("a110w000", True, "allow", {"private", "public"}, "any", None, "/home/me/bin/chat.py", "Chat", "user"))
    plan = fw.evaluate(conf, fw.all_rules(conf, {}), ls)
    state = {(l.proto, l.port): (s, a) for l, a, s in plan.decisions}
    check((8000, 8010) in plan.open["public"]["tcp"], "a port rule opens its ports whatever listens")
    check(state[("tcp", 9000)] == ("allowed", {"public"}), "a block rule wins over an allow rule (Private), not elsewhere")
    conf.overrides["{S1}"] = {"removed": True}
    regrules = fw.all_rules(conf, {"{S1}": rr["{S1}"], "{S2}": rr["{S2}"]})
    check(not any(r.id == "reg:{S1}" for r in regrules) and any(r.id == "reg:{S2}" for r in regrules),
          "a program's rule removed in Settings stays removed")

    # --- the nftables table
    text = fw.ruleset(conf, plan, {"eth0": "private", "wlan0": "public"})
    check(text.startswith("table inet sg_firewall {"), "its own table, inet")
    check('iifname vmap { "eth0" : goto private, "wlan0" : goto public }' in text and "\t\tgoto public\n" in text,
          "each interface to its network's chain; anything else is Public")
    check("ct state established,related accept" in text and 'iif "lo" accept' in text,
          "answers to this PC's own connections, and the loopback, pass")
    check("udp sport 67 udp dport 68 accept" in text and "nd-neighbor-solicit" in text, "DHCP and neighbour discovery pass")
    check('iifname { "virbr*", "docker*"' in text and text.index('"virbr*"') < text.index("iifname vmap"),
          "this PC's own virtual machines' and containers' bridges are let in (their DHCP and DNS)")
    check("flush ruleset" not in text and "delete table inet sg_firewall" not in text,
          "nothing else's tables are touched")
    pub = text.split("chain public {")[1].split("}")[0]
    priv = text.split("chain private {")[1].split("}")[0]
    check("echo-request" not in pub and "echo-request" in priv, "ping answered on Private, not Public")
    check(pub.rstrip().endswith("counter drop"), "Public ends in drop")
    conf.profiles["public"] = False
    pub_off = fw.ruleset(conf, plan, {}).split("chain public {")[1].split("}")[0]
    check("accept" in pub_off and "drop" not in pub_off, "the firewall off for Public: everything in")
    conf.profiles["public"] = True

    # --- Wine's notice: the program's path, and the socket itself (SCM_RIGHTS)
    d = fw.Daemon()
    d.open_notify()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("0.0.0.0", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    ino = os.fstat(srv.fileno()).st_ino
    c1 = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    c1.sendmsg([("SGFW1\n%s\n" % SONOS).encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [srv.fileno()]))],
               0, os.path.join(t, "run", "notify"))
    c1.sendto(("SGFW1\nC:\\evil.exe\n").encode(), os.path.join(t, "run", "notify"))   # no socket: not believed
    time.sleep(0.1)
    d.read_notices()
    h = d.hints.get(ino)
    check(h is not None and h["program"] == SONOS and h["port"] == port and h["proto"] == "tcp" and h["uid"] == os.getuid()
          and h["pid"] == os.getpid(), "Wine's notice: the socket's own port and inode, the sender's uid and pid")
    check(len(d.hints) == 1, "a notice without its socket is ignored")
    c1.close()
    srv.close()
    d.sock.close()

    # --- the question and the Cancel
    with open(os.path.join(t, "etc-dummy"), "w"):
        pass
    d = fw.Daemon()
    d.reload_conf()
    d.networks = [("u-home", "eth0", "Home", "802-3-ethernet", "private")]
    me = fw.Listener("tcp", "0.0.0.0", 3400, 999, 990)
    me.program, me.kind, me.owner_uid = SONOS, "windows", ME
    if os.getuid() != ME:
        print("SKIP  the question (this test needs an ordinary account)")
        return
    plan = fw.evaluate(d.conf, fw.all_rules(d.conf, {}), [me])
    d.update_asks(plan, fw.all_rules(d.conf, {}))
    adir = fw.ask_dir(ME)
    asks = [n for n in os.listdir(adir) if n.endswith(".ask")] if os.path.isdir(adir) else []
    check(len(asks) == 1, "the question is put in the person's own folder")
    body = open(os.path.join(adir, asks[0])).read() if asks else ""
    check("program=%s\n" % SONOS in body and "port=3400" in body and "category=private" in body and "kind=windows" in body,
          "it names the program, its port and the network it is on")
    check(oct(os.stat(adir).st_mode & 0o777) == "0o700", "the folder is the person's alone")
    d.update_asks(plan, fw.all_rules(d.conf, {}))
    check(len([n for n in os.listdir(adir) if n.endswith(".ask")]) == 1, "asked once")
    aid = asks[0][:-4] if asks else "x"
    with open(os.path.join(adir, aid + ".cancel"), "w") as f:
        f.write("Sonos\n")
    d.answers()
    conf2 = fw.read_config()
    blocked = [r for r in conf2.rules if r.program == SONOS]
    check(len(blocked) == 1 and blocked[0].action == "block" and blocked[0].name == "Sonos",
          "Cancel: the program is blocked and listed (unticked), as on Windows")
    d.reload_conf()
    rules = fw.all_rules(d.conf, {})
    d.update_asks(fw.evaluate(d.conf, rules, [me]), rules)
    check(not os.path.exists(os.path.join(adir, aid + ".ask")), "the question goes once it is answered")

    # --- the commands sg-admind runs
    os.unlink(fw.CONF)

    def run(*a):
        try:
            return ("OK", fw.COMMANDS[a[0]][0](list(a[1:])))
        except fw.Fail as e:
            return (e.kind, e.message)
    st, out = run("rule-add", "allow", "private", "any", "*", SONOS, "Sonos", "prompt")
    check(st == "OK" and len(out) == 1, "rule-add: an app allowed on Private")
    rid = out[0] if st == "OK" else ""
    st, out2 = run("rule-add", "allow", "private,public", "any", "*", SONOS.lower(), "Sonos", "prompt")
    check(st == "OK" and out2 == [rid] and fw.read_config().rules[0].profiles == {"private", "public"},
          "the same program again changes its one rule")
    check(run("rule-add", "allow", "private", "tcp", "80", "C:\\x\tb", "n")[0] == "invalid", "a tab is refused")
    check(run("rule-add", "allow", "private", "tcp", "*", "relative.exe", "n")[0] == "invalid", "a program is a full path")
    check(run("rule-add", "allow", "private", "any", "*", "*", "n")[0] == "invalid", "a rule names a program or ports")
    check(run("rule-add", "open", "private", "tcp", "80", "*", "n")[0] == "invalid", "allow or block, nothing else")
    st, out = run("rule-add", "allow", "public", "tcp", "8080", "*", "Web server")
    pid_ = out[0] if st == "OK" else ""
    check(run("rule-set", rid, "1", "allow", "none")[0] == "OK" and not [r for r in fw.read_config().rules if r.id == rid][0].enabled,
          "unticking both networks turns the rule off (the app stays listed)")
    check(run("rule-remove", pid_)[0] == "OK" and not any(r.id == pid_ for r in fw.read_config().rules), "rule-remove")
    check(run("rule-remove", "nosuch00")[0] == "notfound", "removing what is not there says so")
    check(run("rule-set", "reg:{S1}", "1", "allow", "public")[0] == "OK" and
          fw.read_config().overrides["{S1}"]["profiles"] == {"public"}, "a program's rule is changed by an override")
    check(run("rule-remove", "reg:{S1}")[0] == "OK" and fw.read_config().overrides["{S1}"].get("removed"),
          "and removed by one")
    check(run("registry-push", "{S1}", rr["{S1}"])[0] == "OK" and "{S1}" not in fw.read_config().overrides,
          "a program adding its rule again brings it back")
    check(run("profile", "public", "off")[0] == "OK" and not fw.read_config().profiles["public"], "profile off")
    check(run("group", "file-sharing", "none")[0] == "OK" and fw.read_config().groups["file-sharing"] == set(), "a group off")
    check(run("network", "u-cafe", "private", "Cafe")[0] == "OK" and fw.read_config().networks["u-cafe"][0] == "private",
          "a network made Private")
    check(run("network", "u-cafe", "home")[0] == "invalid", "a network is Private or Public")
    check(run("reset")[0] == "OK", "reset")
    c3 = fw.read_config()
    check(not c3.rules and all(c3.profiles.values()) and c3.networks.get("u-cafe", [""])[0] == "private"
          and c3.groups["file-sharing"] == {"domain", "private"}, "Restore defaults: rules gone, firewall on, networks kept")
    os.environ["SG_FIREWALL_TEST"] = "0"
    if os.geteuid() != 0:
        check(fw.main(["profile", "all", "off"]) == 3 and fw.read_config().profiles["public"],
              "changes need root (an administrator, through sg-admind)")
    os.environ["SG_FIREWALL_TEST"] = "1"

    # --- the upgrade: networks in use are Private, what listens stays reachable
    os.unlink(fw.CONF)
    st, lines = run("migrate")
    c4 = fw.read_config()
    check(st == "OK" and c4.networks.get("u-home", [""])[0] == "private" and "u-lo" not in c4.networks
          and c4.networks.get("u-cafe", [""])[0] == "private", "upgrade: the networks in use are Private")
    check("u-old" not in c4.networks, "upgrade: a Wi-Fi network remembered from elsewhere is not made Private")
    kept = {(r.proto, r.ports[0][0]) for r in c4.rules if r.source == "upgrade"}
    check(("tcp", 8080) in kept and ("tcp", 9000) in kept and ("tcp", 3400) in kept and ("tcp", 7000) in kept,
          "upgrade: services and programs listening now get a rule (nginx, a person's program, Windows programs)")
    check(("tcp", 22) not in kept and ("udp", 58072) not in kept, "upgrade: no rule for what is allowed already, or ephemeral UDP")
    upgraded = c4.rules
    plan = fw.evaluate(c4, upgraded, fw.identify(fw.scan_listeners(proc), {}))
    check(all((l.port, l.port) in plan.open["public"][l.proto] for l, a, s in plan.decisions
              if not (l.proto == "udp" and l.port >= fw.EPHEMERAL) and l.port != 5353),
          "upgrade: everything that listened is reachable on every network")
    check(os.path.exists(os.path.join(t, "state", "upgrade.log")) and "8080" in open(os.path.join(t, "state", "upgrade.log")).read(),
          "upgrade: what was allowed is logged")
    st, lines = run("migrate")
    check(lines == ["already set up"], "upgrade: once")

    # --- a new network is Public
    conf = fw.Config()
    nets = fw.active_networks(conf)
    check(nets and all(n[4] == "public" for n in nets) and not any(n[1] == "lo" for n in nets),
          "a network nobody chose for is Public; the loopback is not a network")
    conf.networks["u-home"] = ["private", "Home"]
    check(dict((n[1], n[4]) for n in fw.active_networks(conf)) == {"eth0": "private", "wlan0": "public"},
          "a network chosen as Private is Private")
    with open(os.path.join(t, "role"), "w") as f:
        f.write("role=dc\nrealm=AD.EXAMPLE\n")
    check(all(n[4] == "domain" for n in fw.active_networks(conf)), "a domain controller's networks are Domain")
    os.unlink(os.path.join(t, "role"))
    st = fw.status_lines(conf, fw.all_rules(conf, {}), plan, fw.active_networks(conf))
    check("current\tprivate,public" in st and any(l.startswith("group\tssh\tall\t") for l in st),
          "the status names the networks in use and the groups")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--list-mutants"]:
        print("\n".join(MUTANTS))
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
