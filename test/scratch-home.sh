# Sourced first by every gate that runs Wine. A prefix links
# C:\users\<user>\Desktop, Documents, Downloads, Music, Pictures, Videos and
# Templates to $HOME's folders, and winemenubuilder writes menu entries and
# desktop files under $HOME: a gate on the real HOME reads, writes and
# deletes the real user's files. So every gate gets a HOME of its own.
# The cache is the gate's too (Disk Cleanup and Storage Sense empty it); a
# gate that keeps downloads across runs names "$SG_REAL_HOME/.cache" itself.
# Python's user packages stay the real home's.
if [ -z "${SG_GATE_HOME:-}" ]; then
    SG_REAL_HOME=${HOME:-/nonexistent}
    export SG_REAL_HOME
    export PYTHONUSERBASE="${PYTHONUSERBASE:-$SG_REAL_HOME/.local}"
    SG_GATE_HOME=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-gate-home.XXXXXX") || exit 1
    export SG_GATE_HOME HOME="$SG_GATE_HOME"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share" XDG_DESKTOP_DIR="$HOME/Desktop"
    mkdir -p "$HOME/Desktop" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
    export WINEDLLOVERRIDES="winemenubuilder.exe=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
fi
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
