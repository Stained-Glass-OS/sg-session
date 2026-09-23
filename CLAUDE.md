# sg-session — session glue

Brings up a Stained Glass desktop session: a compositor hosting Wine's
`explorer` as the shell, against a **system-wide** Wine prefix rather than a
per-user one.

Project brief: [`stained-glass/docs/BRIEF.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/BRIEF.md).

## Build, test, gate

```sh
make lint    # sh -n + shellcheck on every script
make test    # lint, then the real session gate (below)
make deb     # build the .deb
make install DESTDIR=... PREFIX=/usr
```

`make test` is the gate. It stands up a **complete headless session on this
machine** — wlroots headless backend, XWayland, a scratch Wine prefix, Wine
explorer as the shell — and runs `sg-session-check` against it. No VM and no
root required, so it runs in CI and on a developer box the same way.

It exits 77 (skip) if `cage`, `Xwayland`, `wine` or `xwininfo` is missing.

This is deliberately the same check the `sg-image` boot gate runs inside the
guest. **If `make test` passes here and the image boot gate fails, the fault is
in the image, not in this repo.** That split is the main reason this gate exists
separately.

## What the pieces are

| File | Role |
|---|---|
| `bin/sg-session-start` | session entry point; greetd exec's this |
| `bin/sg-prefix-init` | builds the system prefix; idempotent, stamp-guarded |
| `bin/sg-session-check` | **the Phase 0 gate**: is a Windows shell really running? |
| `bin/sg-multiuser-check` | **the S2 gate**: expected red until S2 lands |
| `lib/sg-common.sh` | shared paths and the Wine environment, in one place |
| `lib/sg-run-explorer` | runs inside the compositor; starts explorer |
| `config/greetd-config.toml` | autologin placeholder for `sg-greeter` |
| `bin/sg-install-apps` | installs PowerShell 7 and Python into the prefix (see below) |
| `bin/sg-apps-check` | **the bundled-apps gate** |
| `bin/sg-wineserver` | **the machine-level wineserver**: the Windows system itself |
| `bin/sg-services-start` | starts the SCM inside it, as SYSTEM |
| `systemd/sg-prefix-init.service` | first-boot fallback if the image didn't bake a prefix |
| `systemd/sg-wineserver.service` | runs the machine-level server before greetd |

Paths default to `/var/lib/stained-glass` and are overridable via `SG_*`
environment variables — `SG_LIB`, `SG_BIN`, `SG_ROOT`, `SG_PREFIX`, `SG_STATE`,
`SG_LOG_DIR`. That overridability exists so the gate can run against a staged
tree; keep it working.

## The machine-level wineserver

`sg-wineserver.service` runs a persistent wineserver as root, before `greetd`,
and `sg-services-start` starts `services.exe` inside it. That is what makes a
Windows service exist from boot, survive every logout, and be visible to every
logged-in user through one SCM — none of which a session-scoped server can do.
It is debt item `D5`, and the hardest clause of the S2 gate.

**It runs unprivileged**, as `sgsystem` — the account that owns the prefix,
which `wine-sg` therefore maps to the SYSTEM SID. It is deliberately not root.

Hosting the Windows system needs no Unix root, including for driver work:

- `winebus.sys` reaches devices through **udev**, not privileged syscalls
- `winedevice` has no uid or capability checks
- printing goes through **CUPS**, which is a socket and a group

Driver install needs two things, and neither is root. **Permission to touch the
device** comes from `udev/70-stained-glass-devices.rules` plus `sgsystem`'s
membership of `lp`, `scanner`, `plugdev` and `dialout`. **NT administrator**, to
write HKLM, comes from `wine-sg` reading who owns the prefix.

Running it as root would put a root process on a socket every desktop user can
reach and buy no capability an ordinary account lacks.

## Scanners, and other USB devices a Windows driver drives

Two paths, and `wine-sg` has both:

- **`sane.ds`** — Wine's TWAIN data source over SANE. Present only because
  `wine-sg` builds `--with-sane`; **Debian's Wine is `--without-sane` and cannot
  do TWAIN at all**, which would be a baffling thing to discover in the middle
  of S3.
- **`wineusb.sys`** — raw USB, for a real Windows vendor driver talking to the
  device itself. This is the one S3 is actually about.

Both need the device readable and writable by the `sgwine` group, which is what
the udev rules do. There is deliberately **no blanket "all USB to sgwine"
rule** — that would hand every desktop user raw access to every USB device on
the machine. A device the class rules do not match gets its own line; the rules
file shows the form.

## The shared system prefix

`sg-prefix-init` marks the prefix with `.sg-system-prefix`, which puts `wine-sg`
into shared mode: one wineserver for several Unix users, a SID and an HKCU hive
each. On a stock Wine the marker is simply ignored, so this repo still works
against a distribution Wine — without the sharing.

**`SG_WINE_GROUP` (default `sgwine`) is the access policy.** `wine-sg` decides
who may connect to a shared wineserver by membership of the group owning its
directory, which it takes from the prefix. Adding a Unix user to that group is
how you give them a Windows session; there is no separate policy file.

`sg-prefix-init` also creates `HKLM\Software\Policies` as the prefix owner, so
it carries an administrator-owned descriptor. That is deliberately *policy*
rather than Wine behaviour: which branches a machine protects is the operating
system's business, the same way Windows ships those ACLs in its image.

Set `SG_SYSTEM_PREFIX=0` to build an ordinary single-user prefix instead.

## Things that will bite you

- **Wine's driver must be pinned.** Wine prefers `winewayland` whenever a
  Wayland socket is present, and cage always provides one. Without the explicit
  `HKCU\Software\Wine\Drivers\Graphics = x11`, the x11 path silently becomes the
  wayland path, and the virtual desktop — and therefore the taskbar — vanishes.
  See ADR 0003.
- **`/desktop=shell,WxH` geometry is an upper bound.** Wine clamps the desktop
  to the compositor's output. Asking for 1280x800 on a 1280x720 output gets you
  1280x720.
- **The window checks are x11-only,** because cage exposes no toplevel
  enumeration protocol. `sg-session-check` fails loudly rather than skipping if
  pointed at the wayland path. That is intentional.
- **The gate runs the machine-level wineserver too**, because the image does.
  It did not until a bug that needs *two* explorers in one prefix passed here
  and failed in the guest, costing several 25-minute image rebuilds.
  `SG_TEST_MACHINE_SERVER=0` turns it off to isolate a session-only fault.
- **Session 0 must not have a shell.** `sg-wineserver` and `sg-services-start`
  set `SG_WINSTATION=__wineservice_winstation\Default`; `sg-run-explorer`
  unsets it, because the interactive shell belongs on `WinSta0`. See wine-sg
  patch 0007. **Do not detect the shell or a leak by command line.** On the
  image, the process owning the healthy "shell" desktop has been seen with the
  command line `explorer.exe /desktop` and no `/desktop=shell,WxH` process
  alive; under stock Wine both are present. Why is not yet established — but a
  `pgrep` for `/desktop=shell` flaked the boot gate. `sg-session-check` proves
  the shell by its `shell - Wine Desktop` window and guards the leak by
  ownership: no `explorer.exe` may run as `$SG_SYSTEM_USER`.
- **`\\` in a POSIX single-quoted string is two backslashes.** Writing
  `'...\\Default'` produced a desktop named `\Default`, which cannot be
  created, and Wine answered by starting an explorer that did the same thing
  again. Wine now refuses to start a shell for session 0, but the quoting is
  still worth getting right.
- **Scripts are POSIX `sh`, not bash.** They run early, before anything is
  guaranteed present. `make lint` enforces it.
- **`SG_*` variables must be exported** — the session crosses a process boundary
  from `sg-session-start` into `sg-run-explorer` under cage.

## The default user profile

`sg-prefix-init` copies the freshly initialised hive over `userdef.reg`, making
it a real Default User profile.

**Why a second user was short-changed.** `wineboot` applies `wine.inf`'s HKCU
sections to whoever runs it, then stamps `.update-timestamp` in the *prefix*.
The prefix is shared and the hives are not, so every later user's wineboot sees
an up-to-date prefix and skips the per-user install entirely. They were not
seeded badly — they were skipped by design. Before this, the first user had 52
keys and everyone after had 16, and the missing ones were Shell Folders, User
Shell Folders, Internet Settings and the rest of the profile.

Windows fills Default User once at install time; Wine has the same slot
(`\Registry\User\.Default`, stored as `userdef.reg`) and never fills it. Since
`wine-sg` patch 0006 seeds each new hive from that file, filling the template
fixes every future user at the source rather than repairing each copy.

The copy is safe because all the hive files are the same format — server saves
of a user branch — and it is taken immediately after `wineboot --init`, before
anyone has personalised anything. Volatile keys are never written to disk, so
nothing user-specific comes with it. It must stay **after** the `wineserver -w`
that follows `wineboot`, or the hive on disk is incomplete.

Check it with `grep -c '^\[' userdef.reg`: 52-ish means a real profile, 16
means the stub.

## Lock-screen isolation (the security gate)

`sg-keylog-adversary` is a keylogger, and `sg-lock-security-check` is the gate
that must defeat it. Together they hold [ADR 0009](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/decisions/0009-credential-ui-security-model.md)
to account: a program in the user's session must not observe what is typed into
the lock screen.

**The adversary is a test fixture and is never installed.** `make security`
builds it under `build/`; `install` deliberately omits it. Shipping a keylogger
in the image would be indefensible.

Two findings from running it, both of which changed the design:

- **Freezing the user session is not sufficient on its own.** A frozen
  `GetAsyncKeyState` poller recovers the *distinct characters* of anything typed
  while it was frozen, on its first poll after thaw — the "pressed since last
  call" bits accumulate and are not cleared by the freeze. Proven, not
  supposed. The load-bearing defense is therefore #3 below, not the freeze.
- **Cross-display isolation holds.** A secret typed into a separate display
  server never reached an adversary on the user's display. This is the property
  the compositor must provide: lock input goes to the lock surface's display,
  never the user session's, so there is nothing to accumulate.

The gate models this with two display servers and a distinct-character analysis
(order and repeats are lost to `GetAsyncKeyState`, so a secret "leaks" if any
character unique to it appears). It has a teeth check first — the adversary must
capture what is typed on its *own* display — because a gate that can catch
nothing proves nothing.

**`make test-security` is green, and has been seen to fail.** A mutant that
sends the lock secret to the user's display fails with the leaked characters
named, so the pass means something. Adding a case that runs the adversary as a
capture/inject client is open work until `sg-compositor` exists.

Three things that made this gate report nonsense before it worked:

- **Its cleanup used `pkill -f notepad.exe`**, which matches every process on
  the machine whose command line contains that string — including the shell
  that launched the gate, so it killed its own caller and "printed nothing",
  and in the field it would kill a user's real Notepad. Cleanup is
  `wineserver -k` on the test prefix and nothing else.
- **The adversary writes `\r\n`**, being a Windows program in text mode, so a
  `$`-anchored grep matched nothing and every capture read as empty — which is
  indistinguishable from "the adversary caught nothing". Strip `\r` first.
- **Fixed sleeps lose races with Wine's input processing** under load. The
  gate waits until the control secret is *seen* captured before running the
  real test.

Remote access ([ADR 0010](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/decisions/0010-remote-access-and-the-lock-screen.md))
funnels both console-shadow and pre-authenticated RDP through the same bridge,
so the credential always terminates at PAM. That is future work; the design is
recorded.

## The lock screen

`sg-lockd` (a machine-session service) WATCHes sg-compositor's control socket.
When the machine locks — Win+L, Ctrl+Alt+Del, `LockWorkStation()`, idle — it
runs `lib/sg-lock-ui`, which starts **its own X server** on the compositor's
privileged socket and the Windows-style greeter on it in lock mode
(`sg-greeter.exe /lock <user>`). What the greeter collects goes to PAM
(service `stained-glass-lock`) through a root monitor, as in `sg-rdp-authd`;
only a PAM yes sends `UNLOCK`.

- **Whose password** comes from `SO_PEERCRED` on the connection to the
  compositor, which runs as the session user — the kernel's word.
- **A lock UI that dies leaves the machine locked**: the compositor shows only
  privileged clients, so the screen is blank, and `sg-lockd` restarts the UI
  (with a 1s backoff, never a tight loop).
- **The lock screen's X server is separate from the session's on purpose.**
  While locked, the compositor routes input only to it, so the session's X
  server receives nothing for a keylogger in it to see (ADR 0009).

**`make test-lock`** runs it end to end, with keys injected over the privileged
virtual keyboard the way remote access types: teeth first, then Win+L locks,
the lock screen appears, a wrong password is refused, the right one unlocks and
the UI goes away — and not one key typed at the lock screen reaches the user
session. PAM is real, under `pam_wrapper`.

**The greeter reads its pipe on a thread.** It used to poll with
`PeekNamedPipe`, which fails with `ERROR_NOT_SUPPORTED` on a Unix pipe
inherited through Wine — so the real greeter never read a byte from the bridge,
at the login screen either. The login-screen gate missed it because it stood a
shell script in for the greeter; `make test-lock` drives the real one.

## Remote login over RDP

`sg-rdp-authd` is pattern B of ADR 0010: the technician types the username and
password into the RDP client before connecting and lands in an unlocked desktop,
as with `mstsc`. It authenticates; streaming the session needs `sg-compositor`,
so it is **built and gated but not installed** — a login service that leads
nowhere should not run on machines. `make test-rdp` is the gate.

**Privilege separation, as in sshd.** At startup, as root, it forks a *monitor*
that keeps root and does exactly one thing: run `sg-rdp-pamcheck` for a
credential handed to it over a socketpair. The RDP side then drops to an
unprivileged account (all four UIDs, no supplementary groups — verified) before
the listener opens. The TLS key is read into memory before the drop and
`mlock`ed, so the key file can be root-only (0600). A failed guess costs 2s,
enforced in the monitor, where reconnecting cannot skip it.

**TLS plus PAM, not NLA, for local accounts.** Server-side NLA has to verify the
client's NTLM exchange, which needs every user's NT hash — the MD4 hashes
Windows keeps in the SAM and pass-the-hash attacks go after. We store none;
PAM checks the password against the normal store. Domain accounts get NLA via
Kerberos in Phase 2, which needs only the machine keytab. Until then a
`DOMAIN\user` login is refused, so it can never fall through to a local
account of the same name.

Things that will bite you:

- **FreeRDP 3's `Logon` hook is not an authentication point under TLS.** It
  runs during negotiation, *before* the client has sent a credential (empty
  identity, `automatic=FALSE`), and the connection continues whatever it
  returns (`libfreerdp/core/peer.c`, `CONNECTION_STATE_NEGO`). The first build
  here let a refused logon through to the session stage. Authentication is in
  `PostConnect`, from the Client Info packet, and every connection starts
  unauthenticated — default deny.
- **The client sends the password only with `INFO_AUTOLOGON`**, which the
  FreeRDP client sets whenever it has a username and password on a TLS
  connection. A client with no credential is refused; showing it the on-screen
  login instead, as Windows RDP does, is the compositor's half.
- **The gate runs PAM for real** under `pam_wrapper`/`pam_matrix`, so it needs
  `libpam-wrapper`. It has been seen to fail: a build that ignores the PAM
  verdict fails with "a refused logon reached the session stage".

## The login screen

`sg-greeter` is a **Windows program**, deliberately. Remote-support tools —
RMM, RDP, ScreenConnect and friends — are Windows programs that attach to the
console session and expect a Windows login screen there. A Linux greeter is
invisible to every one of them, and a fleet machine that cannot be reached when
logged out is not supportable. See
[ADR 0008](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/decisions/0008-wine-side-login-and-lock.md).

**It decides nothing.** `sg-greet-bridge` hands what it collects to greetd, and
PAM stays the only authority, so account expiry, lockout and later domain auth
keep working untouched.

**The transport is a pair of inherited pipes**, not a socket. Wine has no
`AF_UNIX` (`socket()` returns `WSAEAFNOSUPPORT` — tested, not assumed), and a
loopback port would be reachable by every local user and need a shared secret
to close that hole again. The bridge creates the pipes and forks the greeter,
so nothing else can connect to it. It has no listening socket at all.

**`make test-greeter` is the gate.** It drives the bridge against a stub that
speaks greetd's real wire format, because the failures worth catching live
there: a length prefix in the wrong endianness, a password that ends the JSON
string early, replies read out of order. Mocking above the protocol catches
none of them. It checks that a wrong password is refused and that **the session
starts with the bridge's configured command, never one the greeter asked for** —
a tampered greeter must not be able to choose what executes.

Things that caught me out:

- **A transparent static never erases what it drew.** Returning `NULL_BRUSH`
  from `WM_CTLCOLORSTATIC` and then changing a control's font leaves the old
  text underneath the new one — two titles in two sizes, which reads as a font
  bug and is a painting one. Fonts are set once, at creation.
- **The greeter must never block on its pipe.** It polls with
  `PeekNamedPipe` from a timer; a login screen that stops repainting while PAM
  thinks is indistinguishable from a hung machine.

## Bundled Windows applications: PowerShell 7 and Python

`sg-install-apps` installs what the image stages under `SG_APPS_DIR`
(`/opt/sg-apps`) -- upstream PowerShell 7 and CPython Windows builds -- into
`C:\Program Files\PowerShell\7` and `C:\Program Files\Python3xx`, adds them to
the machine PATH, registers Python under PEP 514
(`HKLM\Software\Python\PythonCore\3.xx`) and writes all-users Start-menu
shortcuts (via Wine's `cscript` and `lib/sg-mklnk.js`; Wine has no command-line
`.lnk` writer). `sg-apps-check` is the gate: both found by bare name through
cmd's PATH lookup, versions, exit codes, pip, the registration, and shortcuts
that point at the right program.

- **Real copies, marked `.sg-bundled`**, replaced wholesale when the payload's
  `VERSION` changes. A directory without the marker is someone else's and is
  left alone.
- **pwsh needs a console.** With no console and its output redirected, its
  ConsoleHost throws a NullReferenceException on Wine; the gate runs it under
  `script(1)`. Launched from the desktop it has a console window and is fine.
  Worth a Wine fix before PowerShell runs unattended (login scripts, RMM).

## Never disable mscoree/mshtml for more than one command

`sg_wine_env` used to export `WINEDLLOVERRIDES=mscoree,mshtml=` to stop Wine's
Mono and Gecko installer prompts. Everything inherits that environment -- the
desktop, every program started from it, the machine's Windows services -- and
with mscoree disabled Wine cannot load a .NET assembly: PowerShell 7 died with
"Could not load file or assembly System.Runtime.dll", and so would any .NET
service or application. The override now lives only in `sg_wine_unattended`,
used for `wineboot --init`; on later boots `sg-prefix-init` starts one Wine
command under it, so an update after a Wine upgrade happens there rather than
inside a user's desktop.

**Log Windows paths with printf, not echo.** dash's `echo` interprets
backslash escapes: `...PythonCore\3.14` printed as an octal control
character, and `...PowerShell\7\...` lost its `\7`. That second one sent a
diagnosis down a false trail (a "missing path component" that was never
there). `sg_log` and the new gates use `printf '%s\n'`.

## Direct3D

`sg-install-d3d` copies DXVK and VKD3D-Proton into the prefix when the image
staged them at `SG_D3D_DIR` (`/opt/sg-d3d`), and `sg-d3d-check` is the gate.
Absent payload is a supported configuration: the prefix keeps Wine's own D3D
and the gate skips.

**64-bit DLLs go to `system32` and 32-bit to `syswow64`.** That is the Windows
layout and the opposite of what the names suggest. DXVK calls its 32-bit
directory `x32` and VKD3D-Proton calls it `x86`; both mean i386.

**Overrides go in HKLM, not HKCU.** Upstream Wine reads `DllOverrides` from
HKCU only, which in a shared prefix means per user — an administrator would
have to write into every existing hive and every future one. `wine-sg` patch
0009 adds HKLM as a machine-wide default. Without that patch the DLLs are
installed and inert, and **nothing reports an error**: Wine just loads its own
builtins.

**The gate creates a real device.** `test/d3d-probe.c` is built as a Windows PE
for both architectures (`make d3d-probe`, needs mingw) and shipped in the .deb,
because the image has no cross-compiler. File and registry checks cannot
distinguish a working installation from an inert one; `D3D11: OK` and
`D3D12: OK` can.

## The S2 gate

`make test-multiuser` (root) runs `bin/sg-multiuser-check`, which encodes the
five clauses of the S2 gate verbatim from the brief. `sg-image`'s
`make multiuser-test` drives the same check against a booted image.

**It is expected to fail — 4 of 5 today — and that is its job.** Clauses 1, 2,
4 and 5 pass on a Wine with `wine-sg`'s `patches/sg` applied, with
`sg-wineserver.service` running. Only clause 3 is open, and it is blocked on a
design decision rather than on code — see issue #8. Do not "fix" it
by weakening a clause. It is deliberately excluded from `make test` and from CI,
because a known-red gate sitting in CI would mask real regressions.

Each clause reports separately, and clauses that cannot yet be attempted say
what blocks them rather than failing bare.

**Run it against a settled prefix.** The gate starts processes as two users; run
straight after `sg-prefix-init` it can race that prefix's wineserver still
shutting down, and report clause 1 failing for a reason that has nothing to do
with the code.

Background: [`stained-glass/docs/s2-wineserver-analysis.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/s2-wineserver-analysis.md).

## Single-user assumptions

This package is full of them, deliberately. Every one is tagged
`MULTIUSER-DEBT: D<n>` in the code and listed in
[`stained-glass/docs/multiuser-debt.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/multiuser-debt.md).
**If you add another, add it to that list too.** It is the input to S2.

## License

**AGPL-3.0-or-later.** See [ADR 0004](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/decisions/0004-licensing.md).

One consequence worth knowing before you write code here: **AGPL-3.0 cannot be
incorporated into Wine, which is LGPL-2.1+.** If you find yourself fixing
something that really belongs in Wine, it does not belong in this repo — it
belongs in `wine-sg` as an upstreamable patch. Writing it here quietly forecloses
sending it upstream.
