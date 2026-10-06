#!/bin/sh
# Unit gate (in make lint): sg-session pulls in the firewall programs VPN
# clients' kill switches run (Eddie's Network Lock: nft, or iptables and
# ip6tables), so installed machines get them on apt upgrade. Without them
# Eddie said "There is no available or enabled Network Lock mode"
# (2026-10-06). The guest side is bin/sg-netlock-check (sg-image
# SG_GUEST_CHECK=netlock). --mutant: the two left out of Depends.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
CONTROL="$HERE/debian/control"
if [ "${1:-}" = --mutant ]; then
    sed 's/ nftables,//; s/ iptables,//' "$CONTROL" > "$T/control"; CONTROL="$T/control"
fi
# sg-session's Depends field, continuation lines joined
deps=$(awk '/^Package: sg-session$/{p=1} p&&/^Depends:/{d=1; sub(/^Depends:/,""); print; next}
            p&&d&&/^[ \t]/{print; next} p&&d{exit}' "$CONTROL" | tr ',' '\n' | sed 's/(.*//; s/ //g')
for pkg in nftables iptables; do
    if printf '%s\n' "$deps" | grep -qx "$pkg"; then echo "PASS  sg-session depends on $pkg"
    else echo "FAIL  sg-session does not depend on $pkg"; RC=1; fi
done
grep -q 'bin/sg-netlock-check' "$HERE/Makefile" && echo "PASS  sg-netlock-check is installed" ||
    { echo "FAIL  sg-netlock-check is not installed"; RC=1; }
exit "$RC"
