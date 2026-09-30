#!/bin/sh
# sg-common.sh's sg_cursor_env: a virtual machine's display (virtio-gpu, QXL,
# Bochs, Cirrus) gets the compositor's own pointer -- over QEMU's VNC the
# hardware cursor was drawn upside down and off target (David). A real GPU
# keeps the hardware cursor; a value set by hand wins. A stand-in sysfs.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
card() {   # NAME DRIVER
    mkdir -p "$T/$1/drm/card0/device" "$T/$1/drivers/$2"
    ln -s "$T/$1/drivers/$2" "$T/$1/drm/card0/device/driver"
}
value() {   # SYSFS [preset]: what the compositor would get
    env -i PATH="$PATH" SG_DRM_SYSFS="$T/$1/drm" ${2:+WLR_NO_HARDWARE_CURSORS=$2} \
        sh -c ". \"$HERE/lib/sg-common.sh\" >/dev/null 2>&1; echo \"\${WLR_NO_HARDWARE_CURSORS:-unset}\""
}
card virtio virtio-pci; card qxl qxl; card intel i915; card amd amdgpu
for d in virtio qxl; do
    [ "$(value $d)" = 1 ] && echo "PASS  $d: the compositor draws the pointer" || { echo "FAIL  $d: $(value $d)"; RC=1; }
done
for d in intel amd; do
    [ "$(value $d)" = unset ] && echo "PASS  $d: the hardware cursor stays" || { echo "FAIL  $d: $(value $d)"; RC=1; }
done
[ "$(value virtio 0)" = 0 ] && echo "PASS  a value set by hand wins" || { echo "FAIL  preset: $(value virtio 0)"; RC=1; }
exit $RC
