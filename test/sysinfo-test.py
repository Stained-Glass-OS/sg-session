#!/usr/bin/python3
# Unit gate for sg-sysinfo, the Linux side of the administrative tools. A fake
# sysfs, lsblk, journalctl, systemctl, testparm, smbstatus, mount and mkfs
# stand in for the machine; the checks are what each command reports from
# them, who may do what over the real socket protocol (sg-sysinfod decides
# from the peer's uid), that disk changes refuse the system disk and volumes
# in use, that the journal never shows anything but Stained Glass's own
# entries, and the bridge a Windows program talks through.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import grp
import json
import os
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SYSINFO = os.path.join(HERE, "..", "bin", "sg-sysinfo")
FAILS = 0


def check(cond, what):
    global FAILS
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        FAILS += 1


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(text, bytes) else "w") as f:
        f.write(text)
    os.chmod(path, mode)


def script(path, body):
    write(path, "#!/usr/bin/python3\n" + body, 0o755)


def link(target, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(target, path)


def edid(name):
    e = bytearray(128)
    e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    code = ((ord("S") - 64) << 10) | ((ord("G") - 64) << 5) | (ord("O") - 64)
    e[8], e[9] = code >> 8, code & 0xff
    e[10], e[11] = 0x34, 0x12
    blk = b"\x00\x00\x00\xfc\x00" + (name.encode() + b"\n").ljust(13, b" ")
    e[54:72] = blk
    return bytes(e)


def make_sysfs(root):
    dev = os.path.join(root, "devices/pci0000:00")

    def pci(slot, vendor, device, cls, driver=None, module=None):
        p = os.path.join(dev, slot)
        write(os.path.join(p, "vendor"), "0x%s\n" % vendor)
        write(os.path.join(p, "device"), "0x%s\n" % device)
        write(os.path.join(p, "class"), "0x%s\n" % cls)
        write(os.path.join(p, "subsystem_vendor"), "0x1af4\n")
        write(os.path.join(p, "subsystem_device"), "0x1100\n")
        link("../../../devices/pci0000:00/" + slot, os.path.join(root, "bus/pci/devices", slot))
        if driver:
            d = os.path.join(root, "bus/pci/drivers", driver)
            os.makedirs(d, exist_ok=True)
            link(os.path.relpath(d, p), os.path.join(p, "driver"))
            if module:
                m = os.path.join(root, "module", module)
                write(os.path.join(m, "version"), "9.9\n")
                if not os.path.lexists(os.path.join(d, "module")):
                    link(os.path.relpath(m, d), os.path.join(d, "module"))
        return p

    pci("0000:00:01.0", "1234", "1111", "030000", "bochs-drm", "bochs")        # a VM's display
    nv = pci("0000:01:00.0", "10de", "1c82", "030000")                         # NVIDIA, no driver
    net = pci("0000:00:03.0", "1af4", "1041", "020000", "virtio-pci", "virtio_pci")
    pci("0000:00:1f.0", "8086", "2918", "060100")                             # an ISA bridge, no driver: fine
    # eth0 under the virtio network device
    vn = os.path.join(net, "virtio0")
    os.makedirs(vn)
    write(os.path.join(vn, "net/eth0/address"), "52:54:00:12:34:56\n")
    link("../../devices/pci0000:00/0000:00:03.0/virtio0/net/eth0", os.path.join(root, "class/net/eth0"))
    link(os.path.relpath(vn, os.path.join(vn, "net/eth0")), os.path.join(vn, "net/eth0/device"))
    write(os.path.join(root, "devices/virtual/net/lo/address"), "00:00:00:00:00:00\n")
    link("../../devices/virtual/net/lo", os.path.join(root, "class/net/lo"))
    # a disk on a controller
    vd = os.path.join(root, "devices/pci0000:00/0000:00:05.0/virtio2/block/vda")
    write(os.path.join(vd, "size"), "41943040\n")
    write(os.path.join(vd, "removable"), "0\n")
    link(os.path.relpath(os.path.dirname(os.path.dirname(vd)), vd), os.path.join(vd, "device"))
    link("../devices/pci0000:00/0000:00:05.0/virtio2/block/vda", os.path.join(root, "block/vda"))
    # a monitor on the display
    con = os.path.join(root, "devices/pci0000:00/0000:00:01.0/drm/card0/card0-Virtual-1")
    write(os.path.join(con, "status"), "connected\n")
    write(os.path.join(con, "edid"), edid("SG Test Panel"))
    link("../../devices/pci0000:00/0000:00:01.0/drm/card0/card0-Virtual-1",
         os.path.join(root, "class/drm/card0-Virtual-1"))
    # a keyboard with no udev data (capabilities decide)
    inp = os.path.join(root, "devices/platform/i8042/serio0/input/input1")
    write(os.path.join(inp, "name"), "AT Translated Set 2 keyboard\n")
    write(os.path.join(inp, "capabilities/ev"), "120013\n")
    write(os.path.join(inp, "capabilities/key"), "402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe\n")
    write(os.path.join(inp, "capabilities/rel"), "0\n")
    write(os.path.join(inp, "id/bustype"), "0011\n")
    write(os.path.join(inp, "id/vendor"), "0001\n")
    write(os.path.join(inp, "id/product"), "0001\n")
    link("../../devices/platform/i8042/serio0/input/input1", os.path.join(root, "class/input/input1"))
    write(os.path.join(root, "class/dmi/id/sys_vendor"), "QEMU\n")
    write(os.path.join(root, "class/dmi/id/product_name"), "Standard PC (Q35 + ICH9, 2009)\n")
    return nv


PCI_IDS = """# test
1234  Technical Corp.
\t1111  QEMU Virtual Video Controller
10de  NVIDIA Corporation
\t1c82  GP107 [GeForce GTX 1050 Ti]
1af4  Red Hat, Inc.
\t1041  Virtio 1.0 network device
8086  Intel Corporation
\t2918  82801IB (ICH9) LPC Interface Controller
"""

CPUINFO = """processor\t: 0
model name\t: Test CPU @ 3.00GHz
physical id\t: 0
core id\t\t: 0
cpu MHz\t\t: 3000.000

processor\t: 1
model name\t: Test CPU @ 3.00GHz
physical id\t: 0
core id\t\t: 1
cpu MHz\t\t: 3000.000
"""

LSBLK = {"blockdevices": [
    {"name": "sda", "path": "/dev/sda", "type": "disk", "size": 64 * 1024 ** 3, "model": "SYSDISK", "tran": "sata",
     "rota": False, "rm": False, "ro": False, "pttype": "gpt", "mountpoints": [None], "children": [
         {"name": "sda1", "path": "/dev/sda1", "type": "part", "start": 2048, "size": 512 * 1024 ** 2,
          "fstype": "vfat", "parttype": "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "mountpoints": ["/boot/efi"],
          "fssize": 500, "fsused": 1, "fsavail": 499, "partn": 1},
         {"name": "sda2", "path": "/dev/sda2", "type": "part", "start": 1050624, "size": 60 * 1024 ** 3,
          "fstype": "ext4", "label": "root", "mountpoints": ["/"], "fssize": 1000, "fsused": 400,
          "fsavail": 600, "partn": 2},
         {"name": "sda3", "path": "/dev/sda3", "type": "part", "start": 1050624 + 60 * 1024 ** 3 // 512,
          "size": 1024 ** 3, "fstype": "ext4", "label": "spare-on-system", "mountpoints": [None], "partn": 3}]},
    {"name": "sdb", "path": "/dev/sdb", "type": "disk", "size": 32 * 1024 ** 3, "model": "DATA", "tran": "usb",
     "rota": True, "rm": True, "ro": False, "pttype": "dos", "mountpoints": [None], "children": [
         {"name": "sdb1", "path": "/dev/sdb1", "type": "part", "start": 2048, "size": 8 * 1024 ** 3,
          "fstype": "ext4", "label": "spare", "mountpoints": [None], "partn": 1},
         {"name": "sdb2", "path": "/dev/sdb2", "type": "part", "start": 2048 + 16 * 1024 ** 3 // 512,
          "size": 8 * 1024 ** 3, "fstype": "vfat", "label": "PHOTOS", "mountpoints": ["/media/photos"],
          "fssize": 8000, "fsused": 10, "fsavail": 7990, "partn": 2}]},
    {"name": "zram0", "type": "disk", "size": 1024, "mountpoints": ["[SWAP]"]},
    {"name": "sr0", "path": "/dev/sr0", "type": "rom", "size": 0, "rm": True, "ro": True, "mountpoints": [None]},
]}

JOURNAL = [
    {"__REALTIME_TIMESTAMP": "1700000000000001", "PRIORITY": "6", "_SYSTEMD_UNIT": "sg-netd@1.service",
     "SYSLOG_IDENTIFIER": "sg-netd", "_PID": "42", "__CURSOR": "s=a;i=1", "MESSAGE": "uid 1000: wifi connect"},
    {"__REALTIME_TIMESTAMP": "1700000000000002", "PRIORITY": "3", "_SYSTEMD_UNIT": "sshd.service",
     "SYSLOG_IDENTIFIER": "sshd", "_PID": "43", "__CURSOR": "s=a;i=2", "MESSAGE": "secret ssh thing"},
    {"__REALTIME_TIMESTAMP": "1700000000000003", "PRIORITY": "4", "_SYSTEMD_UNIT": "user@1000.service",
     "_SYSTEMD_USER_UNIT": "sg-session.service", "SYSLOG_IDENTIFIER": "sg-session", "_PID": "44",
     "__CURSOR": "s=a;i=3", "MESSAGE": "two\nlines\twith a tab and a \\ backslash"},
    {"__REALTIME_TIMESTAMP": "1700000000000004", "PRIORITY": "6", "SYSLOG_IDENTIFIER": "sg-install",
     "_PID": "45", "__CURSOR": "s=a;i=4", "MESSAGE": [104, 105, 255]},
]


KEEP = os.environ.get("KEEP")


def main():
    tmp = tempfile.mkdtemp(prefix="sysinfo-test.", dir="/var/tmp")
    try:
        run_tests(tmp)
    finally:
        if not KEEP:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(tmp)
    print("sysinfo-test: %s (%d failures)" % ("PASS" if not FAILS else "FAIL", FAILS))
    return 1 if FAILS else 0


def run_tests(tmp):
    me = os.getuid()
    my_group = grp.getgrgid(os.getgid()).gr_name
    sysfs = os.path.join(tmp, "sys")
    make_sysfs(sysfs)
    write(os.path.join(tmp, "pci.ids"), PCI_IDS)
    proc = os.path.join(tmp, "proc")
    write(os.path.join(proc, "cpuinfo"), CPUINFO)
    write(os.path.join(proc, "meminfo"), "MemTotal:        2048000 kB\nMemAvailable:    1024000 kB\n")
    write(os.path.join(proc, "uptime"), "1234.5 100.0\n")
    log = os.path.join(tmp, "calls.log")
    fake = os.path.join(tmp, "fake")
    rec = "import json, os, sys\nopen(%r, 'a').write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + '\\n')\n" % log
    script(os.path.join(fake, "lsblk"), rec + "print(open(%r).read())\n" % os.path.join(tmp, "lsblk.json"))
    photos = os.path.join(tmp, "photos")
    os.makedirs(photos)
    write(os.path.join(tmp, "lsblk.json"), json.dumps(LSBLK).replace("/media/photos", photos))
    script(os.path.join(fake, "journalctl"), rec + "for e in json.load(open(%r))[::-1]: print(json.dumps(e))\n"
           % os.path.join(tmp, "journal.json"))
    write(os.path.join(tmp, "journal.json"), json.dumps(JOURNAL))
    script(os.path.join(fake, "systemctl"), rec + r'''
a = sys.argv[1:]
if a[0] in ("list-units", "list-unit-files"):
    print("sg-netd.socket loaded active listening Stained Glass network settings socket")
    print("sg-netd@.service static")
    print("sg-wineserver.service loaded active running Stained Glass machine wineserver")
elif a[0] == "show":
    for u in a[a.index("--") + 1:]:
        if u.startswith("sg-"):
            print("Id=%s\nDescription=Test %s\nLoadState=loaded\nActiveState=active\nSubState=running\n"
                  "UnitFileState=enabled\nMainPID=77\nActiveEnterTimestamp=@1700000000\nFragmentPath=/x/%s\n" % (u, u, u))
        else:
            print("Id=%s\nLoadState=not-found\n" % u)
''')
    script(os.path.join(fake, "testparm"), rec + r'''
print("[global]\n\tworkgroup = SGTEST\n\n[Public]\n\tcomment = Everyone's files\n\tpath = /srv/public\n\tguest ok = Yes\n\tread only = No\n\n[print$]\n\tpath = /var/lib/samba/printers\n")
''')
    script(os.path.join(fake, "smbstatus"), rec + r'''
print(json.dumps({"sessions": {"1": {"username": "alice", "remote_machine": "10.0.0.9", "session_dialect": "SMB3_11",
                                     "encryption": {"cipher": "AES-128-GCM"}}}}))
''')
    for t in ("mount", "umount", "mkfs.ext4", "sg-drivers", "dpkg-query"):
        body = rec
        if t == "sg-drivers":
            body += 'print("DEVICE 0000:01:00.0\\t10de:1c82\\tNVIDIA graphics\\tnvidia-driver firmware-misc-nonfree\\tNVIDIA\'s driver")\n'
        if t == "dpkg-query":
            body += "sys.exit(1)\n"
        script(os.path.join(fake, t), body)
    prefix = os.path.join(tmp, "prefix")
    dd = os.path.join(prefix, "dosdevices")
    os.makedirs(os.path.join(prefix, "drive_c"))
    link("../drive_c", os.path.join(dd, "c:"))
    link("/", os.path.join(dd, "z:"))
    link(photos, os.path.join(dd, "d:"))
    link("/nonexistent/net", os.path.join(dd, "n:"))
    write(os.path.join(tmp, "passwd"), "root:x:0:0:root:/root:/bin/bash\nalice:x:1001:1001:Alice Example,,,:/home/alice:/bin/bash\n"
          "bob:x:1002:1002:Bob:/home/bob:/bin/bash\nsgsystem:x:990:990::/var/lib/stained-glass:/usr/sbin/nologin\n"
          "daemon:x:1:1::/:/usr/sbin/nologin\n")
    write(os.path.join(tmp, "group"), "root:x:0:\nalice:x:1001:\nbob:x:1002:\nsg-admins:x:980:alice\nsgwine:x:981:alice,bob,sgsystem\nsgsystem:x:990:\n")
    write(os.path.join(tmp, "shadow"), "alice:$y$abc:19000:0:99999:7:::\nbob:!$y$abc:19000:0:99999:7:::\n")
    xdg = os.path.join(tmp, "xdg")
    write(os.path.join(xdg, "Trash/files/old.txt"), "x" * 5000)
    write(os.path.join(xdg, "Trash/info/old.txt.trashinfo"), "[Trash Info]\n")
    var = os.path.join(tmp, "var")
    write(os.path.join(var, "cache/apt/archives/foo_1.deb"), "d" * 9000)
    write(os.path.join(var, "cache/apt/archives/lock"), "")
    write(os.path.join(var, "log/syslog.2.gz"), "z" * 3000)
    write(os.path.join(var, "log/syslog"), "keep")

    base = dict(os.environ, SG_SYSFS=sysfs, SG_PROCFS=proc, SG_UDEV_DATA=os.path.join(tmp, "udev"),
                SG_PCI_IDS=os.path.join(tmp, "pci.ids"), SG_USB_IDS="/nonexistent", SG_MODINFO="",
                SG_DETECT_VIRT="", SG_LSBLK=os.path.join(fake, "lsblk"),
                SG_JOURNALCTL=os.path.join(fake, "journalctl"), SG_SYSTEMCTL=os.path.join(fake, "systemctl"),
                SG_TESTPARM=os.path.join(fake, "testparm"), SG_SMBSTATUS=os.path.join(fake, "smbstatus"),
                SG_NET="", SG_MOUNT=os.path.join(fake, "mount"), SG_UMOUNT=os.path.join(fake, "umount"),
                SG_MKFS_EXT4=os.path.join(fake, "mkfs.ext4"), SG_DRIVERS=os.path.join(fake, "sg-drivers"),
                SG_DPKG_QUERY=os.path.join(fake, "dpkg-query"), SG_PREFIX=prefix, SG_MEDIA_DIR=os.path.join(tmp, "media"),
                SG_PASSWD_FILE=os.path.join(tmp, "passwd"), SG_GROUP_FILE=os.path.join(tmp, "group"),
                SG_SHADOW_FILE=os.path.join(tmp, "shadow"), XDG_DATA_HOME=xdg,
                XDG_CACHE_HOME=os.path.join(tmp, "cache"), SG_VAR=var,
                SG_SYSINFO_SOCKET=os.path.join(tmp, "no.sock"))
    base.pop("WINEPREFIX", None)

    def cli(*argv, env=None):
        p = subprocess.run([sys.executable, SYSINFO] + list(argv), stdout=subprocess.PIPE, env=env or base,
                           timeout=60)
        return p.stdout.decode().splitlines(), p.returncode

    def calls():
        try:
            return [json.loads(x) for x in open(log)]
        except OSError:
            return []

    def reset():
        if os.path.exists(log):
            os.unlink(log)

    def blocks(lines, head):
        out, cur = [], None
        for line in lines:
            k, _, v = line.partition(" ")
            if k == head:
                cur = {"_": v}
                out.append(cur)
            elif line == "END":
                cur = None
            elif cur is not None:
                cur.setdefault(k, []).append(v)
        return out

    def serve(argv, admin=False, user=True, raw=None):
        a, b = socket.socketpair()
        e = dict(base, SG_ADMIN_GROUP=my_group if admin else "sg-no-such-group",
                 SG_WINE_GROUP=my_group if user else "sg-no-such-group", SG_SYSTEM_USER="sg-no-such-user")
        p = subprocess.Popen([sys.executable, SYSINFO, "--serve"], stdin=b, stdout=b, env=e)
        b.close()
        a.sendall(raw if raw is not None else (json.dumps({"argv": argv}) + "\n").encode())
        data = b""
        while True:
            chunk = a.recv(65536)
            if not chunk:
                break
            data += chunk
        p.wait(timeout=60)
        a.close()
        return data.decode().splitlines()

    # --- system --------------------------------------------------------------
    out, rc = cli("system")
    d = dict(line.split(" ", 1) for line in out if " " in line)
    check(rc == 0 and out[-1] == "OK", "system answers")
    check(d.get("CPU") == "Test CPU @ 3.00GHz" and d.get("CPU-CORES") == "2" and d.get("CPU-THREADS") == "2",
          "system: the processor and its cores from cpuinfo")
    check(d.get("MEMORY-TOTAL") == str(2048000 * 1024) and d.get("MANUFACTURER") == "QEMU",
          "system: memory and the maker from DMI")
    gpus = [line[4:] for line in out if line.startswith("GPU ")]
    check(any("QEMU Virtual Video Controller" in g for g in gpus) and "NVIDIA GeForce GTX 1050 Ti" in gpus,
          "system: the graphics adapters (%s)" % gpus)

    # --- devices -------------------------------------------------------------
    out, rc = cli("devices")
    devs = {b["_"]: b for b in blocks(out, "DEVICE")}
    disp = devs.get("pci:0000:00:01.0", {})
    check(disp.get("CLASS") == ["display"] and "QEMU Virtual Video Controller" in disp.get("NAME", [""])[0]
          and disp.get("DRIVER") == ["bochs-drm"] and disp.get("MODULE") == ["bochs"]
          and disp.get("MODULE-VERSION") == ["9.9"] and disp.get("STATUS") == ["ok"],
          "devices: the VM's display adapter, its driver and module")
    nv = devs.get("pci:0000:01:00.0", {})
    check(nv.get("NAME") == ["NVIDIA GeForce GTX 1050 Ti"] and nv.get("STATUS") == ["nodriver"]
          and nv.get("SG-DRIVER") == ["nvidia-driver firmware-misc-nonfree"] and "nvidia-driver" in nv.get("PROBLEM", [""])[0],
          "devices: an NVIDIA card with no driver says so and names what sg-drivers installs")
    net = devs.get("pci:0000:00:03.0", {})
    check(net.get("CLASS") == ["net"] and net.get("IFACE") == ["eth0"] and net.get("MAC") == ["52:54:00:12:34:56"],
          "devices: the network adapter with its interface and address")
    check(not any(k.startswith("net:lo") for k in devs), "devices: no loopback adapter")
    bridge_dev = devs.get("pci:0000:00:1f.0", {})
    check(bridge_dev.get("STATUS") == ["ok"] and bridge_dev.get("CLASS") == ["system"],
          "devices: a bridge with no driver is a system device, not a problem")
    vda = devs.get("block:vda", {})
    check(vda.get("CLASS") == ["disk"] and vda.get("SIZE") == [str(41943040 * 512)], "devices: the disk and its size")
    mon = devs.get("monitor:card0-Virtual-1", {})
    check(mon.get("NAME") == ["SG Test Panel"] and mon.get("PARENT") == ["pci:0000:00:01.0"]
          and mon.get("VENDOR-ID") == ["SGO"], "devices: the monitor, named from its EDID, on its adapter")
    kb = devs.get("input:input1", {})
    check(kb.get("CLASS") == ["keyboard"], "devices: a keyboard found by its capabilities without udev")
    check(len([k for k in devs if k.startswith("cpu:")]) == 2, "devices: one processor entry per logical CPU")

    # --- disks ---------------------------------------------------------------
    out, rc = cli("disks")
    check(rc == 0 and out[-1] == "OK", "disks answers")
    disks = {b["_"]: b for b in blocks(out, "DISK") if "PATH" in b}
    parts = {b["_"]: b for b in blocks(out, "PART")}
    free = blocks(out, "FREE")
    check(set(disks) == {"sda", "sdb", "sr0"}, "disks: the disks and the optical drive, no zram (%s)" % sorted(disks))
    check(disks["sda"].get("SIZE") == [str(64 * 1024 ** 3)] and disks["sda"].get("SYSTEM") == ["yes"]
          and disks["sdb"].get("SYSTEM") == ["no"] and disks["sdb"].get("REMOVABLE") == ["yes"],
          "disks: sizes, the system disk, a removable disk")
    check(parts["sda2"].get("START") == [str(1050624 * 512)] and parts["sda2"].get("FSUSED") == ["400"],
          "disks: partition offsets in bytes and file system use")
    check(parts["sda1"].get("FLAGS") == ["esp system"], "disks: the EFI system partition")
    check(sorted(parts["sda2"].get("LETTER", [])) == ["C:", "Z:"] and parts["sdb2"].get("LETTER") == ["D:"],
          "disks: drive letters from the prefix's dosdevices (C: and Z: on /, D: on the photos volume)")
    check(any(line.startswith("MAP N:\t") for line in out), "disks: a letter on no local volume is listed")
    check(any(f.get("_") == "sdb" and f.get("START") == [str(2048 * 512 + 8 * 1024 ** 3)]
              and f.get("SIZE") == [str(8 * 1024 ** 3)] for f in free), "disks: the unallocated space between partitions")

    # --- units, users, groups, shares ---------------------------------------
    out, rc = cli("units")
    units = {b["_"]: b for b in blocks(out, "UNIT")}
    check(set(units) == {"sg-netd.socket", "sg-wineserver.service"} and units["sg-netd.socket"].get("SINCE") == ["1700000000"],
          "units: the Stained Glass units, templates left out, others not found skipped")
    out, rc = cli("users")
    users = {b["_"]: b for b in blocks(out, "USER")}
    check(set(users) == {"alice", "bob", "sgsystem"}, "users: people and SYSTEM, not daemons")
    check(users["alice"].get("ADMIN") == ["yes"] and users["bob"].get("ADMIN") == ["no"]
          and users["alice"].get("FULL-NAME") == ["Alice Example"] and users["bob"].get("DISABLED") == ["yes"]
          and users["alice"].get("DISABLED") == ["no"] and users["sgsystem"].get("SYSTEM-ACCOUNT") == ["yes"],
          "users: administrators, full names, a locked account, SYSTEM")
    out, rc = cli("groups")
    groups = {b["_"]: b for b in blocks(out, "GROUP")}
    check(groups.get("sg-admins", {}).get("WINDOWS-NAME") == ["Administrators"]
          and groups.get("sgwine", {}).get("MEMBERS") == ["alice bob sgsystem"] and "alice" not in groups,
          "groups: Administrators and Users by their Windows names; personal groups left out")
    out, rc = cli("shares")
    shares = {b["_"]: b for b in blocks(out, "SHARE")}
    check(shares.get("Public", {}).get("READONLY") == ["no"] and shares["Public"].get("GUEST") == ["yes"]
          and "global" not in shares, "shares: Samba's shares from testparm")
    out, rc = cli("shares", env=dict(base, SG_TESTPARM="", SG_SMBD=""))
    check(out[-1].startswith("ERROR unsupported") and rc == 1, "shares: Samba absent is said plainly")

    # --- the journal through sg-sysinfod ------------------------------------
    out = serve(["journal"])
    ents = [line.split("\t") for line in out if line.startswith("E\t")]
    check(out[-1] == "OK" and len(ents) == 3, "journal: a user's request is answered")
    check(not any("ssh" in line for line in out), "journal: nothing but Stained Glass entries")
    check(ents and ents[0][1] == "1700000000000004" and ents[-1][1] == "1700000000000001", "journal: newest first")
    sess = [e for e in ents if e[4] == "sg-session"]
    check(sess and sess[0][3] == "sg-session.service" and sess[0][7] == "two\\nlines\\twith a tab and a \\\\ backslash",
          "journal: a session's user unit, the message escaped onto one line")
    check(any(e[7] == "hi\ufffd" for e in ents), "journal: a binary message is decoded")
    out = serve(["journal", "--unit", "sg-netd@1.service"])
    check(len([x for x in out if x.startswith("E\t")]) == 1, "journal: filtered by unit")
    out = serve(["journal", "--unit", "sshd.service"])
    check(out[-1].startswith("ERROR invalid"), "journal: a unit outside Stained Glass is refused")
    out = serve(["journal"], user=False)
    check(out[-1].startswith("ERROR denied"), "journal: an account with no Windows session gets nothing")
    out = serve([], raw=b"not json\n")
    check(out[-1] == "ERROR invalid malformed request", "sg-sysinfod: a malformed request is refused")
    out = serve(["devices"])
    check(out[-1].startswith("ERROR invalid"), "sg-sysinfod: only its own commands (readable ones are local)")

    # --- Samba sessions: administrators --------------------------------------
    out = serve(["sessions"])
    check(out[-1].startswith("ERROR denied"), "sessions: refused to a standard user")
    out = serve(["sessions"], admin=True)
    check(out[-1] == "OK" and "USER alice" in out, "sessions: an administrator sees who is connected")

    # --- disk changes --------------------------------------------------------
    reset()
    out = serve(["format", "sdb1", "ext4"])
    check(out[-1].startswith("ERROR denied") and not calls(), "format: refused to a standard user")
    out = serve(["format", "sda3", "ext4"], admin=True)
    check(out[-1].startswith("ERROR denied") and not any(c[0] == "mkfs.ext4" for c in calls()),
          "format: refused on the system disk")
    out = serve(["format", "sdb2", "ext4"], admin=True)
    check(out[-1].startswith("ERROR denied") and not any(c[0] == "mkfs.ext4" for c in calls()),
          "format: refused on a mounted volume with a drive letter")
    out = serve(["format", "sdb1", "ext4", "--label", "bad;label"], admin=True)
    check(out[-1].startswith("ERROR invalid"), "format: a bad label is refused")
    out = serve(["format", "sdb1", "ext4", "--label", "Spare"], admin=True)
    check(out[-1] == "OK" and ["mkfs.ext4", "-F", "-q", "-L", "Spare", "/dev/sdb1"] in calls(),
          "format: an administrator formats an unused partition")
    reset()
    out = serve(["unmount", "sda2"], admin=True)
    check(out[-1].startswith("ERROR denied") and not calls() or all(c[0] == "lsblk" for c in calls()),
          "unmount: the system volume is refused")
    out = serve(["mount", "sdb1"], admin=True)
    mc = [c for c in calls() if c[0] == "mount"]
    check(out[-1] == "OK" and mc and mc[0][-2] == "/dev/sdb1" and mc[0][-1].endswith("/media/spare"),
          "mount: an administrator mounts a partition under the media directory")
    out = serve(["mount", "sdb1"])
    check(out[-1].startswith("ERROR denied"), "mount: refused to a standard user")
    out = serve(["unmount", "sdb2"], admin=True)
    check(out[-1] == "OK" and ["umount", photos] in calls(), "unmount: a data volume")
    out = serve(["letter", "sdb2", "C:"], admin=True)
    check(out[-1].startswith("ERROR invalid") and os.readlink(os.path.join(dd, "c:")) == "../drive_c",
          "letter: C: cannot be given away")
    out = serve(["letter", "sdb2", "N:"], admin=True)
    check(out[-1].startswith("ERROR invalid") and os.readlink(os.path.join(dd, "n:")) == "/nonexistent/net",
          "letter: a letter in use is refused")
    out = serve(["letter", "sdb1", "G:"], admin=True)
    check(out[-1].startswith("ERROR invalid") and not os.path.lexists(os.path.join(dd, "g:")),
          "letter: an unmounted volume gets no letter")
    out = serve(["letter", "sdb2", "E:"])
    check(out[-1].startswith("ERROR denied") and not os.path.lexists(os.path.join(dd, "e:")),
          "letter: refused to a standard user")
    out = serve(["letter", "sdb2", "E:"], admin=True)
    check(out[-1] == "OK" and os.readlink(os.path.join(dd, "e:")) == photos
          and not os.path.lexists(os.path.join(dd, "d:")), "letter: changed from D: to E:")
    out = serve(["letter", "sdb2", "none"], admin=True)
    check(out[-1] == "OK" and not os.path.lexists(os.path.join(dd, "e:")) and os.path.lexists(os.path.join(dd, "c:")),
          "letter: removed, C: untouched")
    out = serve(["letter", "sda2", "none"], admin=True)
    check(os.path.lexists(os.path.join(dd, "c:")) and os.path.lexists(os.path.join(dd, "z:")),
          "letter: C: and Z: are never removed")

    # --- cleanup -------------------------------------------------------------
    out, rc = cli("cleanup")
    cats = {b["_"]: b for b in blocks(out, "CATEGORY")}
    check(int(cats.get("recycle-bin", {}).get("SIZE", ["0"])[0]) >= 5000 and "update-cache" not in cats,
          "cleanup: the user's own categories (system ones need the service)")
    out = serve(["cleanup-system"])
    cats = {b["_"]: b for b in blocks(out, "CATEGORY")}
    check(int(cats.get("update-cache", {}).get("SIZE", ["0"])[0]) >= 9000
          and int(cats.get("old-logs", {}).get("SIZE", ["0"])[0]) >= 3000, "cleanup: system categories' sizes")
    out = serve(["clean-system", "update-cache"])
    check(out[-1].startswith("ERROR denied") and os.path.exists(os.path.join(var, "cache/apt/archives/foo_1.deb")),
          "clean: system files refused to a standard user")
    out = serve(["clean-system", "update-cache", "old-logs"], admin=True)
    check(out[-1] == "OK" and not os.path.exists(os.path.join(var, "cache/apt/archives/foo_1.deb"))
          and os.path.exists(os.path.join(var, "cache/apt/archives/lock"))
          and not os.path.exists(os.path.join(var, "log/syslog.2.gz")) and os.path.exists(os.path.join(var, "log/syslog")),
          "clean: an administrator empties the package cache and old logs, nothing else")
    out, rc = cli("clean", "recycle-bin")
    check(out[-1] == "OK" and not os.listdir(os.path.join(xdg, "Trash/files")) and os.path.isdir(os.path.join(xdg, "Trash/files")),
          "clean: the user empties their own Recycle Bin")
    out, rc = cli("clean", "nope")
    check(rc == 2 and out[-1].startswith("ERROR invalid"), "clean: an unknown category is refused")

    # --- processes and connections (the real /proc) ---------------------------
    out, rc = cli("processes", env=dict(base, SG_PROCFS="/proc"))
    procs = {b["_"]: b for b in blocks(out, "PROCESS")}
    check(str(os.getpid()) in procs and procs[str(os.getpid())].get("USER") == [pwd.getpwuid(me).pw_name],
          "processes: this test's own process, with its user")
    out, rc = cli("connections", env=dict(base, SG_PROCFS="/proc"))
    check(rc == 0 and out[-1] == "OK", "connections answers")

    # --- the bridge -----------------------------------------------------------
    child = os.path.join(tmp, "child.py")
    script(child, r'''
import json, sys
def ask(argv):
    sys.stdout.write("wine: noise on stdout\n")
    sys.stdout.write(json.dumps({"argv": argv}) + "\n"); sys.stdout.flush()
    out = []
    while True:
        line = sys.stdin.readline().rstrip("\n")
        out.append(line)
        if line == "OK" or line.startswith("ERROR ") or not line:
            return out
a = ask(["whoami"]); b = ask(["disks"]); c = ask(["bogus"])
sys.stdout.write("{not json\n"); sys.stdout.flush(); d = sys.stdin.readline().rstrip("\n")
open(sys.argv[1], "w").write(json.dumps([a, b, c, d]))
''')
    res = os.path.join(tmp, "bridge.json")
    p = subprocess.run([sys.executable, SYSINFO, "--bridge", sys.executable, child, res], env=base, timeout=60)
    try:
        a, b, c, d = json.load(open(res))
    except (OSError, ValueError):
        a = b = c = d = None
    check(p.returncode == 0 and a and a[0] == "USER " + pwd.getpwuid(me).pw_name and a[-1] == "OK",
          "bridge: a Windows program's request is answered")
    check(b and "DISK sda" in b and b[-1] == "OK", "bridge: disks through the bridge")
    check(c and c[-1].startswith("ERROR invalid"), "bridge: an unknown command is refused")
    check(d == "ERROR invalid malformed request", "bridge: a malformed line is refused")


if __name__ == "__main__":
    sys.exit(main())
