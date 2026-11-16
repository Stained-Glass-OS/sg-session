# Stained Glass OS: the XDG base directories' defaults (the XDG spec's), set
# before a person's ~/.profile runs. A common idiom there,
#   export XDG_DATA_DIRS="$HOME/.local/share:$XDG_DATA_DIRS"
# on a login where nothing set it first left "~/.local/share:" -- /usr/share
# gone: no Vulkan driver (the loader finds its ICDs there), no icons, no
# .desktop files (David's dev box, 2026-11-16). GDM and systemd's user
# environment set this default; a tty or ssh login had none.
if [ -z "${XDG_DATA_DIRS:-}" ]; then
    XDG_DATA_DIRS=/usr/local/share:/usr/share
    export XDG_DATA_DIRS
fi
if [ -z "${XDG_CONFIG_DIRS:-}" ]; then
    XDG_CONFIG_DIRS=/etc/xdg
    export XDG_CONFIG_DIRS
fi
