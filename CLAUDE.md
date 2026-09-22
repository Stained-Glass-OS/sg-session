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
- **Scripts are POSIX `sh`, not bash.** They run early, before anything is
  guaranteed present. `make lint` enforces it.
- **`SG_*` variables must be exported** — the session crosses a process boundary
  from `sg-session-start` into `sg-run-explorer` under cage.

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
