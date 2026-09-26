# sg-session — session glue

Brings up a Stained Glass desktop session: a compositor hosting Wine's
`explorer` as the shell, against a **system-wide** Wine prefix rather than a
per-user one.

Project brief: [`stained-glass/docs/BRIEF.md`](https://github.com/Stained-Glass-OS/stained-glass/blob/main/docs/BRIEF.md).

## Trademark: we never call ourselves Windows

"Windows" is Microsoft's trademark; no user-visible text of ours uses it as
our product's or a feature's name. `make lint` runs `tools/trademark-check.py`
(the same checker as sg-shell's and wine-sg's) over the greeter, Setup, the
OOBE and the tools: string literals in C, the Python and shell tools'
messages (not comments, docstrings or test/). Paths, dotted identifiers and
the `.reg` header pass; other exceptions are in `tools/trademark-allow.txt`,
each with its reason (describing compatibility, or Setup naming Microsoft's
operating system already on the disk).

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
| `bin/sg-update-prepare` | downloads updates for the next reboot to install (see below) |
| `bin/sg-wineserver` | **the machine-level wineserver**: the Windows system itself |
| `bin/sg-services-start` | starts the SCM inside it, as SYSTEM |
| `systemd/sg-prefix-init.service` | first-boot fallback if the image didn't bake a prefix |
| `systemd/sg-wineserver.service` | runs the machine-level server before greetd |
| `bin/sg-install` | installs the live system onto a disk (see below) |
| `setup/` | Setup: the wizard, its bridge, and `sg-installd`; the first-run setup (OOBE): `sg-oobe`, `sg-oobed` |
| `bin/sg-netctl` | network settings: the CLI, sg-netd, and the bridge for Windows programs (see below) |
| `bin/sg-settingsctl` | Settings' native half: sound, Bluetooth, display modes, night light, idle timers, pending updates (see below) |
| `bin/sg-sysinfo` | the administrative tools' Linux side: devices, disks, units, the journal, accounts, shares (see below) |
| `bin/sg-pdf` | the PDF Viewer's Linux half: poppler renders pages and reports text, links, outline and search hits over the viewer's bridge (see below) |
| `speech/sg-dictate`, `speech/sgspeech.py` | voice typing's engine, its bridge, and sg-speechd, the model download (see below) |

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

## The machine's server must own the prefix

Any Wine command run before `sg-wineserver` starts (sg-prefix-init's, at
boot) runs on a transient server of its own. It used to exit when idle, but
auto-start services -- Microsoft Edge installs three -- keep it alive, and the
machine's server then found the prefix taken, exited with status 2, and the
greeter ended up on the transient one. sg-prefix-init now stops its server on
exit (a trap; its `wineserver -w` is bounded, since services never exit), and
sg-wineserver stops any server holding the prefix before it starts. **The
tell:** `sg-wineserver.service: Main process exited, status=2` at boot, and a
second `wineserver` without `-p -f` in `pgrep -a wineserver`.

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
- **The desktop is sized to the output.** `sg-run-explorer` measures the X root
  window, which is the compositor's output, and runs `/desktop=shell,WxH` at
  that size. A fixed default would leave a larger screen unfilled, or ask for a
  mode the output cannot show. `SG_DESKTOP_AUTO=0` keeps `SG_DESKTOP_W`x`_H`.
  Wine clamps a larger request to the output anyway.
- **The machine's Windows system never uses a display.** `sg-prefix-init`,
  `sg-wineserver` and `sg-services-start` unset `DISPLAY`/`WAYLAND_DISPLAY`.
  Whatever screen they were started from (a build host, a developer's desktop)
  must not be recorded as the machine's monitor.
- **`SG_TEST_HOLD`** runs a command against the live gate session after the
  result is taken, e.g. `wine reg query ...`. Note that reg.exe itself runs a
  display update and can perturb display state.
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

**The template must name no one's profile** (debt D15). Wine writes the
owner's -- SYSTEM's -- profile path into the hive as absolute strings, so a
plain copy gave every user SYSTEM's TEMP and Shell Folders, which since ADR
0013 they cannot even write. `sg-prefix-init` therefore rewrites
`C:\users\<owner>` to `%USERPROFILE%` (REG_EXPAND_SZ) and drops the cached
Shell Folders and Volatile Environment. That relies on wine-sg 0018, which
defines `USERPROFILE` before `HKCU\Environment` is expanded. (Also: the
"Volatile keys are never written to disk" above is not true of Volatile
Environment, which is why it is dropped explicitly.)

**The profile directory comes from `sg-profile-create`** -- Windows' profile
service. `pam_exec` runs it as root at every session open (registered through
`pam-auth-update`, `config/pam-configs/stained-glass-profile`, so greetd, ssh
and anything else using `common-session` get it). It creates
`C:\users\<name>` owned by the user, 0700, for members of `sgwine`, then the
standard folders -- **as the user, with `runuser`**: root walking a tree the
user owns can be steered with a symlink. A user cannot do this themselves:
`C:\users` is SYSTEM's. Without it, `%TEMP%` does not exist, csc fails, and
PowerShell falls into ConstrainedLanguage mode (it probes `%TEMP%` for
AppLocker).

It also plants the **Send to** items Windows' Default profile has, as empty
files whose extension says what they do (wine-sg 0156 reads them):
`Compressed (zipped) Folder.ZFSendToTarget` (sg-shell's zip reg gives that
type a `sendto` command), `Desktop (create shortcut).DeskLink`,
`Documents.mydocs` -- **once per profile** (marker
`AppData\Local\Stained Glass\sendto-defaults`), so a profile made before
gets them at its next login and an item the user deleted stays deleted. Gate:
`make test-profile` (root; a second account, default `sgconf`).

## The per-user process agent (sg-procagent)

`sg-procagent` (native C, `procagent/`) runs **as each session user**, launched
by `sg-session-start`. The machine-level wineserver runs as SYSTEM and the
kernel refuses it `ptrace`/`tgkill`/`sched_setaffinity` on an ordinary user's
processes, so the server **delegates** those to this agent (wine-sg patch
0021, ADR 0014): cross-process `ReadProcessMemory`/`WriteProcessMemory`,
`DebugActiveProcess` (PEB write), async-APC thread signals, thread affinity.
The agent performs them on its own user's processes, where the kernel allows
it — it gains **no** privilege.

- It binds `<prefix>/.sg-procagent.<uid>` (0660, group = the prefix group, so
  the SYSTEM-account server can reach it and nothing wider) and serves the
  wireserver's requests. The wire protocol must match `server/ptrace.c` in
  wine-sg (see that repo's CLAUDE.md); if you change one, change both.
- It touches only its own uid's processes (kernel-enforced), so a compromised
  server gains nothing by asking it to.
- Gate: `sg-procagent-check` runs `sg-procmem-probe.exe` and is mutant-proven —
  cross-process memory succeeds with the agent, is refused without it. In the
  image, `make procagent-test`. The gate starts and stops its own agent because
  it runs outside a graphical session.

## Token gate

`sg-token-check` (root, in the image: `make token-test` in sg-image) runs
`sg-token-probe.exe` and its `requireAdministrator` twin as the ordinary user
and as SYSTEM: every attempt to obtain an administrator's token must be denied
to the user (debt D17, wine-sg 0019) and granted to SYSTEM, which proves the
probe can tell.

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

**Keys held when the screen appears are not typing.** The L of Win+L is
often still down when the lock screen comes up (later still with pixman
rendering), and its auto-repeat filled the password box and lifted the
curtain -- then "The password is incorrect". As on Windows, the greeter
ignores a key that was down before it appeared (`GetAsyncKeyState` at
start, or a first message that is already a repeat, lParam bit 30) until it
is released. `make test-lock` locks with Win+L's L held 4 s across the lock
(`sg-vkbd -D l ... -s 4 -U l`) and requires the first password to unlock,
then re-locks for the refusal checks; the old greeter fails it (sg-lockd
refuses the "lll..." password, and the curtain is gone).

**The greeter reads its pipe on a thread.** It used to poll with
`PeekNamedPipe`, which fails with `ERROR_NOT_SUPPORTED` on a Unix pipe
inherited through Wine — so the real greeter never read a byte from the bridge,
at the login screen either. The login-screen gate missed it because it stood a
shell script in for the greeter; `make test-lock` drives the real one.

### The lock screen's picture and clock

Windows 10's lock screen: the picture chosen in Settings > Personalization >
Lock screen fills the screen with the time and date at the bottom left (the
"curtain"); a key, a click or the wheel lifts it to the sign-in pane -- the
same picture shrunk to 1/24 and grown back, dimmed (a cheap acrylic), with
the account's initial in an accent circle, or the plain blue when "Show lock
screen background picture on the sign-in screen" is off. The login screen
has the curtain too, over the system's picture
(`/usr/share/stained-glass/wallpapers/stained-glass.jpg`,
`SG_LOCK_DEFAULT_PICTURE`); `SG_GREETER_CURTAIN=0` turns it off.

- **The key that lifts the curtain is not lost**: it goes on to the box that
  now has the focus (Enter, Escape and Space only lift it). Every gate and
  remote-support tool that just starts typing keeps working -- sg-image's
  login typing ("x", BackSpace, the name) and `make test-lock` unchanged.
- **The machine account draws the lock screen and must not read the user's
  files or a path the user names.** Settings publishes the choice as the
  user (`sg-settingsctl lockscreen picture FILE|default`, `lockscreen signin
  yes|no`) into `/var/lib/stained-glass/lockscreen` (tmpfiles, 1733: anyone
  may create, nobody may list or replace another's file): `<user>` the
  picture (JPEG/PNG/BMP/GIF by magic, at most 32 MB, mode 0644) and
  `<user>.signin`. At every lock, sg-lockd opens `<user>` with `O_NOFOLLOW`,
  requires a regular file owned by the session's uid, at most 32 MB, a
  picture's magic, and copies it **from that descriptor** into a private
  `mkstemp` file (`SG_LOCK_PICTURE` for the UI, deleted when the UI stops).
  Anything else -- a symlink, a planted file owned by someone else, a
  non-picture -- is ignored and the system's picture shows. A user who
  plants a file under another's name only costs that user their picture
  (they fall back to the default). The published pictures are readable by
  other local users (sgwine traverses `/var/lib/stained-glass`), like a
  wallpaper would be.
- **The greeter decodes with WIC** (`\\?\unix\` path, 32bpp BGR) and scales
  it itself: an area average when shrinking, bilinear when growing, "Fill"
  cropping. Statics over the picture erase with a pattern brush of the
  blurred picture aligned to the control, so the old warning about
  transparent statics still holds.
- **Gate: `make test-lockpic`** (`test/lockpic-e2e.sh`, Xvfb, its own
  prefix): sg-settingsctl refuses a non-picture and publishes a picture and
  the switch as the user's own files; `sg-lockd --stage-picture USER` (the
  service's staging, as a hook) stages it, refuses a symlink and a published
  non-picture; the real greeter shows the picture's colours with the clock's
  white at the bottom left and no form; typing "alice" + Enter lifts it and
  arrives whole ("USER alice"), over the dimmed picture with the clock gone;
  ShowOnSignIn off gives the plain colour (a JPEG); lock mode's account
  circle (a BMP); no picture: plain colour with the clock. Mutants: a
  greeter ignoring the picture (`-DSG_MUTANT_NOPIC`, 6 fails), the old
  greeter (9), one that eats the lifting key ("USER lice"), an sg-lockd
  without `O_NOFOLLOW`/owner check -- each red (`SG_GREETER=`, `SG_LOCKD=`).
  **`make test-lock`** now also publishes a picture, requires it staged while
  locked, reads the lock X server's pixels (`xwd -root`), and requires the
  staged copy gone after unlocking. Its first run on a fresh prefix can miss
  the 60 s window for the lock screen (Wine's first start); run it again.
- **Not yet:** the curtain does not come back after a minute idle, no
  slide-up animation, no Windows Spotlight, no notifications on the curtain;
  a picture chosen before this existed is not published until chosen again.

## Run as administrator: the consent prompt

`sg-brokerd` (ADR 0012) asks on the **secure surface**. It finds the
requester's compositor (`<seat>/<uid>/control.sock`, and it must be served by
that uid according to `SO_PEERCRED`), sends `SECURE`, and runs `lib/sg-consent-ui`: its own
X server on the privileged socket and `sg-consent64.exe` on it. An
administrator gets Yes/No. Anyone else must give an administrator's name and
password; the root monitor checks the password with PAM (`stained-glass-elevate`)
and the broker checks membership of `sg-admins`. Three wrong tries, a closed
prompt or 120s of silence all deny, and so does everything else. `RELEASE`
follows in every case. In SECURE mode the compositor tells watchers `secure`,
not `locked`, so `sg-lockd` puts no lock screen over the prompt.

**`make test-consent`** runs the whole thing with PAM under `pam_wrapper`. It
checks that Escape declines, that Yes allows, that there is no prompt over a
locked machine, that a standard user's own password is refused, that a wrong
administrator password is refused and the right one accepted, and that no key
typed at a prompt reaches the session. It fails when the broker skips the
administrator check, and when it skips `SECURE`.

Things that bit:

- **Drive Wine prompts with `build/sg-vkbd`, not `wtype`.** wtype makes up a
  keymap per call and puts its first key on keycode 9. Until Wine notices the
  keymap change it reads that key as **Escape**. The first key of each call
  declined the prompt. That included the "warm-up" key, and an Escape test that
  "passed" did so by accident. sg-vkbd uploads the ordinary evdev/us keymap,
  so there is no change to race. `lock-e2e.sh` uses it too.
- **The prompt acts on key release, and only for a key whose press it saw.**
  It has no bare-letter shortcuts, only Alt+Y and Alt+N. Focus starts on No. A
  stray key must never answer an elevation prompt.
- **A control client that hangs up early used to kill the compositor**
  (SIGPIPE on the reply). This is fixed in sg-compositor. The broker still
  sends `STATUS` on its probe connection rather than connecting bare.

## Installing: sg-install and Setup

`bin/sg-install` installs the running **live** system. The live system is the
stick booted through its `-live` boot entry (`systemd.volatile=overlay`, added
by sg-image's `mkosi.postoutput`): `/` is an overlay on a tmpfs, and the
stick's root partition underneath is mounted read-only. sg-install mounts that
partition read-only again and **copies its files** into a fresh ext4 on the
target (a file copy, so any partition big enough works and nothing else on
the disk moves). The copy is then made a machine of its own: an empty
machine-id, the chosen host name, ssh host keys generated on first boot, the
keyboard layout, the lab account `sguser` removed, and the owner created in
`sgwine`, `sg-admins` and `sudo`. Nothing from the live session reaches the
installed machine: the source is the pristine read-only root, and the Wine
prefix is built on its first boot.

**Where it installs** -- `--layout` lists every disk it may touch with its
partitions and unallocated space; `--new`, `--delete` and `--format` change
them (applied immediately, as in Windows Setup); the install goes to one of:

- `--free DISK:START:SECTORS` -- unallocated space, exactly as `--layout`
  reported it. On a disk with no EFI system partition, a 512 MB one is made
  there first and the kernels go in it; on a disk that has one (Windows'),
  **a 1 GB extended boot loader partition (XBOOTLDR) of our own** is made
  beside the root, and the kernels go there. gpt-auto mounts it at `/boot`
  and the ESP at `/efi`; systemd-boot in the ESP finds it on the same disk.
- `--target PARTITION` -- an existing partition, formatted. The disk must
  have an ESP (else the Windows message: unable to create or locate a system
  partition); the kernels go into it under `stained-glass/` (the entry
  token), so they cannot collide with another Linux's `debian/`.
- `--disk DISK` -- the whole disk, erased: a new GPT, then as `--free`.

**Booting beside another system.** The root is named on the kernel command
line (`root=PARTUUID=... rw`, also in `/etc/kernel/cmdline` with the entry
token in `/etc/kernel/entry-token`, so later kernels match). In a shared ESP,
`EFI/systemd/` is ours; the firmware fallback `EFI/BOOT/BOOTX64.EFI` is written
only where nothing is; `loader/loader.conf` only when absent or ours (`#
Stained Glass OS` first line) -- with `timeout 5` when a Windows boot manager
is there, so the menu shows (systemd-boot lists Windows itself). efibootmgr adds
"Stained Glass OS" first in the firmware boot order, as Windows Setup does.
Nothing else in the ESP, and no partition that was not chosen, is touched.

- **Where the live root is.** systemd 257 does not expose the lower layer at
  `/run/systemd/volatile-root` -- it is `/sysroot` in the initrd's namespace.
  sg-install takes the root-type partition on the ESP's disk (GPT
  auto-discovery, as at boot) and requires the kernel's ext4 state
  (`/proc/fs/ext4/<dev>/options`) not to be `rw`. One superblock, one state.
  The ESP is an automount: sg-install touches `/boot` and `/efi` before
  looking for it.
- **Refused:** the disk it runs from (any operation), MBR disks (UEFI
  installs to GPT, as Windows'), partitions in use, system/MSR/boot/recovery
  partitions as the root, a root under 10 GB, formatting a system partition.
- **The live overlay is small** (under 1 GB on a 4 GB machine) and the Wine
  prefix alone is ~650 MB: sg-image mounts a tmpfs of its own on
  `/var/lib/stained-glass` on live boots.
- **`SG_INSTALL_DISKS`** (tests only) replaces disk discovery with the given
  devices -- loop devices, for trying `--layout`/`--new`/`--delete` on
  scratch files. Never point it at a real disk.
- **`userdel -r` exits non-zero after removing an account** with no home or
  mail spool; sg-install checks that the account is gone instead.
- **After mkfs, `lsblk` is stale until udev re-probes**: sg-install triggers a
  `change` event, or Setup would show a just-formatted partition as empty.

**Setup** is the wizard around it, and looks like Windows Setup: language and
keyboard, Install now, license terms, installation type, account ("Who's going
to use this PC?"), "Where do you want to install Stained Glass OS?" (the
partitioner: Refresh, Delete, Format, New, with Windows-like warnings), Ready,
Installing (the step list and a progress bar under "1 Collecting information /
2 Installing"), then a 15-second restart countdown. Our own drawing: a
stained-glass backdrop, the four-pane mark, and its icon (`setup/make-icon.py`,
generated at build time into the exe's resources).

On a live boot `sg-login-ui` starts `sg-setup64.exe` full screen where the
login screen would be; it asks `sg-setup-bridge`, which asks `sg-installd` --
root, socket-activated, one instance per connection -- to run sg-install.
The socket (`/run/stained-glass-setup/installd.sock`, root:**sgsetup** 0660)
exists **only on a live boot** (`ConditionKernelCommandLine=`). Group
`sgsetup` is the login screen's account and the live session's. The wizard
decides nothing; sg-installd checks each request against sg-install's own
`--layout`, and sg-install validates everything again.

**The live session ("Try Stained Glass OS", the hybrid).** `sg-live.service`
(live boots only) runs `setup/sg-live-setup` before greetd: it creates the
account `live` -- no password, groups sgwine, sgsetup, sg-admins -- in the
volatile overlay, so it is never on the stick's root (sg-install refuses if it
ever is), and puts "Install Stained Glass OS" (`Z:\usr\libexec\stained-glass\sg-setup64.exe`)
on the all-users desktop and Start menu, as SYSTEM through `sg-mklnk.js`.
Setup's Try link sends `TRY`; the bridge writes `try` to `$SG_SETUP_RESULT`;
`sg-login-ui` then runs `sg-greet-bridge` with `SG_GREET_AUTOLOGIN=live`,
which asks greetd for that account's session with no greeter -- **only on a
live boot and only for `live`** (the login gate checks the refusal), and PAM
still decides (`nullok`). Logging out returns to Setup. The shortcut starts
sg-setup64.exe without a bridge; it then starts one itself
(`\\?\unix\usr\bin\systemd-cat -t sg-setup sg-setup-bridge "wine sg-setup64.exe --windowed"`),
which runs it again, windowed (`SG_SETUP_BRIDGED` tells them apart).

- **Never put a socket under `/run/stained-glass`.** It is sg-wineserver's
  `RuntimeDirectory`: systemd chowned the installer's socket to sgsystem, and
  would delete it whenever that service stops. Setup's is in
  `/run/stained-glass-setup`; the install gate checks its owner and mode.
- **The wizard acts on Enter/Escape release, for a press seen on the same
  page**; "Ready to install" opens with focus on Back; destructive warnings
  open on Cancel. A key held on one page must never answer "erase this". It
  logs each page change (`sg-setup: page <name>`), the rows it selects
  (`sg-setup: selected Drive 0 Partition 2`) and layouts, journal tag
  `sg-setup`, which is what the gates wait on.
- **Gates:** `make test-setup` runs the real wizard, bridge and sg-installd on
  this machine under xvfb, with a stand-in sg-install that keeps a Windows-like
  layout: license acceptance, password mismatch, preselection, New, Delete
  through its warning, nothing else touched, Back on Ready, the arguments and
  password on stdin, restart, and Try (screenshots in
  `build/artifacts-setup/`). sg-image's `make install-test` runs two scenarios
  in QEMU: **blank** (Try -> the live desktop's session gate -> Setup from the
  desktop shortcut, windowed -> New on a blank disk -> install) and
  **dualboot** (a Windows-shaped disk; install into its unallocated space; the
  Windows boot manager, MSR and data partitions and their table entries
  byte-identical afterwards), each followed by the full boot gate on the
  installed disk alone.

## The first-run setup (OOBE): sg-oobe and sg-oobed

The installed machine's first boot shows Windows 10's out-of-box experience
**in the login screen's place, before anyone signs in** -- the choice made:
Windows' OOBE runs before any user session too, and here that keeps it off
any user's desktop (nothing of a session exists yet to be observed), reuses
Setup's proven shape (a Windows program the bridge feeds, a root service that
decides), and needs no autologin. sg-install writes
`/etc/stained-glass/oobe.pending` into the machine it installs; `sg-login-ui`
sees it and runs `sg-setup-bridge --oobe "wine sg-oobe64.exe"` in a
compositor; whatever happens it then exits, and greetd starts it again: the
login screen (with the keyboard just chosen), or the first-run setup again if
it did not finish. `SG_OOBE=0` skips it.

**It never keeps the machine from its login screen**: it is not shown
without its service's socket; if its window has not appeared within
`SG_OOBE_TIMEOUT` (300 s; the bridge touches `SG_OOBE_READY` on the
wizard's HELLO) it is stopped; after three runs that did not finish this
boot shows the login screen (a per-boot count in /tmp). The marker stays, so
the next boot offers it again. `test/oobe-fallback-test.sh` (in `make lint`,
stand-ins, no Wine): ready, hang, crash loop, no socket; the version without
these fails three of four.

Pages (`setup/sg-oobe.c`, our own drawing: a stained-glass backdrop, a card
with the page's picture and Basics / Network / Account / Services on the left,
the page on the right, purple buttons): **region** ("Let's start with region.
Is this right?", preselected from Setup's keyboard) -> **keyboard** (Setup's
layout preselected) -> **a second layout?** (Add layout / Skip; two layouts
switch with Windows logo key + Space, `grp:win_space_toggle`) -> **network**
(the wired adapter and Wi-Fi networks from sg-netctl, a key field for a
secured one, Connect; Next when online, "Skip for now" when not) ->
**account** (only when there is no administrator; Setup always makes one) ->
**privacy** (Location, Microphone -- voice typing --, Tailored experiences,
Advertising ID switches; diagnostic data is *none*, stated, not offered) ->
**a web browser** (Firefox, Firefox ESR, or none; offline: none, said so) ->
"Hi. We're setting things up" -> "All set." and it closes.

`setup/sg-oobed` (root, `sg-oobed.socket`, `/run/stained-glass-oobe/oobed.sock`,
root:**sgsetup** 0660 -- the login screen's account; `ConditionPathExists=` the
marker) answers `STATE`, `NETWORKS`, `CONNECT`+`KEY` (sg-netctl, the key on
its stdin), `ACCOUNT`+`PASSWORD` (refused when an administrator exists;
sg-install's name rules; useradd into sgwine/sg-admins/sudo, chpasswd on
stdin) and `FINISH`. It refuses everything once the marker is gone. FINISH
checks each value against a fixed list or pattern (locale `xx-YY`, a numeric
country, known layouts, 0/1 switches, an offered browser) before writing:

- `/etc/default/keyboard` (+ `/etc/vconsole.conf`). **Nothing read that file
  before**: the compositor's keymap came from nowhere, so Setup's keyboard
  choice never reached the desktop. `sg-common.sh` now exports
  `XKB_DEFAULT_LAYOUT/VARIANT/OPTIONS/MODEL` from it for every compositor
  (login screen, session, and so the lock screen too).
- HKLM as SYSTEM (runuser sgsystem, `reg import`): the device's microphone
  and location ConsentStore switches, `Policies\Microsoft\Windows\DataCollection`
  `AllowTelemetry=0`.
- `/etc/stained-glass/oobe.conf`: the region (locale, country), layouts and
  their Windows ids, the per-user switches, a stamp. `lib/sg-oobe-user`
  (sg-run-explorer, before the shell) applies it to each user's HKCU once, at
  their first sign-in: `Control Panel\International` LocaleName and
  `Geo\Nation`/`Name`, `Keyboard Layout\Preload`, ConsentStore (and
  NonPackaged), AdvertisingInfo, Privacy; marked in `HKCU\Software\Stained
  Glass\OOBE\Applied`. **The format only sticks with wine-sg 0168**: Wine
  rewrote `International` to the Unix locale at every process start.
- The browser: `/var/lib/stained-glass/oobe-browser` and
  `sg-oobe-browser.service` (also at each boot while the request is there):
  `lib/sg-oobe-browser`, as SYSTEM, `winget install --scope machine` when
  the user has installed winget, else the publisher's own download link
  (Mozilla's, HTTPS only) run silently. Nothing is shipped in the image.

Keys as in Setup (Enter/Escape on release, for a press seen on the page); a
privacy switch turns with Space, Enter there accepts the page. It logs
`sg-oobe: page <name>`, `selected <row>`, `networks N online=yes|no`,
`toggle <switch> on|off`, `done` (journal tag `sg-oobe`), which the gates
wait on.

**Gates:** `make test-oobe` (`test/oobe-e2e.sh`, xvfb): the real wizard,
bridge and sg-oobed with stand-ins for sg-netctl, nmcli, the account tools,
systemctl and the HKLM import -- region preselection, United Kingdom, US +
German, a Wi-Fi key on sg-netctl's stdin only, no account page with an owner,
the switches, Firefox handed to the service, the marker gone and the window
closed; then no administrator and offline: skip, the account page, a
mismatch refused, the account's groups and password on stdin, no browser;
sg-oobed refusing after done and outside its lists. Screenshots in
`build/artifacts-oobe/`. Mutants seen red: the wizard ignoring `ACCOUNT no`,
sg-oobed without its done check, without the console keymap. sg-image's
`make install-test` walks it in QEMU after the installed disk's first boot
(`test/oobe-walk.sh`) and checks the owner's session got the region
(`en-GB`, dd/MM/yyyy, country 242), layouts and switches;
`SG_MUTANT_NO_OOBE=1` removes the marker before the restart and must fail.

## Third-party drivers: sg-drivers

`bin/sg-drivers` (root) is Windows Update's "optional drivers" / Ubuntu's
"additional drivers": what this PC needs from Debian's **non-free** archive
(sg-image's apt sources carry `main contrib non-free non-free-firmware`), and
installing it. **It is the interface for the Control Panel's future drivers
page** -- call it through the elevation broker, parse its lines:

| Command | Output |
|---|---|
| `sg-drivers --list` | `DEVICE <slot>\t<vendor:device>\t<what>\t<packages or ->\t<note>` per device that wants something |
| `sg-drivers --recommended` | the packages still to install, space separated, one line (empty: none) |
| `sg-drivers --install-recommended [--pending]` | installs them with apt (stderr: progress); exit 0 when done or nothing to do |
| `sg-drivers --status` | `STATUS pending|none`, then `INSTALLED <package>` lines |
| `sg-drivers --secure-boot-enroll [--root DIR]` | with Secure Boot on: `MOKPASSWORD <8 digits>` |

- **NVIDIA: Debian's `nvidia-detect` decides** (in the image; it carries
  Debian's per-driver ID lists and knows the release): `nvidia-driver` for
  Maxwell and newer, the Tesla series where it says so, and *nothing* for a
  card no trixie driver supports (Kepler and older -- 470/390 stopped at
  bookworm), which keeps nouveau. With a driver: `firmware-misc-nonfree`
  and `linux-image-amd64 linux-headers-amd64` (DKMS builds for the headers
  it has; the pair keeps kernel and headers in step), and
  `modprobe.blacklist=nouveau` on this root's boot entries and
  `/etc/kernel/cmdline` (Debian's package blacklists it in modprobe.d; an
  initrd built before it would not). Without the driver nouveau is untouched.
- **Firmware by vendor**: AMD graphics `firmware-amd-graphics`, Intel
  graphics `firmware-intel-graphics`, Wi-Fi `firmware-iwlwifi` (Intel),
  `-realtek`, `-atheros` (Qualcomm too), `-mediatek`, `-brcm80211`, and
  `broadcom-sta-dkms` only for the Broadcom chips only wl runs.
- **When**: Setup's "Install third-party drivers for graphics and Wi-Fi
  (recommended)" (checked by default, on the installation type page, which
  shows what the survey found) makes sg-install write
  `/etc/stained-glass/drivers.pending`; `sg-drivers.service` installs at the
  first boot after `network-online.target` and removes it, and retries every
  10 minutes and at the next boot while the archive is unreachable. **Not
  inside Setup**: DKMS and a kernel upgrade want the running system and its
  real boot partitions, not a chroot of a system that has never booted.
- **Secure Boot**: with it on (the `SecureBoot` EFI variable), sg-install
  runs `--secure-boot-enroll --root` on the new system: an RSA key made on
  the spot (`/var/lib/dkms/mok.key`, 0600; certificate `mok.pub`, DER),
  `/etc/dkms/framework.conf.d/50-stained-glass-mok.conf` pointing DKMS at it,
  and `mokutil --import` with a hash of an 8-digit one-time password.
  Setup's last page shows the password and the MokManager steps, and does
  not restart by itself. Off: nothing is made. **Open:** the image's own
  boot chain is not signed (systemd-boot without shim), so the media does
  not boot with Secure Boot on yet; this path is gated with the state forced.
- **Test inputs**: `SG_DRIVERS_PCI` (a file of `slot vendor device class`
  lines instead of the PCI bus), `SG_DRIVERS_NVIDIA_DETECT`, `SG_SECUREBOOT`,
  `SG_DRIVERS_ENTRIES` (where the boot entries are). Gates:
  `test/drivers-test.sh` (in `make test`'s lint block) and sg-image's
  install gate (the real nvidia-detect with fake devices, `apt-get -s` of the
  NVIDIA set against the archive, the forced Secure Boot enrollment, the
  first-boot service settling).

## Network settings: sg-netctl and sg-netd

The image runs **NetworkManager** (wired DHCP out of the box, Wi-Fi), feeding
systemd-resolved (which the DC and member roles configure). `bin/sg-netctl`
(Python, `/usr/bin/sg-netctl`) is the one backend for everything Windows-side
that shows or changes network settings: sg-shell's Network Connections
(`ncpa.cpl`) and taskbar network flyout today, `netsh`/`ipconfig` in wine-sg
next.

- **As a user it asks sg-netd**: `sg-netd.socket`
  (`/run/stained-glass-net/netd.sock`, 0666, `Accept=yes`) runs
  `sg-netctl --serve` as root per connection, which takes the caller's uid
  from `SO_PEERCRED` and decides, as Windows does: **anyone with a Windows
  session** (group `sgwine`; sg-admins; root) may list adapters, scan, join,
  disconnect and forget Wi-Fi and switch the Wi-Fi radio; **changing an
  adapter's addresses, DNS, or enabling/disabling/renewing/releasing it needs
  an administrator** (`sg-admins`). System accounts get nothing. As root it
  does the work itself.
- **polkit holds NetworkManager to the same line**
  (`config/polkit/50-stained-glass-network.rules`): sg-admins may do anything
  with nmcli; everyone else may only scan. Letting ordinary users drive NM
  would not keep the line -- a "modify.own" profile can be any type with any
  static address. The VM gate checks both halves.
- **The Wi-Fi key never touches a command line.** It arrives on stdin
  (`--password-stdin`) or in the request's `secret` field, and sg-netd writes
  the profile as a keyfile itself (0600 root,
  `/etc/NetworkManager/system-connections/sg-wifi-<uuid>.nmconnection`, the
  SSID as its exact bytes) and loads it. A network that cannot be joined is
  not remembered.
- **Wine gives a native program started from a GUI process no stdio**
  (`fork_and_exec` closes stdin/stdout when there is no inherited console), and
  Wine has no AF_UNIX. So a Windows program re-launches itself as
  `sg-netctl --bridge wine <itself> --bridged ...`: the bridge starts it with
  pipes as its standard handles and answers each request. sg-shell's
  `src/sg-netclient.h` is the client side.

**Interface** (stable; netsh/ipconfig will be built on it):

```
sg-netctl whoami                                   USER <name> / ADMIN yes|no
sg-netctl adapters [DEVICE]                        per adapter, a block:
    ADAPTER <dev>  TYPE ethernet|wifi|...  STATE connected|disconnected|connecting|unavailable|unmanaged
    MAC <aa:bb:..>  MTU <n>  [SPEED <Mb/s>]  RX-BYTES <n>  TX-BYTES <n>  DRIVER <name>
    [CONNECTION <profile name>  CONNECTION-UUID <uuid>  AUTOCONNECT yes|no
     IPV4-METHOD auto|manual|disabled  IPV4-DNS-AUTO yes|no  IPV6-METHOD auto|manual|disabled|...]
    IPV4-ADDRESS <a.b.c.d/p>*  [IPV4-GATEWAY <a>]  IPV4-DNS <a>*  DNS-SUFFIX <domain>*
    [DHCP4-SERVER <a>  DHCP4-LEASE-TIME <s>  DHCP4-EXPIRES <epoch>  DHCP4-OBTAINED <epoch>]
    IPV6-ADDRESS <addr/p>*  [IPV6-GATEWAY <a>]  IPV6-DNS <a>*  [SSID-HEX <hex>  SSID <text>]
    END
sg-netctl ipv4 DEV dhcp [--dns auto|A[,B,C]]                     (admin)
sg-netctl ipv4 DEV static A.B.C.D/P [--gateway G] [--dns A[,B,C]] (admin; no --dns: none)
sg-netctl ipv6 DEV auto|disabled | static ADDR/P [--gateway G] [--dns ...]   (admin)
sg-netctl dns DEV auto|A[,B,C]                                   (admin)
sg-netctl enable|disable|renew|release DEV                       (admin)
sg-netctl wifi scan [--rescan]
    WIFI <signal>\t<open|wpa-psk|sae|enterprise|wep>\t<in-use yes|no>\t<saved yes|no>\t<ssid hex>\t<ssid text>
sg-netctl wifi connect (--ssid TEXT | --ssid-hex HEX) [--hidden] [--security open|wpa-psk|sae]
                       [--no-autoconnect] [--password-stdin] [--device DEV]   -> CONNECTED <dev>
sg-netctl wifi disconnect [DEV]                                  -> DISCONNECTED <dev>
sg-netctl wifi forget (--ssid TEXT | --ssid-hex HEX)             -> FORGOTTEN <n>
sg-netctl wifi saved      SAVED <uuid>\t<autoconnect yes|no>\t<ssid hex>\t<ssid text>
sg-netctl wifi radio on|off|status                               -> RADIO enabled|disabled
```

The last line of every answer is `OK` or `ERROR <kind> <message>`, kind one
of `denied` (exit 3), `invalid` (2), `notfound`, `auth` (a wrong Wi-Fi key),
`unsupported` (enterprise/WEP Wi-Fi), `failed` (1). Inputs are validated
before NetworkManager hears of them: adapter names, addresses (no network,
broadcast, multicast or loopback address; the gateway on the subnet), one to
three DNS servers, WPA2 keys of 8-63 printable characters, SSIDs of 1-32
bytes. A fixed address has fixed DNS (or none), as on Windows. Bridge and
socket requests are one JSON line, `{"argv": [...], "secret": "..."}`.

- **nmcli leaves DHCP4 out of `device show`** unless asked by field
  (`-f GENERAL,IP4,DHCP4,IP6`), and puts a `Hint:` line after the `Error:`
  line: the error is the `Error:` line.
- **`sg-dc-provision` pins the DC's address**: if DHCP gave it, the adapter
  gets it as a fixed address (same prefix, gateway, upstream DNS) through
  sg-netctl before provisioning.
- **Gates:** `test/netctl-test.py` (in `make lint`; a stand-in nmcli: who may
  do what over the real socket protocol, validation before NetworkManager, the
  key on no command line and 0600, failed joins not remembered, the bridge);
  sg-image's `make net-test` (real NetworkManager in a VM: DHCP on two NICs,
  static and back as an administrator, refusals for a standard user through
  sg-netd and through nmcli, and Wi-Fi over mac80211_hwsim against an access
  point of the test's own: wrong key, join, a DHCP lease and traffic over the
  air, disconnect, rejoin with the saved key, forget, the radio).

## The administrative tools' Linux side: sg-sysinfo and sg-sysinfod

`bin/sg-sysinfo` (Python, stdlib only, `/usr/bin/sg-sysinfo`) is what
sg-shell's administrative tools (Device Manager, Disk Management, Event
Viewer's "Stained Glass" log, Services' Linux view, Computer Management's
Local Users and Groups and Shared Folders, System Information, Resource
Monitor, Disk Cleanup) know about the Linux machine under Wine. Same shape as
sg-netctl: a Windows program re-launches itself as `sg-sysinfo --bridge wine
<itself> --bridged ...` and writes one JSON line per request
(`{"argv": [...]}`); answers are lines, the last `OK` or `ERROR <kind>
<message>` (kinds and exit codes as sg-netctl: `denied` 3, `invalid` 2,
`notfound`, `unsupported`, `failed` 1).

- **Readable things are answered in-process**, as the caller: devices,
  disks, units, users, groups, shares, processes, connections, system,
  the user's own cleanup categories. Only what needs root goes to
  **sg-sysinfod** (`sg-sysinfod.socket`, `/run/stained-glass-sysinfo/sysinfod.sock`,
  0666, `Accept=yes`, `sg-sysinfo --serve` as root per connection), which
  decides from `SO_PEERCRED`: anyone with a Windows session (sgwine,
  sg-admins, SYSTEM, root) may read the journal and the system cleanup sizes;
  `sessions`, `openfiles`, `clean-system`, `mount`, `unmount`, `letter`,
  `format` need an administrator (sg-admins, SYSTEM, root). Other accounts get
  nothing. Root, or a member of `systemd-journal`/`adm`, reads the journal
  directly.
- **The journal shows only Stained Glass**: entries whose unit
  (`_SYSTEMD_UNIT`, or a session's `_SYSTEMD_USER_UNIT`) or
  `SYSLOG_IDENTIFIER` starts `sg-`, filtered in the service whatever the
  caller asked; `--unit` must itself be `sg-*`. Newest first.
- **Disk changes refuse** the system disk (one holding `/`, `/boot`,
  `/boot/efi`, `/efi`, `/usr`, `/var`, `/home`, swap, or the Wine prefix)
  for `format`; a volume that is mounted, has a letter, holds other volumes or
  is an ESP; unmounting a system or swap volume; letters other than D:-Y:,
  a letter in use, a letter for an unmounted volume. **C: and Z: are never
  touched.** Mounts go to `/media/stained-glass/<label>` (FAT/exFAT/NTFS
  group-writable by sgwine, since Windows programs open files as their own
  uid). A letter is a symlink in the prefix's `dosdevices`, owned like the
  directory. The service has no mount namespace (no PrivateTmp) so mounts are
  the machine's.

**Interface** (stable; blocks end with `END`, `*` = repeated):

```
whoami        USER <name>  ADMIN yes|no
system        OS-NAME OS-VERSION OS-BUILD KERNEL HOSTNAME DOMAIN MANUFACTURER MODEL SYSTEM-TYPE
              BIOS-VENDOR BIOS-VERSION BIOS-DATE BOARD-VENDOR BOARD-NAME BOARD-VERSION BOOT-MODE UEFI|Legacy
              SECURE-BOOT on|off|unsupported CPU CPU-CORES CPU-THREADS CPU-MHZ MEMORY-TOTAL MEMORY-AVAILABLE
              SWAP-TOTAL (bytes) TIMEZONE LOCALE UPTIME (s) VIRTUALIZATION GPU* BOOT-DEVICE   (no blocks)
devices       DEVICE <pci:SLOT|usb:N|net:IF|block:N|sound:cardN|input:inputN|monitor:CONN|cpu:N|power:N>
              CLASS display|net|disk|cdrom|sound|usb|hid|keyboard|mouse|camera|bluetooth|processor|system|
                    storage-controller|printer|battery|monitor|other
              NAME [VENDOR] [VENDOR-ID 0x..] [PRODUCT-ID 0x..] [SUBSYSTEM-NAME] BUS SUBSYSTEM SYSFS [DEVNODE]
              [LOCATION] [DRIVER] [MODULE] [MODULE-VERSION|-SRCVERSION|-FILE|-LICENSE|-AUTHOR|-DESCRIPTION]
              IFACE* [MAC] [SIZE] [SPEED] [SOUND-CARD] [CAPACITY] [VIRTUAL yes|no] STATUS ok|nodriver
              [PROBLEM <text>] [SG-DRIVER <packages sg-drivers would install>] [SG-DRIVER-NOTE] [PARENT <id>]  END
disks         DISK <name> PATH TYPE disk|cdrom SIZE [MODEL VENDOR SERIAL TRANSPORT] ROTATIONAL REMOVABLE
                          READONLY PTTYPE gpt|dos|none SYSTEM yes|no  END
              PART <name> PATH DISK NUMBER START SIZE (bytes) [FSTYPE] [INNER-FSTYPE] [LABEL UUID PARTTYPE
                          PARTTYPENAME PARTLABEL] MOUNT* [FSSIZE FSUSED FSAVAIL] [FLAGS esp boot swap system]
                          LETTER <X:>*  END           (after their DISK, in disk order)
              FREE <disk> START SIZE  END            (unallocated, >= 2 MiB)
              MAP <X:>\t<target>                     (a letter on no local volume: network, tmpfs, missing)
units         UNIT <id> DESCRIPTION LOAD ACTIVE SUB UNIT-FILE-STATE MAIN-PID SINCE (epoch) [PATH]  END
              (sg-* plus greetd, NetworkManager, systemd-resolved, cups, samba-ad-dc/smbd/nmbd/winbind if present)
journal [--unit sg-U]* [--since EPOCH] [--until EPOCH] [--priority 0-7] [--lines N<=5000] [--after-cursor C]
              E\t<usec>\t<priority>\t<unit>\t<identifier>\t<pid>\t<cursor>\t<message>   (\\ \t \n \r escaped)
users         USER <name> UID FULL-NAME HOME SHELL GROUPS ADMIN WINDOWS DISABLED yes|no|unknown
                          SYSTEM-ACCOUNT [DESCRIPTION]  END   (uid 1000-59999 and SYSTEM)
groups        GROUP <name> GID MEMBERS [WINDOWS-NAME Administrators|Users] [DESCRIPTION]  END
shares        SHARE <name> PATH COMMENT READONLY GUEST PRINTABLE [USERSHARE yes]  END
              (ERROR unsupported "Samba is not installed" without it)
sessions      SESSION <id> USER MACHINE PROTOCOL ENCRYPTED  END           (admin)
openfiles     OPENFILE <path> USER SHARE MODE  END                        (admin)
processes     PROCESS <pid> PPID NAME [COMMAND] USER CPU-TICKS CLOCK-TICKS RSS THREADS STATE
                          [READ-BYTES WRITE-BYTES]  END
connections   CONN\t<tcp|tcp6|udp|udp6>\t<local>\t<remote>\t<state>\t<pid|->\t<uid>
cleanup       CATEGORY <id> NAME SCOPE user|system SIZE DESCRIPTION  END
              user: recycle-bin thumbnails wine-downloads; system (via the service):
              update-cache old-logs archived-journal crash-reports
clean ID...   CLEANED <id> <bytes>*        (system categories: admin)
mount PART                 MOUNTED <part> <dir>          (admin)
unmount PART               UNMOUNTED <part>              (admin)
letter PART X:|none        REMOVED <X:>* LETTER <X:>     (admin)
format PART ntfs|exfat|fat32|ext4 [--label L]  FORMATTED <part> <fs>   (admin)
create DISK START SIZE [--fs F] [--label L]    CREATED <part> <fs>      (admin; bytes, in a FREE region)
delete PART                DELETED <part>                (admin)
resize-info PART           SIZE MIN-SIZE MAX-SIZE        (admin; NTFS/ext4, unmounted)
resize PART SIZE           RESIZED <part> <bytes>        (admin; extend into the space after it, or shrink)
smart         SMART <disk> HEALTH ok|failing|unsupported|unknown [NOTE] [TEMPERATURE] [POWER-ON-HOURS]
                           [REALLOCATED PENDING UNCORRECTABLE] [WEAR MEDIA-ERRORS] [MODEL]  END   (any session user)
device-disable ID | device-enable ID    DISABLED|ENABLED <id>        (admin; pci:/usb: devices)
```

- **Names**: PCI names from udev's hwdb data (`/run/udev/data`), else
  `pci.ids`; the bracketed marketing name wins ("GA102 [GeForce RTX 3090]"
  is "NVIDIA GeForce RTX 3090"), with the maker in front as Device Manager
  shows it. USB: the device's own strings, then hwdb, then `usb.ids`.
  Monitors: the EDID's name descriptor. Keyboards and mice: udev's
  `ID_INPUT_*`, else the evdev capabilities (containers have no udev data).
- **"No driver"**: a display, network, sound, storage, USB, Bluetooth,
  camera or printer device with no bound kernel driver is `STATUS nodriver`.
  `SG-DRIVER` is what `sg-drivers --list` recommends for that PCI slot and
  is not yet installed (dpkg), so Device Manager can offer it -- also on a
  device that works on the open driver (nouveau, r8169).
- **Drive letters** come from `$WINEPREFIX` (else `SG_PREFIX`, default
  `/var/lib/stained-glass/prefix`) `dosdevices/x:` links, mapped to the
  volume whose mount point is the longest prefix of the target **and** that
  really holds it (same `st_dev`), so C: (drive_c) and Z: (`/`) sit on the
  root partition and a network drive under `/run` is a `MAP` line.
- **Test overrides**: `SG_SYSINFO_SOCKET`, `SG_SYSFS`, `SG_PROCFS`,
  `SG_UDEV_DATA`, `SG_PCI_IDS`, `SG_USB_IDS`, `SG_OS_RELEASE`,
  `SG_PASSWD_FILE`/`SG_GROUP_FILE`/`SG_SHADOW_FILE`, `SG_VAR`, `SG_MEDIA_DIR`,
  and a command per tool, `SG_<TOOL>` (`LSBLK`, `JOURNALCTL`, `SYSTEMCTL`,
  `TESTPARM`, `SMBD`, `SMBSTATUS`, `NET`, `MODINFO`, `DETECT_VIRT`,
  `DPKG_QUERY`, `MOUNT`, `UMOUNT`, `MKFS_NTFS|EXFAT|FAT32|EXT4`, `DRIVERS`);
  an empty value means "not installed". Setting `SG_JOURNALCTL` also reads
  the journal directly (no socket).
- **Gate: `test/sysinfo-test.py`** (in `make lint`): a fake sysfs (a VM's
  bochs display with its module, an NVIDIA card with no driver and
  sg-drivers' recommendation, virtio network with eth0, a disk, a monitor
  with an EDID, a keyboard without udev), fake lsblk/journalctl/systemctl/
  testparm/smbstatus/mount/mkfs, and the real socket protocol: journal only
  sg-*, escaped, newest first, a non-sg unit refused, non-session accounts
  denied; every disk change and system cleanup refused to a standard user;
  format refused on the system disk and a mounted volume; C:/Z: kept; the
  bridge. Seen red against mutants: no journal filter, no admin check, no
  system-disk check, no `st_dev` check. Checked for real on the dev box
  (i7/RTX 3090/Realtek: display, network, disks with sizes) and through a
  real root socket (`systemd-socket-activate --inetd`) with real accounts: a
  non-session account denied, an sgwine member reading the journal and
  refused `format`, SYSTEM refused unmounting `/`.
- **Partitions (Disk Management's New Simple Volume, Delete, Extend,
  Shrink)** follow sg-install's partitioner (sfdisk `--append` in a free
  region, `--delete`, `-N n` to resize; `partx`, `udevadm settle`): a blank
  disk becomes GPT; types Microsoft basic data (NTFS/exFAT/FAT32) or Linux
  file system (ext4), MBR 07/0c/83 and at most four primaries; the new
  volume formatted with its label. Refused: the system disk, a mounted or
  lettered volume, an ESP, anything outside a FREE region. Resizing is NTFS
  and ext4 only (as Windows: not FAT/exFAT), unmounted; shrinking resizes the
  file system first (resize2fs / ntfsresize `-s`), extending after the
  partition. **`SG_SYSINFO_DISKS`** (tests: loop devices) lists the only
  disks anything may change -- and makes those loop devices visible as disks;
  loop/ram devices are otherwise never changed. **Commands never get the
  service's stdin** (the request socket): `ntfsresize` asks "Are you sure"
  there and hung the service; `run_cmd` feeds `y` or nothing.
- **SMART** (`smart`, sg-sysinfod: root reads the disks) is `smartctl -H -A
  -i --json=c` per disk; `SG_SMARTCTL` stands in; without smartmontools the
  health is `unknown`.
- **Disable/Enable device**: a PCI device gets `driver_override` =
  `sg-disabled` (no such driver) and is unbound; enabling clears it and
  writes `drivers_probe`. A USB device's `authorized` goes 0/1. Both show
  `STATUS disabled`, "This device is disabled. (Code 22)". Refused: the
  controller above the system disk, bridges/processors/monitors/batteries,
  USB root hubs. Remembered in `/var/lib/stained-glass-sysinfo/disabled-devices`
  (`SG_SYSINFO_STATE`) and re-applied at boot by `sg-devices-apply.service`
  (`sg-sysinfo --apply-disabled`, root).
- **Gates**: `test/sysinfo-test.py` (fakes: refusals, SMART, disable/enable
  on a made-up sysfs; mutants without the system-disk check, the admin check
  on resize, the controller guard, the Code 22 status, failing SMART, the
  allow-list each turn it red) and **`make test-diskops`** (`test/diskops-test.sh`,
  sudo, a 512 MB **loop device** only): a standard user refused and the disk
  untouched, GPT initialised, ext4 and NTFS volumes created with labels and
  types, both shrunk and extended with e2fsck/ntfsresize confirming the file
  systems, over-extending and mounted volumes refused, both deleted. A mutant
  that shrinks the partition without the file system fails e2fsck.

## The Security log: sg-audit and the audit spool

Signing in and out and elevation happen in PAM and in sg-brokerd, not in
Windows, so they reach Event Viewer's Security log through the **audit
spool** `/var/lib/stained-glass-audit` (tmpfiles `sg-audit.conf`: 0700
sgsystem -- only root and SYSTEM can write it, so no user can forge an
audit event), which wine-sg's Event Log service imports (0187; file format
there and in `bin/sg-audit`'s header).

- **`sg-audit pam`** (pam-configs `stained-glass-audit`, pam_exec at session
  open/close, root): 4624 with Windows' logon type from the PAM service
  (greetd 2 Interactive, `stained-glass-lock` 7 Unlock, `stained-glass-remote`
  10 RemoteInteractive, sshd 3), 4672 for an administrator (sg-admins),
  4634 at close. Files are written under a dot-name, renamed, and chowned to
  the spool's owner (root's 0600 files were unreadable to the service). It
  never fails a login.
- **sg-brokerd** (running as SYSTEM, writes itself): consent = 4672 for the
  administrator with the program; a standard user elevating with an
  administrator's credentials = 4648 + 4672; wrong credentials = 4625 (audit
  failure). The password never reaches the spool.
- **The log files at the Linux level**: sg-services-start makes
  `winevt/Logs` 0700 and its files 0600 before the SCM starts (Wine maps a
  DACL naming SYSTEM to user *and group* bits, so wevtsvc cannot).
- **Not seen**: failed sign-ins at the login screen (a pam_exec in the auth
  stack runs only on success paths).
- **Gate: `make test-audit`** (`test/audit-test.sh`, sudo, `sgconf`):
  sg-audit's events for each PAM service, admin vs standard, modes and owner,
  auth ignored, an unwritable spool not failing; the broker built and run in
  test mode for consent, credentials and a wrong password (no password in the
  spool); the log directory's modes; and with `SG_WINE=<a wine-sg with 0187>`
  the sign-in read back from Wine's Security log, worded. Mutants: no chown,
  4672 for everyone, no 4625 from the broker, no chmod -- each red.

## Settings' native half: sg-settingsctl

`bin/sg-settingsctl` (Python, `/usr/bin/sg-settingsctl`) is what sg-shell's
Settings (`sg-settings`, `ms-settings:`) cannot reach from the Windows side.
It runs **as the signed-in user** and does only the user's own business;
root's (time zone, clock, computer name, fetching updates) stays with
sg-shell's sg-admind.

```
sg-settingsctl sound                          SINK|SOURCE <name>\t<default>\t<vol%>\t<muted>\t<description>
sg-settingsctl sound default sink|source NAME
sg-settingsctl sound volume sink|source NAME PERCENT      (0-150)
sg-settingsctl sound mute sink|source NAME yes|no
sg-settingsctl bluetooth                      BLUETOOTH yes|no, POWERED yes|no, DEVICE <mac>\t<connected>\t<paired>\t<name>
sg-settingsctl bluetooth power on|off | scan [SECONDS] | pair|connect|disconnect|remove MAC
sg-settingsctl display                        OUTPUT <name>\t<WxH@Hz>\t<scale>\t<desc>, MODE <name>\t<WxH@Hz>\t<current>\t<preferred>
sg-settingsctl display mode OUTPUT WxH[@Hz] | scale OUTPUT S
sg-settingsctl nightlight [on|off] [--temp K] NIGHTLIGHT on|off\t<K>\t<available>\t<running>
sg-settingsctl power [--screen MIN] [--sleep MIN]   POWER <screen>\t<sleep>\t<available>\t<running>
sg-settingsctl sleep-caps                     CAN suspend|hibernate <logind: yes|no|challenge|na>
sg-settingsctl sleep [suspend|hibernate]      lock, then systemctl suspend|hibernate (Start's Sleep)
sg-settingsctl shutdown poweroff|reboot       when the session's programs have closed, systemctl poweroff|reboot (ExitWindowsEx)
sg-settingsctl updates                        UPDATE <pkg>\t<installed>\t<new>, STAGED yes|no
sg-settingsctl session-start                  night light and idle timers again (sg-run-explorer)
```

Every answer ends with `OK` or `ERROR <kind> <message>` (invalid 2,
unsupported 4, notfound 5, failed 1). `--out FILE` writes the answer to a file
(renamed into place whole): Wine gives a Windows program no pipes to a native
child, so Settings reads files, as it does sg-dictate's.

- **The tools**: pactl (PipeWire's Pulse server), bluetoothctl, wlr-randr
  (sg-compositor's output management), wlsunset (its gamma control),
  swayidle + wlopm (its idle notifications), `apt list --upgradable`.
  sg-image installs them (`mkosi.conf`, "settings"); each command answers
  `unsupported` without its tool, and display/night light/power without
  `WAYLAND_DISPLAY`. `SG_SETTINGSCTL_TOOLS` puts stand-ins first (the gate).
- **Choices persist** in `~/.config/stained-glass/settings.json`; the
  helpers it starts (wlsunset, swayidle) are detached, their pids in
  `$XDG_RUNTIME_DIR/sg-{nightlight,idle}.pid`, replaced on each change, and
  `sg-run-explorer` runs `session-start` with every session.
- **Inputs are validated** before a tool hears of them: device and output
  names (no leading `-`, so no option smuggling), MAC addresses, numbers in
  range, modes and scales by pattern; an output must exist.
- **Power & sleep**: `swayidle -w` runs for the whole session: the screen
  timeout (`wlopm --off '*'`, resume `--on`; sg-compositor 0.2.0+sg5 has
  wlr-output-power-management and wakes the screen on any input itself),
  the sleep timeout (`systemctl suspend`), and -- whatever the timeouts,
  even never/never -- `before-sleep sg-lockctl LOCK` and `after-resume
  wlopm --on`, so every sleep (lid, Start, timer) wakes to the lock screen,
  as Windows asks for the password on waking. `-w` makes logind wait for
  the lock. sg-lockctl is found in `/usr/libexec/stained-glass` and needs
  the session's `SG_LOCK_CONTROL`.
- **Sleep and Hibernate** (sg-shell's Start): `sleep-caps` asks logind's
  `CanSuspend`/`CanHibernate` (busctl); Start shows an item only for "yes"
  -- "challenge" would need a polkit agent, which our session has none of,
  and logind refuses an inactive or remote session. `sleep` locks first,
  then `systemctl suspend|hibernate`; polkit's refusal comes back as
  `ERROR failed`.
- **Shut down and Restart** (Start's, and any program's `ExitWindowsEx`):
  wine-sg 0241 starts `wineboot --end-session` and then `sg-settingsctl
  shutdown poweroff|reboot`, which waits while this user's
  `wineboot.exe --end-session` runs (the session's programs closing; at most
  `SG_SHUTDOWN_WAIT`, 30 s -- argv[0]'s base name must be wineboot.exe, not
  merely mentioned) and then asks logind. `config/polkit/50-stained-glass-
  power.rules` lets a local active user power off and reboot even though the
  login screen's session always exists (logind's `-multiple-sessions`
  actions would otherwise want an administrator's password, with no agent to
  ask). Before 0241 Shut down did nothing at all (2026-09-26 ISO QA, B44).
- **No Bluetooth adapter** (no `hci*` in `/sys/class/bluetooth`;
  `SG_SETTINGSCTL_BTSYS` for the gate) is answered at once: bluetoothctl
  otherwise waits 15 s for a bluetoothd that cannot start, and Settings'
  Devices page froze that long.
- **Gate: `test/settingsctl-test.py`** (in `make lint`): stand-in tools record
  what they are asked -- the parsed answers Settings reads, the exact
  commands, and every refusal. Seen red: device names that start with `-`
  were accepted before the pattern was tightened.

## The PDF Viewer's Linux half: sg-pdf

`bin/sg-pdf` (Python, `/usr/bin/sg-pdf`) is what sg-shell's PDF Viewer
(`sg-pdf64.exe`, the `.pdf` association) draws from: **Debian's poppler**
through its GObject-introspection bindings (`gir1.2-poppler-0.18`,
`python3-gi`, `python3-gi-cairo`, `python3-cairo` -- Recommends, and named in
sg-image's package list). It runs as the user, reads only the file the viewer
names, and touches no network. The viewer re-launches itself as `sg-pdf
--bridge wine <itself> --bridged <args>` and talks on its standard handles,
as sg-dictate's toolbar does.

```
open PATH [PASSWORD]     OK pages=N bytes=K   "size W H" a page (points), "title T", "author A"
render PAGE SCALE ROT    OK w=W h=H bytes=W*H*4   top-down B,G,R,A rows, opaque (white paper)
text PAGE                OK n=N bytes=18N     N UTF-16LE units, then N boxes (4 x float32 LE:
                                              x1 y1 x2 y2); a character beyond the BMP has its box twice
find NEEDLE [FLAGS]      OK n=N bytes=K       "PAGE X1 Y1 X2 Y2" lines, in reading order;
                                              FLAGS c = match case, w = whole words
links PAGE               OK n=N bytes=K       "X1 Y1 X2 Y2<TAB>goto<TAB>PAGE<TAB>TOP" or "...<TAB>uri<TAB>URI"
outline                  OK n=N bytes=K       "DEPTH<TAB>PAGE<TAB>TOP<TAB>OPEN<TAB>TITLE" lines, in order
quit
```

One request a line, fields separated by tabs; pages are 0-based; every
coordinate is in points with the origin at the page's top left, unturned
(poppler's search hits and link areas are bottom-left based and turned
here). Errors are one line, `ERR <kind> <message>`: `invalid`, `open`,
`password` (the document needs one: the viewer asks and sends `open PATH
PASSWORD`), `notopen`, `range`, `toolarge` (a bitmap over 60 Mpixel),
`failed` (poppler is not installed says so here). `--serve` answers on its
own stdin/stdout; `--info FILE` prints the open answer. `--thumbnail FILE
SIZE OUT` is File Explorer's PDF thumbnail (wine-sg 0244's shell32 runs it
as `\\?\unix/usr/bin/sg-pdf`): page 1 with its longer side SIZE (16-1024)
as a PNG written to OUT.tmp then renamed, or the reason in OUT.err --
**shell32 polls for one of the two files** (a Windows program gets no pipe
to a native one), so both must appear whole and exactly one of them.

- **Gate: `test/pdf-test.py`** (in `make lint`; skips 77 without the GI
  bindings): a PDF written by hand (Helvetica text, a filled box, a link
  annotation, a two-entry outline); sizes, a bitmap's size and the box's
  colour where the page puts it (and where a clockwise quarter turn puts
  it), the H's box at the top left, find in any case and with match case in
  reading order and top-left coordinates, the link and the outline, eight
  refusals, and the bridge serving a stand-in program. Seen red against
  mutants that leave search hits bottom-left based and that ignore the
  rotation; `--thumbnail`'s size, no leftovers, and its refusals in
  OUT.err (a mutant ignoring SIZE fails). sg-shell's `test/pdf-check.sh` is
  the Windows side; wine-sg's `test/explorer3-gate.sh` the thumbnail's.

## Voice typing: sg-dictate (Win+H)

`speech/sg-dictate` (Python, `/usr/bin/sg-dictate`) and `speech/sgspeech.py`
(`/usr/lib/stained-glass/speech/`) are voice typing's engine: **NVIDIA
Parakeet TDT 0.6B v3** (int8 ONNX, CC BY 4.0 -- the Control Panel page
carries the attribution) on the CPU through Debian's `python3-onnxruntime`,
with **Silero VAD v5** (MIT) finding where speech starts and stops. The
Windows side is sg-shell's `sg-dictate.exe` (the toolbar) and Control Panel >
Speech Recognition. Explorer's Win+H runs `sg-dictate.exe /toggle` (wine-sg
0092), found through App Paths.

- **Our own decoder, not onnx-asr.** Debian does not package onnx-asr, so
  `sgspeech.py` does NeMo's 128-band log-mel (checked against onnx-asr's
  filterbank to 3e-8) and TDT greedy decoding itself; it transcribes exactly
  as onnx-asr does. Debian's onnxruntime prints ~570 lines of "Schema error"
  when it makes its first session: harmless, and `_Quiet` keeps them off
  stderr.
- **The packaged model comes first.** sg-image's `speech-model/build-deb.sh`
  makes `sg-speech-model-parakeet` (the files, `NOTICE` and the `.verified`
  stamp under `/usr/share/stained-glass-speech/parakeet-tdt-0.6b-v3-int8/`).
  When that stamp exists, `model_path()` is there and `model_installed()` is
  true; `--status` adds `SOURCE packaged|downloaded <dir>`; `--download` (and
  sg-speechd's) has nothing to do; `--remove` refuses (exit 4; sg-speechd
  `ERROR unsupported`), naming the package -- dpkg owns it. **`fetch_model`
  skips only when asked** (`skip_if_packaged=True`, as `--download` and
  sg-speechd ask): build-deb.sh calls it plain to fill its cache, which must
  really fetch whatever the build machine has installed.
  `SG_SPEECH_PACKAGED_DIR` moves it for the gate.
- **Otherwise the model is downloaded.** `sg-speechd.socket`
  (`/run/stained-glass-speech/speechd.sock`, 0666, `Accept=yes`) runs
  `sg-dictate --serve` as root per request: members of `sgwine` (anyone with
  a Windows session) may `download`, an `sg-admins` member may `remove`.
  Files come from pinned revisions (Hugging Face `istupakov/parakeet-tdt-0.6b-v3-onnx`
  at `8f23f0c`, silero-vad `v5.1.2`), each checked against its size and
  SHA-256 in `sgspeech.FILES`, resumed with HTTP ranges, into
  `/var/lib/stained-glass-speech/parakeet-tdt-0.6b-v3-int8/` (`.verified`
  when complete; 642 MB). Progress goes to `status` there (`STATE`, `DONE`,
  `TOTAL`, `MESSAGE`), which the Control Panel reads. **Not under
  `/var/lib/stained-glass`**: that belongs to the SYSTEM account, which could
  swap the directory for a link under root's feet.
- **The bridge.** Wine gives the toolbar no AF_UNIX and no pipes to a native
  program, so it re-launches itself as `sg-dictate --bridge wine <itself>
  --bridged /toggle` (as sg-netctl's bridge). Down: JSON lines, `{"cmd":
  "start", "continuous", "spoken", "auto", "fillers", "numbers", "fresh",
  "mic", "tail", "language", "partials"}`, `stop` (what was said is still
  typed), `cancel`, `preload`, `unload`, `quit`. Up: `STATE
  loading|listening|idle|nomodel|nomic ...|error ...`, `LEVEL 0-100` (10 a
  second), `PARTIAL <JSON string>` (the utterance so far: shown, never typed;
  `""` clears it), `TEXT <JSON string>` (the final, which replaces the
  partial), `CMD delete|undo` (spoken commands the toolbar carries out).
- **Partial results while speaking.** While the VAD is in speech, the
  utterance so far is recognised again every 0.5 s of new speech (the first
  after 0.4 s) -- or every twice what the last partial took, so a slow or busy
  machine gets fewer, never a backlog. Partials share the recogniser thread
  with finals and are one slot deep (only the newest is kept); a partial of
  an utterance that has meanwhile finished (a serial number per utterance)
  is dropped, so none arrives after its final. Cost measured: 0.1 s for 0.4 s
  of speech, ~0.9 s for 11 s. `--listen --partials` prints them on stderr.
- **Audio** is `parec` (PipeWire's Pulse server) at 16 kHz mono, else
  `pw-record --raw`. Audio heard while the model loads is kept (up to a
  minute), so the first words after Win+H are not lost. Utterances end after
  700 ms below the VAD's lower threshold, and are cut at 20 s. Not
  continuous: listening stops after the first utterance, or 8 s of silence;
  continuous: after 120 s of silence.
- **Text rules** (`postprocess`): the model punctuates and capitalises by
  itself; spoken marks ("comma", "period", "question mark", "new line", "new
  paragraph", quotes, brackets...) replace whatever the model put around them;
  fillers (um, uh, er, hmm...) go; spoken numbers of two words or more, or ten
  and over, become digits (English only).
- **Languages**: English, German, French, Spanish tables
  (`SPOKEN_PUNCTUATION_BY_LANG`, `FILLERS_BY_LANG`, `COMMANDS_BY_LANG`),
  chosen by Control Panel's Language (`en-US`, `de-DE`, `fr-FR`, `es-ES`;
  `--language` on the command line); `auto` guesses each utterance's language
  from frequent words, the tables' phrases and letters (`detect_language`,
  English when in doubt). Phrases match with or without accents, hyphens or
  spaces ("linea", "point virgule"). German quotes are „...“ (so “ closes),
  French puts a space before ? ! : ; and inside « », Spanish gets its ¿/¡
  opener added to a sentence that lacks it. "Punkt"/"point"/"punto" are
  marks only as whole words (the model sometimes glues German words:
  "Testpunkt" stays).
- **Spoken commands** (`command()`): an utterance that is *only* "delete
  that"/"scratch that", "undo that", "stop listening" (and "das löschen",
  "rückgängig machen", "Diktat beenden"; "efface ça", "annuler", "arrête
  d'écouter"; "borra eso", "deshacer", "deja de escuchar"...) is a command,
  never text, under the spoken-punctuation setting. `delete` and `undo` go to
  the toolbar (`CMD`); `stop` stops listening (`STATE idle stopped`).
- **espeak-ng for the gates**: its German "Komma" is heard as "Toma" (say
  "Kommar"); its French "point" is rarely heard ("virgule" is). `join` puts a space between utterances, none after
  a line break or before punctuation; the toolbar sends the character before
  the caret (`tail`) when the focus is an Edit or RichEdit.
- **Privacy:** nothing heard is written anywhere or logged (the log says
  "recognised 3.3s of audio in 0.25s", never what); the only network access
  is sg-speechd's download.
- **Other modes:** `--transcribe-file WAV...` (the gate's), `--listen
  [--once] [--seconds N]`, `--mics [--out FILE]`, `--meter FILE` (Test
  microphone: `LEVEL n` in FILE until `FILE.stop`), `--status`,
  `--download`, `--remove`. `SG_SPEECH_DIR`, `SG_SPEECH_MODEL` (a model
  directory, skipping the machine's), `SG_DICTATE_AUDIO_FILE` (a WAV instead
  of the microphone, at real time) and `SG_SPEECH_MIRROR` (a local directory
  to download from; ignored as root) exist for the gates.
- **Gates:** `test/dictate-test.py` (in `make lint`: text rules, the mel
  bank, who sg-speechd lets do what -- a mutant that lets everyone download
  fails it) and `make test-dictate` (`test/dictate-e2e.sh`: espeak-ng speech
  through the real model -- words, spoken marks, no fillers, digits, two
  utterances split by a pause, `--once`; skips 77 without the model, which it
  downloads to `~/.cache` when it can) -- plus German/French/Spanish marks
  (and `auto` on German), partial results that grow on a long sentence
  (`--listen --partials`), and "delete that" as a command. dictate-test.py
  also runs the real `Dictation` with a stand-in recogniser and VAD: partials
  before the final and never after it, exactly one final, none when not
  asked, German marks and "Das löschen"/"Diktat beenden" as commands. Seen
  red: German table removed (6), partials sent as TEXT (3), no partials (2),
  no commands (1), language ignored (21). sg-shell's `test/dictate-check.sh`
  is the Windows side, and runs this engine too when a model is at hand.
- **Measured** (i7-8086K, 8 threads): model load 2 s and ~0.7 GB resident
  (1.3 GB with onnxruntime's weight pre-packing, now off); recognition at
  ~0.08 x real time (3.3 s of speech in 0.3 s); the VAD while listening
  0.5% of one core. The engine lives while the bar is open; the hold-to-talk
  listener unloads the model after 5 minutes unused.

## Domain controller role (D2)

One image, two roles. `domain/sg-dc-provision` (installed as
`sg-dc-provision`) turns a machine into an Active Directory domain controller:
Samba AD DC with its internal DNS, `samba-tool domain provision
--use-rfc2307`, the realm's `krb5.conf`, the resolver pointed at itself
(`/etc/systemd/resolved.conf.d/50-sg-dc.conf`, stub listener off so Samba has
port 53), `samba-ad-dc` enabled. The image ships every Samba service disabled
(a preset in sg-image) until a role asks. The gates use the test domain
SGTEST.LAN only.

- **Wipe a workstation's Samba databases before provisioning** (Samba's own
  guide says so). Left in place, the caches of the winbind that ran before
  confused the DC's winbindd.
- **A negative idmap answer is cached for a week.** A lookup of a well-known
  SID (Everyone, S-1-1-0) made while the DC was still starting cached "no
  mapping", and every SMB session setup then failed with
  `NT_STATUS_INVALID_SID`. The provisioner waits until `wbinfo --sid-to-gid
  S-1-1-0` answers, flushing the cache (`net cache flush`) until it does.
- **The Administrator password is on samba-tool's command line** for the
  seconds provisioning takes; samba-tool has no other way to take it.

## Domain member (D1)

`domain/sg-domain-join` (installed as `sg-domain-join`) joins an Active
Directory domain, as "Join a domain" does on Windows: DNS pointed at the DC
(`--dc`), `krb5.conf`, a member `smb.conf` (`security = ADS`, rid idmap for
the domain), `net ads join` with the password in `$PASSWD` (never argv),
winbind on. Then sign-in: `pam_winbind` with `krb5_auth` (a ticket at sign-in,
`FILE:/tmp/krb5cc_<uid>`, which Wine's Kerberos/Negotiate use -- single
sign-on for Windows programs), `pam_mkhomedir`, and `sg-domain-groups`
(pam_exec at session open, as root; pam-configs `stained-glass-domain-groups`,
off until the join) putting a signing-in domain user in the Windows system's
group, and Domain Admins in `sg-admins` and `sudo` -- Windows' "Domain Users
are local Users, Domain Admins local Administrators".

- **Not pam_group.** greetd sets the session's groups with `initgroups()`
  after PAM's setcred, which drops pam_group's additions: the session could not
  reach the prefix and ended at once, silently. The group file is what
  initgroups() reads, so sg-domain-groups writes the membership there before
  the session starts. It records what it granted
  (`/var/lib/stained-glass/domain-groups`) and takes away only that, so a
  demotion in the directory applies at the next sign-in.
- **`winbind use default domain = yes`**: domain users are `alice`, not
  `SGTEST\alice`. A backslash in a Unix user name would become a path
  separator in Wine (`C:\users\SGTEST\alice`).
- **The shell's command line reads as bare `explorer.exe /desktop`** on the
  image (see the note under "Things that will bite you"): gates match
  `explorer.exe`, never `/desktop=shell`.
- **Gate:** sg-image's `make domain-test`: two copies of the image on a private
  segment, one provisioned as the DC, the other joined, a domain user signed in
  at the console by typing, SSPI Kerberos from a Windows program
  (`test/sg-sspi-probe.c`), a Domain Admin who is an administrator and a Domain
  User who is not.

## Network drives, home drives and logon scripts

`domain/sg-netmountd.c` (root, one instance per connection through
`sg-netmountd.socket`, `/run/stained-glass-net/netmount.sock`, 0666) mounts
`\\server\share` for whoever asks. The mount is kernel CIFS with
`multiuser,sec=krb5,cruid=<peer uid>` at
`/run/stained-glass-net/unc/<server>/<share>`, and drive letters are symlinks
in `/run/stained-glass-net/drives/<uid>/<x>:`. **The mount grants nothing:**
every user reaching it is a separate SMB session on their own Kerberos
ticket (cifs.upcall finds `/tmp/krb5cc_<uid>`), so the file server decides.
A user with no ticket gets no mount at all. Names are validated: a server is
DNS, NetBIOS or IPv4; a share or directory name is what Windows allows, and
never `.` or `..`. C: and Z: cannot be mapped. `\\DOMAIN\share` (NETLOGON,
SYSVOL) goes to a domain controller found with DNS SRV. A short name gets the
domain's DNS suffix so Kerberos finds `cifs/<fqdn>`. wine-sg 0056/0057 are
the clients; the tab-separated wire format is in wine-sg's CLAUDE.md.

`domain/sg-domain-logon` (pam_exec as root, with sg-domain-groups) reads a
domain user's homeDirectory, homeDrive and scriptPath with `net ads search -P`
(the machine account) at session open. It maps the home drive and records
`\\DOMAIN\NETLOGON\<script>` in the user's drive directory, and
`lib/sg-run-explorer` runs that script hidden as the desktop starts (Windows
does not wait for it either). It also records the logon variables
(USERDOMAIN, LOGONSERVER, HOMEDRIVE/HOMESHARE/HOMEPATH) as `volatile.reg`,
which the session imports into `HKCU\Volatile Environment` first. Drive
letters go when the user's last session ends: `user-runtime-dir@.service`'s
ExecStop (a drop-in), because a session logind ends leaves no PAM close.
The user service manager's own PAM session (`systemd-user`) is skipped.

`domain/sg-gpo-user` (Python, root, from sg-domain-logon) is the Group Policy
client for a user. Samba's `get_gpo_list` (machine account) decides which
GPOs apply: the OU chain, link order, enforced links, and security filtering
on the user's token. The files come from SYSVOL **with the user's ticket**:
SYSVOL is mounted for them and read by a child that has dropped to their uid.
Samba's own SMB client (`check_refresh_gpo_list`) failed with
`STATUS_INVALID_PARAMETER_MIX` on a member. Handled: GPP `Drives.xml` (C/U/R/D;
item-level targeting by security group only, and items with other filters
are skipped), `scripts.ini` [Logon] (appended to the logon scripts) and user
`Registry.pol` (to HKCU through sg-polimport).

**Group Policy de-tattoos** (sg_apply_policy). A value a policy set last
time and no policy sets now is deleted on the next apply -- a policy removed
from a GPO, or a local `.reg` dropped from `policy.d`, stops applying. The set
of values policy set is recorded in `$SG_STATE/policy-applied.list`; the
difference from the previous set is deleted. **Only the exact `(key, value)`
pairs policy set are touched** -- never a branch key and never a descriptor,
so a program's own state under a policy branch survives, and the boot-time
protection (which is not re-stamped mid-refresh) is not disturbed. First run
has no state, so nothing is deleted. The same applies to **user policy**
(`sg_apply_user_policy`, HKCU) at login, with per-user state in the user's
home. The delete loop is `set -e` safe (it runs under `set -eu`). Gate:
`test/detattoo-test.sh` (machine and user).

**Machine Group Policy**: `domain/sg-gpo-machine` (root) asks Samba which
GPOs apply to the computer account. It fetches each one's
`Machine\Registry.pol` from SYSVOL with the machine account (`smbclient -P`)
into the machine policy directory as `60-domain-NN-{GUID}.pol`, in
application order, and removes the file of a GPO that no longer applies.
`sg_apply_policy` imports the files as SYSTEM, at boot (sg-services-start)
and from `sg-gpupdate` (gpupdate, root), which `sg-gpupdate.timer` runs every
90 minutes. Not yet: removing the *values* a GPO that stopped applying had
set (Windows rewrites the policy keys on each refresh), and machine startup
scripts.

**The Start menu and the logon scripts wait for the shell's desktop window.**
A Wine GUI program started before the shell makes Wine create the desktop
itself (a bare `explorer /desktop`). The shell's explorer then found it taken
and exited 0, and the supervisor logged "shell exited cleanly: ending the
session" while the desktop stayed up with nothing watching it. That was the
cause of the "shell shows as bare /desktop" oddity.

## Remote Desktop (RDP in)

`sg-rdp-authd` is pattern B of ADR 0010: the technician types the username and
password into the RDP client before connecting and lands in an unlocked desktop,
as with `mstsc`. `sg-rdpd.service` runs it; it is installed **disabled**, as
Remote Desktop is on Windows (`systemctl enable --now sg-rdpd`). The TLS
certificate is made on first start (`sg-rdp-cert`, `/etc/stained-glass/rdp/`,
key 0600 root) and never overwritten, so an administrator may install their own.

**After PAM says yes, the root monitor finds that user's session** and hands the
RDP side a connection to its compositor's privileged socket (SCM_RIGHTS): the
worker gains exactly that user's session, and only after that user's password
was accepted. A user with no session gets one: `systemd-run` with
`PAMName=stained-glass-remote` (logind session, profile service) runs
`sg-session-start` with `SG_REMOTE=1` -- sg-compositor on the headless backend
at the client's size (`SG_OUTPUT_SIZE`) -- in a seat of its own,
`/run/stained-glass-seat/rdp-<uid>`, with its own `sg-lockd` bound to it, so
Win+L works remotely and sg-brokerd finds it for consent prompts. Disconnecting
leaves the session running; the next login reconnects to it, as on Windows.

A user **signed in at the console** has that session taken over, as on
Windows (E1b). The monitor sends `REMOTE` to the console compositor's control
socket, with one end of a socketpair as the remote connection. The compositor
moves the user's windows to an output of its own; the console goes dark and
deaf except for Ctrl+Alt+Del. When the connection closes, the session goes
back to the console, locked. The stream always captures the newest output,
and its virtual pointer is created on that output. See sg-compositor's
CLAUDE.md. In the gate, the console phase first stops the prefix's
wineserver: a Wine desktop that belonged to a vanished X server makes the next
Wine process on another one die of BadWindow.

`rdp/sg-rdp-stream.c` is the stream: screencopy frames (pointer drawn in,
`copy_with_damage` paces it), 64x64 tiles compared with the last frame sent,
changed ones as **uncompressed 32bpp bitmap updates** (bottom-up BGRA, every
client since RDP 4 decodes them; bulk compression still applies). Input: RDP
scancodes -> winpr virtual keys -> evdev, on a virtual keyboard carrying the
ordinary evdev/us keymap; absolute pointer, buttons, wheel. Everything runs on
the peer's thread, which polls the Wayland fd beside FreeRDP's handles.

- **Not planar.** FreeRDP 3.15's planar encoder does not round-trip: with RLE
  any detail comes back streaked (its own round-trip test is disabled upstream
  as unfinished), and raw planes arrive at the client with red and blue
  swapped. Found by the gate's lossless check. An encoder of our own for the
  open RDP 6.0 bitmap compression spec is the way to get bandwidth back.
- **`make test-rdp-stream`** is the gate: a real FreeRDP client on Xvfb into a
  headless session running a Windows program. A wrong password starts nothing;
  the session is the client's size; the client's screen equals the session's
  captured frame **pixel for pixel** (`SG_RDP_FRAME_DUMP`); typing and clicks
  reach the program; disconnect keeps the session, reconnect finds the same
  one; the session ending disconnects the client. `SG_RDP_SESSION_CMD` and
  `SG_RDP_SEAT_ROOT` exist for this gate only.
- **Privilege separation, as in sshd.** At startup, as root, it forks a
  *monitor* that keeps root and does two things: check a credential with
  `sg-rdp-pamcheck`, and for an accepted one, find or start that user's
  session. The RDP side then drops to `sgrdp` (all four UIDs, no supplementary
  groups -- verified) before the listener opens. The TLS key is read into
  memory before the drop and `mlock`ed. A failed guess costs 2s, enforced in
  the monitor, where reconnecting cannot skip it. One worker process serves
  every connection; one per connection would contain a compromised parser to
  the sessions it was given.

**TLS plus PAM, not NLA, for local accounts.** Server-side NLA has to verify the
client's NTLM exchange, which needs every user's NT hash -- the MD4 hashes
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
- **pwsh needs a console.** Without one its ConsoleHost throws a
  NullReferenceException; the gate runs it under `script(1)`. From a
  console-less Windows parent, `CREATE_NO_WINDOW` (the RMM/service way) works,
  but default flags do not: Windows would give the child a new console and Wine
  does not. Measured and tabled in sg-image's `docs/packages.md`.

## Staged updates: download now, install on the next reboot

`sg-update-prepare` (run daily by `sg-update-prepare.timer`, randomised across
an hour so a fleet does not arrive at once) asks PackageKit to refresh and
download updates without installing them, then `pkcon offline-trigger` marks
the next boot. That boot enters `system-update.target`, where PackageKit's own
`packagekit-offline-update.service` installs everything and reboots into the
updated system -- before anyone logs in, so nothing is replaced under a running
program. It is the Windows and PureOS pattern and PackageKit's standard
mechanism, not a new one. Updates come from whatever apt sources are
configured.

- **The package starts the timer, never the service.** A postinst that started
  the service would run a network update check inside dpkg on a live system.
  `debian/rules` handles the two units separately for that reason.
- **The gate is sg-image's `make update-test`**: a canary package upgraded from
  a local test repository, asserted *not* installed before the reboot and
  installed after it, with the machine still reaching its login screen.

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

## Open: domain identity branch (`domain-identity`, not merged)

Branch `domain-identity` (fbe6146, changelog 0.1.0-32 -- renumber to the next
free version when merging): sg-domain-logon writes
`/run/stained-glass/domain-sids/<uid>` and ProfileList\<SID> (wine-sg 0205
gives domain users their real SID), computer GPO startup scripts
(sg-gpo-machine, sg-gpupdate, sg-gpupdate.service at boot). **Requires
wine-sg 10.0-61 (0211, pushed)**: without it, after a domain user signs out
the greeter spins in win32u's reg_empty_key (display keys owned by the
domain's Domain Users) and no one can sign in -- the branch's
`Breaks: wine-sg (<< 10.0-61)` says so. Status: sg-image `make domain-test`
passed 37 checks on wine 10.0-56 but failed at dave's sign-in (that bug);
the re-run with 10.0-61 was not done. Next: rebase the branch, build debs
from worktrees, run the gate with sg-image's uncommitted-then-branched
`test/domain-test.sh` (branch `domain-identity` in sg-image), merge on pass.
