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
| `bin/sg-session-check` | **the gate**: is a Windows shell really running? |
| `lib/sg-common.sh` | shared paths and the Wine environment, in one place |
| `lib/sg-run-explorer` | runs inside the compositor; starts explorer |
| `config/greetd-config.toml` | autologin placeholder for `sg-greeter` |
| `systemd/sg-prefix-init.service` | first-boot fallback if the image didn't bake a prefix |

Paths default to `/var/lib/stained-glass` and are overridable via `SG_*`
environment variables — `SG_LIB`, `SG_BIN`, `SG_ROOT`, `SG_PREFIX`, `SG_STATE`,
`SG_LOG_DIR`. That overridability exists so the gate can run against a staged
tree; keep it working.

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
