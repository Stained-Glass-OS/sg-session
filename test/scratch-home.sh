# Sourced first by every gate that runs Wine. A prefix links
# C:\users\<user>\Desktop, Documents, Downloads, Music, Pictures, Videos and
# Templates to $HOME's folders, and winemenubuilder writes menu entries and
# desktop files under $HOME: a gate on the real HOME reads, writes and
# deletes the real user's files. So every gate gets a HOME of its own.
# The cache is the gate's too (Disk Cleanup and Storage Sense empty it); a
# gate that keeps downloads across runs names "$SG_REAL_HOME/.cache" itself.
# Python's user packages stay the real home's.
# Gates leave their scratch behind when they are killed, and the gate HOME
# below is never removed (each gate sets its own EXIT trap): 6000 of them,
# 161 GB, in /var/tmp by 2026-11-01. Every gate start takes away what is
# more than a day old -- a gate's HOME and a gate's mktemp directory
# (sg-<name>.XXXXXX) -- so the host never fills up with them.
find "${TMPDIR:-/var/tmp}" -maxdepth 1 -mindepth 1 -type d -mtime +0 \
    \( -name 'sg-gate-home.??????' -o -name 'sg-*.??????' \) ! -name 'sg-lint-tree-*' \
    -exec sh -c 'chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"' _ {} \; 2>/dev/null
if [ -z "${SG_GATE_HOME:-}" ]; then
    SG_REAL_HOME=${HOME:-/nonexistent}
    export SG_REAL_HOME
    export PYTHONUSERBASE="${PYTHONUSERBASE:-$SG_REAL_HOME/.local}"
    SG_GATE_HOME=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-gate-home.XXXXXX") || exit 1
    export SG_GATE_HOME HOME="$SG_GATE_HOME"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share" XDG_DESKTOP_DIR="$HOME/Desktop"
    mkdir -p "$HOME/Desktop" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
    export WINEDLLOVERRIDES="winemenubuilder.exe=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
    # Nothing a gate runs may reach the person's own session: Wine's Wayland
    # driver connects to $XDG_RUNTIME_DIR/wayland-0 even with WAYLAND_DISPLAY
    # unset (2026-10-06: a printing run reached the host's desktop), and
    # DISPLAY=:0 is the host's X server. A gate starts its own display and
    # gets a runtime directory of its own; SG_REAL_XDG_RUNTIME_DIR keeps the
    # person's for the rare gate that must reach their user services.
    export SG_REAL_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
    XDG_RUNTIME_DIR="$SG_GATE_HOME/run"
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    export XDG_RUNTIME_DIR
    unset WAYLAND_DISPLAY DISPLAY
fi
# A Windows program that listens tells the firewall (wine-sg 1500), and the firewall asks the
# person on their desktop. A gate's probes must never do that (David 2026-11-21: prompts popped
# up from an agent's gate sweep). Gates that test the notice set their own SG_FIREWALL_NOTIFY.
export SG_FIREWALL_NOTIFY="$SG_GATE_HOME/no-firewall-notify"
# Shut down / Restart from a Windows program (ExitWindowsEx, InitiateSystemShutdown, shutdown.exe) runs
# SG_POWERCTL, else sg-session's /usr/bin/sg-settingsctl, which asks logind -- as the person running the
# gate, that powers off the real PC (David's desktop went down twice, 2026-11-21/22, from shutdown-gate
# in an agent's sweep). A path that does not exist: nothing is run. Gates that test it set their own.
export SG_POWERCTL="$SG_GATE_HOME/no-power-helper"
# sg_prefix_safe PREFIX: fail when any folder of PREFIX's user profiles
# resolves outside the prefix and the gate's HOME (an old prefix made on the
# real HOME). Gates that reuse a prefix call it before starting Wine.
sg_prefix_safe() {
    _bad=$(find "$1/drive_c/users" -maxdepth 6 -type l 2>/dev/null | while read -r _l; do
        _t=$(readlink -f "$_l")
        case "$_t" in "$SG_GATE_HOME"*|"$1"*) ;; *) echo "$_l -> $_t" ;; esac
    done)
    [ -z "$_bad" ] && return 0
    echo "refusing to run: $1 links outside the gate's home:" >&2
    echo "$_bad" >&2
    return 1
}
