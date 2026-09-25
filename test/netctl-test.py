#!/usr/bin/python3
# Unit gate for sg-netctl, no NetworkManager needed: a fake nmcli and busctl
# record what they are asked and answer from a small state. Checks who may do
# what (the peer's uid, over the real socket protocol), that inputs are
# validated before NetworkManager hears of them, that a Wi-Fi key never
# appears on a command line and is stored 0600, that a network that could not
# be joined is not remembered, and the bridge a Windows program talks through.
#
# The VM gate (sg-image `make net-test`) runs the same commands against a real
# NetworkManager, Wi-Fi radio and DHCP server.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import grp
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NETCTL = os.path.join(HERE, "..", "bin", "sg-netctl")
FAILS = 0

FAKE_NMCLI = r'''#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_NM_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
state = json.load(open(os.environ["FAKE_NM_STATE"]))
a = [x for x in args if x not in ("-t", "-e", "yes")]
if a[:2] == ["--wait", "45"]:
    a = a[2:]
def out(s):
    sys.stdout.write(s)
if a[:1] == ["-f"]:
    fields, a = a[1], a[2:]
else:
    fields = ""
if a[:2] == ["device", "status"]:
    out("eth0:ethernet:connected:u-eth\nwlan0:wifi:disconnected:--\nlo:loopback:connected (externally):lo\n")
elif a[:2] == ["device", "show"]:
    out("GENERAL.DEVICE:eth0\nGENERAL.STATE:100 (connected)\nGENERAL.HWADDR:52\\:54\\:00\\:12\\:34\\:56\n"
        "GENERAL.MTU:1500\nGENERAL.CONNECTION:Wired connection 1\nIP4.ADDRESS[1]:10.0.2.15/24\n"
        "IP4.GATEWAY:10.0.2.2\nIP4.DNS[1]:10.0.2.3\n"
        "DHCP4.OPTION[1]:dhcp_lease_time = 86400\nDHCP4.OPTION[2]:expiry = 1800000000\n"
        "DHCP4.OPTION[3]:dhcp_server_identifier = 10.0.2.2\n")
elif a[:2] == ["connection", "show"] and len(a) == 2:
    for c in state.get("connections", []):
        out("%s:802-11-wireless:%s:/org/freedesktop/NetworkManager/Settings/%s\n" % (c["uuid"], c["name"], c["n"]))
elif a[:2] == ["connection", "show"]:
    out("connection.autoconnect:yes\nipv4.method:auto\nipv4.ignore-auto-dns:no\nipv6.method:auto\n")
elif a[:3] == ["device", "wifi", "list"]:
    for n in state.get("scan", []):
        out("%s:%s:%d:%s:wlan0\n" % (" " if not n.get("inuse") else "*", n["hex"], n["signal"], n["security"]))
elif a[:2] == ["connection", "up"]:
    if state.get("up_fails"):
        sys.stderr.write("Error: Connection activation failed: Secrets were required, but not provided.\n"
                         "Hint: use 'journalctl -xe NM_CONNECTION=x + NM_DEVICE=wlan0' to get more details.\n")
        sys.exit(4)
elif a[:2] == ["connection", "load"] or a[:2] == ["connection", "modify"] or a[:2] == ["connection", "delete"]:
    pass
elif a[:2] == ["radio", "wifi"]:
    out("enabled\n")
elif a[:1] == ["device"]:
    pass
else:
    sys.stderr.write("fake nmcli: unhandled %r\n" % (a,))
    sys.exit(2)
'''

FAKE_BUSCTL = r'''#!/usr/bin/python3
import json, os, sys
state = json.load(open(os.environ["FAKE_NM_STATE"]))
path = sys.argv[sys.argv.index("org.freedesktop.NetworkManager") + 1]
for c in state.get("connections", []):
    if path.endswith("/" + c["n"]):
        print(json.dumps({"type": "a{sa{sv}}", "data": [{"802-11-wireless": {"ssid": {"type": "ay", "data": list(bytes.fromhex(c["hex"]))}},
                                                        "connection": {"autoconnect": {"type": "b", "data": True}}}]}))
        sys.exit(0)
sys.exit(1)
'''


def check(cond, what):
    global FAILS
    print(("PASS  " if cond else "FAIL  ") + what)
    if not cond:
        FAILS += 1


def main():
    t = tempfile.mkdtemp(prefix="netctl-test.")
    try:
        run_tests(t)
    finally:
        shutil.rmtree(t, ignore_errors=True)
    print()
    print("RESULT: %s" % ("PASS" if FAILS == 0 else "FAIL"))
    return 1 if FAILS else 0


def run_tests(t):
    bindir = os.path.join(t, "bin")
    os.mkdir(bindir)
    for name, body in (("nmcli", FAKE_NMCLI), ("busctl", FAKE_BUSCTL)):
        p = os.path.join(bindir, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)
    log = os.path.join(t, "nm.log")
    state_file = os.path.join(t, "state.json")
    nmdir = os.path.join(t, "system-connections")
    os.mkdir(nmdir, 0o700)
    me = os.getuid()
    my_group = grp.getgrgid(os.getgid()).gr_name
    env = dict(os.environ, PATH=bindir + ":" + os.environ["PATH"], FAKE_NM_LOG=log,
               FAKE_NM_STATE=state_file, SG_NM_DIR=nmdir)

    def state(**kw):
        with open(state_file, "w") as f:
            json.dump(kw, f)
        open(log, "w").close()

    def calls():
        """What nmcli was asked, without the output-format and wait options."""
        out = []
        with open(log) as f:
            for line in f:
                c = json.loads(line)
                if c[:3] == ["-t", "-e", "yes"]:
                    c = c[3:]
                if c[:2] == ["--wait", "45"]:
                    c = c[2:]
                out.append(c)
        return out

    def serve(argv, secret=None, admin=False, outsider=False):
        """One request over a real socket to sg-netctl --serve, from this uid.
        admin: the admin group is one this user is in; outsider: neither it nor
        the Windows users' group is."""
        a, b = socket.socketpair()
        e = dict(env, SG_ADMIN_GROUP=my_group if admin else "sg-no-such-group",
                 SG_WINE_GROUP="sg-no-such-group" if outsider else my_group)
        p = subprocess.Popen([sys.executable, NETCTL, "--serve"], stdin=b, stdout=b, env=e)
        b.close()
        a.sendall((json.dumps({"argv": argv, "secret": secret}) + "\n").encode())
        out = b""
        while True:
            chunk = a.recv(65536)
            if not chunk:
                break
            out += chunk
        a.close()
        p.wait(timeout=30)
        return out.decode().splitlines()

    if me == 0:
        print("SKIP  running as root: the policy is about ordinary accounts")
        return

    # --- who may do what ---------------------------------------------------------
    state(scan=[{"hex": b"Cafe".hex(), "signal": 70, "security": "WPA2"}])
    out = serve(["whoami"])
    check(out[-1] == "OK" and "ADMIN no" in out, "whoami: an ordinary user is not an administrator")
    out = serve(["whoami"], admin=True)
    check("ADMIN yes" in out, "whoami: a member of the admin group is")
    out = serve(["ipv4", "eth0", "static", "10.0.2.50/24", "--gateway", "10.0.2.2"])
    check(out[-1].startswith("ERROR denied"), "an ordinary user may not set a static address")
    check(not any(c[:3] == ["connection", "modify", "uuid"] for c in calls()),
          "and NetworkManager was never asked")
    for cmd in (["dns", "eth0", "1.1.1.1"], ["disable", "eth0"], ["renew", "eth0"], ["release", "eth0"],
                ["ipv6", "eth0", "disabled"]):
        out = serve(cmd)
        check(out[-1].startswith("ERROR denied"), "an ordinary user may not: %s" % " ".join(cmd))
    out = serve(["wifi", "scan"], outsider=True)
    check(out[-1].startswith("ERROR denied"), "an account without a Windows session may not even scan")
    out = serve(["wifi", "scan"])
    check(out[-1] == "OK" and any(l.startswith("WIFI 70\twpa-psk\tno\tno\t%s\tCafe" % b"Cafe".hex()) for l in out),
          "an ordinary user may scan for Wi-Fi: " + (out[0] if out else "(nothing)"))
    out = serve(["adapters"])
    check(out[-1] == "OK" and "ADAPTER eth0" in out and "IPV4-ADDRESS 10.0.2.15/24" in out
          and "MAC 52:54:00:12:34:56" in out and "DHCP4-SERVER 10.0.2.2" in out and "DHCP4-OBTAINED 1799913600" in out,
          "adapters: address, MAC (escaped colons), DHCP lease")
    check("ADAPTER lo" not in out, "adapters: loopback is not an adapter")

    # --- administrators: validated, then NetworkManager -------------------------------
    state()
    out = serve(["ipv4", "eth0", "static", "10.0.2.50/24", "--gateway", "10.0.2.2", "--dns", "10.0.2.3,1.1.1.1"],
                admin=True)
    mods = [c for c in calls() if c[:2] == ["connection", "modify"]]
    check(out[-1] == "OK" and mods and mods[0][2:4] == ["uuid", "u-eth"]
          and mods[0][4:] == ["ipv4.method", "manual", "ipv4.addresses", "10.0.2.50/24", "ipv4.gateway", "10.0.2.2",
                              "ipv4.dns", "10.0.2.3,1.1.1.1", "ipv4.ignore-auto-dns", "yes"],
          "an administrator sets a static address, gateway and DNS: %s" % (mods[0][4:] if mods else out[-1:]))
    check(any(c[:4] == ["connection", "up", "uuid", "u-eth"] for c in calls()), "and the connection is reapplied")
    state()
    out = serve(["ipv4", "eth0", "dhcp"], admin=True)
    mods = [c for c in calls() if c[:2] == ["connection", "modify"]]
    check(out[-1] == "OK" and mods and mods[0][4:] == ["ipv4.method", "auto", "ipv4.addresses", "", "ipv4.gateway", "",
                                                        "ipv4.dns", "", "ipv4.ignore-auto-dns", "no"],
          "back to DHCP clears the address and takes DNS from the server")
    for bad, why in ((["ipv4", "eth0", "static", "10.0.2.50"], "no prefix length"),
                     (["ipv4", "eth0", "static", "300.0.2.50/24"], "not an address"),
                     (["ipv4", "eth0", "static", "10.0.2.0/24"], "the network's own address"),
                     (["ipv4", "eth0", "static", "10.0.2.255/24"], "the broadcast address"),
                     (["ipv4", "eth0", "static", "224.0.0.5/24"], "multicast"),
                     (["ipv4", "eth0", "static", "10.0.2.50/24", "--gateway", "10.9.9.9"], "a gateway off the subnet"),
                     (["ipv4", "eth0", "static", "10.0.2.50/24", "--dns", "a;b"], "junk DNS"),
                     (["ipv4", "eth0", "static", "10.0.2.50/24", "--dns", "auto"], "automatic DNS with a fixed address"),
                     (["ipv4", "eth0", "dhcp", "--gateway", "10.0.2.2"], "a gateway with DHCP"),
                     (["ipv4", "eth0; reboot", "dhcp"], "a shell-ish adapter name"),
                     (["ipv4", "nosuch0", "dhcp"], "an adapter that does not exist"),
                     (["ipv4", "eth0", "static", "10.0.2.50/24", "--bogus", "x"], "an unknown option")):
        state()
        out = serve(bad, admin=True)
        check(out[-1].startswith(("ERROR invalid", "ERROR notfound")) and
              not any(c[:2] == ["connection", "modify"] for c in calls()), "refused before NetworkManager: " + why)

    # --- Wi-Fi: the key never on a command line; failed joins not remembered -----
    secret = "correct horse \\ battery"
    state(scan=[{"hex": b"Cafe Net".hex(), "signal": 55, "security": "WPA2"}])
    out = serve(["wifi", "connect", "--ssid", "Cafe Net", "--password-stdin"], secret=secret)
    files = os.listdir(nmdir)
    check(out[-1] == "OK" and "CONNECTED wlan0" in out, "an ordinary user joins a WPA2 network: %s" % out[-1:])
    check(len(files) == 1 and stat.S_IMODE(os.stat(os.path.join(nmdir, files[0])).st_mode) == 0o600,
          "its profile is stored 0600")
    body = open(os.path.join(nmdir, files[0])).read() if files else ""
    check("ssid=67;97;102;101;32;78;101;116;" in body and "psk=correct\\shorse\\s\\\\\\sbattery" in body
          and "key-mgmt=wpa-psk" in body, "the profile has the SSID's bytes and the escaped key")
    check(not any(secret in " ".join(c) or "correct" in " ".join(c) for c in calls()),
          "the key never appears in NetworkManager's command lines")
    state(scan=[{"hex": b"Cafe Net".hex(), "signal": 55, "security": "WPA2"}], up_fails=True)
    for f in os.listdir(nmdir):
        os.unlink(os.path.join(nmdir, f))
    out = serve(["wifi", "connect", "--ssid", "Cafe Net", "--password-stdin"], secret="wrong-password")
    check(out[-1].startswith("ERROR auth"), "a wrong key is reported as such: %s" % out[-1:])
    check(os.listdir(nmdir) == [] and any(c[:2] == ["connection", "delete"] for c in calls()),
          "and the network is not remembered")
    state(scan=[{"hex": b"Cafe Net".hex(), "signal": 55, "security": "WPA2"}])
    out = serve(["wifi", "connect", "--ssid", "Cafe Net", "--password-stdin"], secret="short")
    check(out[-1].startswith("ERROR invalid"), "a WPA2 key under 8 characters is refused")
    state(scan=[{"hex": b"Corp".hex(), "signal": 55, "security": "WPA2 802.1X"}])
    out = serve(["wifi", "connect", "--ssid", "Corp", "--password-stdin"], secret="whatever1")
    check(out[-1].startswith("ERROR unsupported"), "enterprise networks are refused plainly, not half-joined")
    state(scan=[])
    out = serve(["wifi", "connect", "--ssid", "Gone", "--password-stdin"], secret="whatever1")
    check(out[-1].startswith("ERROR notfound"), "a network not in range is not found")
    odd = bytes([0xff, 0x00, 0x41])
    state(scan=[{"hex": odd.hex(), "signal": 40, "security": ""}])
    out = serve(["wifi", "connect", "--ssid-hex", odd.hex()])
    files = os.listdir(nmdir)
    check(out[-1] == "OK" and files and "ssid=255;0;65;" in open(os.path.join(nmdir, files[0])).read()
          and "[wifi-security]" not in open(os.path.join(nmdir, files[0])).read(),
          "an open network with a non-UTF-8 name joins by its exact bytes")
    state(connections=[{"uuid": "u-saved", "name": "Wi-Fi Home", "n": "7", "hex": b"Home".hex()}],
          scan=[{"hex": b"Home".hex(), "signal": 90, "security": "WPA2"}])
    out = serve(["wifi", "saved"])
    check(out[-1] == "OK" and any(l.startswith("SAVED u-saved\tyes\t%s\tHome" % b"Home".hex()) for l in out),
          "saved networks are listed by their exact SSID")
    out = serve(["wifi", "connect", "--ssid", "Home"])
    check(out[-1] == "OK" and any(c[:4] == ["connection", "up", "uuid", "u-saved"] for c in calls()),
          "a saved network joins with its saved key")
    out = serve(["wifi", "forget", "--ssid", "Home"])
    check(out[-1] == "OK" and any(c[:4] == ["connection", "delete", "uuid", "u-saved"] for c in calls()),
          "forget deletes the saved network")

    # --- the request itself ----------------------------------------------------------
    a, b = socket.socketpair()
    p = subprocess.Popen([sys.executable, NETCTL, "--serve"], stdin=b, stdout=b, env=env)
    b.close()
    a.sendall(b"not json\n")
    reply = a.recv(4096).decode()
    a.close()
    p.wait(timeout=30)
    check(reply.startswith("ERROR invalid"), "a malformed request is refused")
    out = serve(["wifi", "connect", "--ssid", "x" * 300])
    check(out[-1].startswith("ERROR invalid"), "an oversized argument is refused")

    # --- the bridge a Windows program talks through ---------------------------------
    state(scan=[{"hex": b"Cafe".hex(), "signal": 70, "security": "WPA2"}])
    child = os.path.join(t, "child.py")
    with open(child, "w") as f:
        f.write("import json, sys\n"
                "print('Wine may print this', flush=True)\n"
                "print(json.dumps({'argv': ['whoami']}), flush=True)\n"
                "got = []\n"
                "for line in sys.stdin:\n"
                "    got.append(line.strip())\n"
                "    if line.strip() == 'OK' or line.startswith('ERROR '): break\n"
                "open(sys.argv[1], 'w').write('\\n'.join(got))\n")
    res = os.path.join(t, "bridge.out")
    sock = os.path.join(t, "netd.sock")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock)
    srv.listen(4)
    bp = subprocess.Popen([sys.executable, NETCTL, "--bridge", sys.executable, child, res],
                          env=dict(env, SG_NETD_SOCKET=sock))
    conn, _ = srv.accept()
    p = subprocess.Popen([sys.executable, NETCTL, "--serve"], stdin=conn, stdout=conn,
                         env=dict(env, SG_WINE_GROUP=my_group))
    conn.close()
    p.wait(timeout=30)
    rc = bp.wait(timeout=30)
    srv.close()
    got = open(res).read().splitlines() if os.path.exists(res) else []
    check(rc == 0 and got[-1:] == ["OK"] and "ADMIN no" in got,
          "the bridge carries a Windows program's request to sg-netd and the answer back: %s" % got)


if __name__ == "__main__":
    sys.exit(main())
