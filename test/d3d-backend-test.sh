#!/bin/sh
# sg-common.sh's sg_d3d_backend: Direct3D 8-11 through Wine's own wined3d
# ("builtin") where Vulkan has only software devices (lavapipe: DXVK's frames
# never reached the screen there), DXVK ("native") where there is a GPU; the
# registry only when the answer changes. Stand-ins for vulkaninfo and wine.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
mkdir -p "$T/bin" "$T/d3d/dxvk/x64" "$T/st"
for d in d3d9 d3d11 dxgi; do : > "$T/d3d/dxvk/x64/$d.dll"; done
cat > "$T/bin/vulkaninfo" <<EOS
#!/bin/sh
cat "$T/devices"
EOS
cat > "$T/bin/wine" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$T/wine.log"
EOS
chmod 755 "$T/bin/vulkaninfo" "$T/bin/wine"
run() { ( PATH="$T/bin:$PATH"; . "$HERE/lib/sg-common.sh" >/dev/null 2>&1; sg_d3d_backend "$T/d3d" "$T/st" ) >/dev/null 2>&1; }
printf '\tdeviceType         = PHYSICAL_DEVICE_TYPE_CPU\n' > "$T/devices"
run
[ "$(grep -c '/d builtin' "$T/wine.log" 2>/dev/null)" = 3 ] && grep -q '/v d3d11 ' "$T/wine.log" \
    && pass "only a software Vulkan device: D3D 8-11 are Wine's own (builtin)" || fail "cpu: $(cat "$T/wine.log" 2>/dev/null)"
rm -f "$T/wine.log"; run
[ ! -e "$T/wine.log" ] && pass "the same answer next boot: Wine is not started" || fail "re-ran: $(cat "$T/wine.log")"
printf '\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_CPU\n' > "$T/devices"
run
[ "$(grep -c '/d native' "$T/wine.log" 2>/dev/null)" = 3 ] && pass "a GPU (beside lavapipe): DXVK again (native)" || fail "gpu: $(cat "$T/wine.log" 2>/dev/null)"
rm -f "$T/wine.log"; : > "$T/devices"; run
[ ! -e "$T/wine.log" ] && pass "no answer from vulkaninfo: left as it is" || fail "unknown changed it: $(cat "$T/wine.log")"
exit $RC
