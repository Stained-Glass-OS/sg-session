#!/bin/sh
# sg-common.sh's sg_cursor_env: a virtual machine's display rendered with GL
# (virgl) gets the compositor's own pointer -- its hardware cursor came out
# upside down and off target over QEMU's VNC (David 2026-09-30); rendered in
# software (pixman, a VM without 3D) the hardware cursor stays, or the viewer
# showed two pointers (David 2026-10-01). A real GPU keeps the hardware
# cursor; a value set by hand wins. A stand-in sysfs.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
card() {   # NAME DRIVER [virgl]
    mkdir -p "$T/$1/drm/card0/device" "$T/$1/drivers/$2"
    ln -s "$T/$1/drivers/$2" "$T/$1/drm/card0/device/driver"
    if [ -n "${3:-}" ]; then mkdir -p "$T/$1/drm/card0/device/virtio0"; echo 1000 > "$T/$1/drm/card0/device/virtio0/features"; fi
}
value() {   # SYSFS [preset]: what the compositor would get
    env -i PATH="$PATH" SG_DRM_SYSFS="$T/$1/drm" ${2:+WLR_NO_HARDWARE_CURSORS=$2} \
        sh -c ". \"$HERE/lib/sg-common.sh\" >/dev/null 2>&1; echo \"\${WLR_NO_HARDWARE_CURSORS:-unset}\""
}
card virgl virtio-pci virgl; card virtio virtio-pci; card qxl qxl; card intel i915; card amd amdgpu
[ "$(value virgl)" = 1 ] && echo "PASS  virtio-gpu with 3D (GL): the compositor draws the pointer" || { echo "FAIL  virgl: $(value virgl)"; RC=1; }
for d in virtio qxl; do
    [ "$(value $d)" = unset ] && echo "PASS  $d without 3D (pixman): one pointer, the hardware cursor" || { echo "FAIL  $d: $(value $d)"; RC=1; }
done
for d in intel amd; do
    [ "$(value $d)" = unset ] && echo "PASS  $d: the hardware cursor stays" || { echo "FAIL  $d: $(value $d)"; RC=1; }
done
[ "$(value virtio 0)" = 0 ] && echo "PASS  a value set by hand wins" || { echo "FAIL  preset: $(value virtio 0)"; RC=1; }
exit $RC
