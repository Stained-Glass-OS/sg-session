#!/bin/sh
# /etc/profile.d/00-stained-glass-xdg.sh: a login gets the XDG spec's defaults
# before ~/.profile, so the common "export XDG_DATA_DIRS=$HOME/.local/share:
# $XDG_DATA_DIRS" keeps /usr/share (David's dev box, 2026-11-16: the Vulkan
# loader found no driver, Wine gates hung). A value already set is kept.
#   SG_XDG_PROFILE=<file> tests another copy (mutant: an empty file)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
F=${SG_XDG_PROFILE:-$HERE/config/profile.d/00-stained-glass-xdg.sh}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
v=$(env -i HOME=/home/x sh -c '. "$1"; export XDG_DATA_DIRS="$HOME/.local/share:$XDG_DATA_DIRS"; echo "$XDG_DATA_DIRS"' x "$F")
case ":$v:" in *:/usr/share:*) pass "a ~/.profile that appends keeps /usr/share ($v)" ;; *) fail "XDG_DATA_DIRS after ~/.profile: '$v'" ;; esac
v=$(env -i sh -c '. "$1"; echo "$XDG_CONFIG_DIRS"' x "$F")
[ "$v" = /etc/xdg ] && pass "XDG_CONFIG_DIRS defaults to /etc/xdg" || fail "XDG_CONFIG_DIRS: '$v'"
v=$(env -i XDG_DATA_DIRS=/opt/x/share sh -c '. "$1"; echo "$XDG_DATA_DIRS"' x "$F")
[ "$v" = /opt/x/share ] && pass "a value already set is kept" || fail "a set value was changed: '$v'"
exit $RC
