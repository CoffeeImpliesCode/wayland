#!/usr/bin/env bash
# Interactive canvas demo: DRM backend + foot terminal on the virtio-gpu
# output, no auto-poweroff. Launched by the compositor-demo-drm boot gate
# when /shared/repo/.no-auto-demo exists on the host share (touch the file
# on the HOST, then boot the VM WITHOUT -nographic so qemu opens a window).
#
# Controls (through libinput + the M4 seat hooks):
#   left-button drag  pan the camera
#   mouse wheel       zoom (x1.25 per notch, clamped 0.1-16)
#   click             focus the terminal (click-to-focus)
set -u

export HOME=/root
export XDG_RUNTIME_DIR=/tmp/rt
export XDG_CACHE_HOME=/tmp/zig-xdg
mkdir -p /tmp/rt
chmod 700 /tmp/rt

# The server was built by the boot gate; reuse the binary + caches.
export WAYLAND_BACKEND=drm
export WAYLAND_LIBINPUT=1
export WAYLAND_SYNTH_INPUT=0
# A visible starting zoom so pan/zoom feel real; no RUN_FRAMES (run until
# the VM stops), the frame watchdog self-re-arms.
export WAYLAND_CAMERA="cx=640,cy=360,zoom=1.5"
export WAYLAND_LOG=err,drm=info,libinput=info

/tmp/zo/bin/wayland-server > /tmp/srv-interactive.log 2>&1 &
SRV=$!
for _ in $(seq 1 50); do
    [ -S /tmp/rt/wayland-1 ] && break
    sleep 0.1
done

if [ ! -S /tmp/rt/wayland-1 ]; then
    echo "VM-INTERACTIVE-FAILED: server socket never appeared"
    tail -20 /tmp/srv-interactive.log
    poweroff -f
    exit 1
fi

WAYLAND_DISPLAY=wayland-1 "${FOOT:-foot}" --font="monospace:size=14" \
    > /tmp/foot.log 2>&1 &
FOOT_PID=$!

sleep 1
if ! kill -0 "$FOOT_PID" 2>/dev/null; then
    echo "VM-INTERACTIVE-FAILED: foot died after 1s"
    tail -20 /tmp/foot.log
    poweroff -f
    exit 1
fi

echo "VM-INTERACTIVE-OK: server pid $SRV, foot pid $FOOT_PID (drag to pan, wheel to zoom)"
# Keep the oneshot unit alive; the demo ends when the VM powers off.
while kill -0 "$SRV" 2>/dev/null; do
    sleep 1
done
echo "VM-INTERACTIVE: server exited"
