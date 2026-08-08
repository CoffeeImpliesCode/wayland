#!/usr/bin/env bash
# In-guest DRM/KMS + libinput E2E (run by the compositor-demo-drm systemd
# service). Builds the repo with the guest toolchain into /tmp (the shared
# 9p dir stays untouched), then runs the DRM backend on /dev/dri/card0
# (virtio-gpu) with the libinput source on /dev/input/* (virtio keyboard +
# mouse) plus the test client. Verdicts go to the console; CLIENT-OK plus
# drm:/libinput: lines in the server log are the pass signals. Powers off.
set -uo pipefail
exec > /dev/console 2>&1

cd /shared/repo || { echo "VM-DRM-E2E-FAILED: repo share not mounted"; poweroff -f; exit 1; }
# 9p defaults to cache=loose: host-side edits can be invisible to the
# guest. Drop the cache so every boot builds the CURRENT source.
mount -o remount,cache=none /shared/repo 2>/dev/null || true
echo "=== share sanity: $(grep -c wantDrmBackend src/server/main.zig 2>/dev/null || echo 0) drm-wiring refs ==="
echo "=== vm-drm-e2e: building with the guest toolchain ==="
# Same flags as the headless E2E: the drm + libinput backends compile
# unconditionally, so no extra -D options are needed (guest has no raylib).
# Forced clean build: no stale artifacts from any cache (the 9p view
# was stale across boots despite the remount; start from zero each time).
rm -rf /tmp/zo /tmp/zc /tmp/zgc
# The systemd service has no HOME: zig's translate-c subprocess cannot
# resolve its cache dir (AppDataDirUnavailable). Give it one.
export HOME=/root
export XDG_CACHE_HOME=/tmp/zig-xdg
zig build --prefix /tmp/zo --cache-dir /tmp/zc --global-cache-dir /tmp/zgc \
    -Denable_raylib=false > /tmp/build.log 2>&1
if [ ! -x /tmp/zo/bin/wayland-server ] || [ ! -x /tmp/zo/bin/wayland-client ]; then
    echo "=== build failed; log tail: ==="
    tail -40 /tmp/build.log
    echo "VM-DRM-E2E-FAILED: build did not produce binaries"
    poweroff -f
    exit 1
fi
# Fail fast if the binary lacks the DRM wiring (stale-source smoke).
# Note: the guest has no `strings` binary; grep -a reads the binary text.
WIRED=$(grep -a -c "WAYLAND_BACKEND" /tmp/zo/bin/wayland-server || true)
echo "=== binary wiring check: $WIRED refs ==="
if [ "$WIRED" -eq 0 ]; then
    echo "=== diagnostics: ==="
    echo "zig: $(zig version)"
    echo "source md5: $(md5sum src/server/main.zig | cut -d' ' -f1)"
    echo "binary md5: $(md5sum /tmp/zo/bin/wayland-server | cut -d' ' -f1)"
    echo "=== build.log tail: ==="
    tail -15 /tmp/build.log
    echo "VM-DRM-E2E-FAILED: binary has no WAYLAND_BACKEND strings (stale build)"
    poweroff -f
    exit 1
fi
# DRM init failed (or the client failed): dump the kernel's view of the
# modeset attempt (virtio-gpu logs atomic rejections to dmesg).
if ! grep -q "VM-DRM-E2E-OK" /tmp/srv.out 2>/dev/null; then
    echo "=== kernel log (virtio-gpu/kms): ==="
    journalctl -k --no-pager 2>/dev/null | grep -iE "virtio|drm|atomic|kms" | tail -40
fi
echo "=== vm-drm-e2e: build ok, running DRM E2E ==="

mkdir -p /tmp/rt
# Server log (stderr) goes to /tmp/srv.out so the drm:/libinput: lines are
# greppable. WAYLAND_LOG=err would hide info-level lines; keep the rest of
# the log quiet but let the drm + libinput tags through.
XDG_RUNTIME_DIR=/tmp/rt WAYLAND_BACKEND=drm WAYLAND_LIBINPUT=1 \
    WAYLAND_SYNTH_INPUT=1 \
    WAYLAND_LOG=err,server=debug,surface=debug,xdg=debug,shm=debug,drm=info,libinput=info WAYLAND_RUN_FRAMES=600 \
    /tmp/zo/bin/wayland-server > /tmp/srv.out 2>&1 &
SRV=$!
SOCK=""
for _ in $(seq 1 120); do
    SOCK=$(grep -m1 '^WAYLAND_SOCKET=' /tmp/srv.out 2>/dev/null | cut -d= -f2)
    [ -n "$SOCK" ] && break
    sleep 0.5
done
if [ -z "$SOCK" ]; then
    echo "VM-DRM-E2E-FAILED: server did not print a socket"
    poweroff -f
    exit 1
fi

XDG_RUNTIME_DIR=/tmp/rt WAYLAND_DISPLAY="$SOCK" /tmp/zo/bin/wayland-client \
    > /tmp/cli.out 2>&1
RC=$?
# The server stops itself after WAYLAND_RUN_FRAMES; wait briefly, then kill.
for _ in $(seq 1 40); do
    kill -0 "$SRV" 2>/dev/null || break
    sleep 0.5
done
kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

DRM_LINES=$(grep -c "drm:" /tmp/srv.out 2>/dev/null || true)
# The startup logs (drm:/libinput:) live at the HEAD of the log; the tail
# is dominated by teardown noise. Show both when the E2E failed.
if [ "$RC" -ne 0 ] || [ "$DRM_LINES" -eq 0 ]; then
    echo "=== /dev/dri: ==="
    ls -la /dev/dri 2>&1
    echo "=== virtio modules: ==="
    grep -E "virtio|drm" /proc/modules 2>/dev/null | head -8
    echo "=== binary evidence (drm branch wired?): ==="
    strings /tmp/zo/bin/wayland-server | grep -c "WAYLAND_BACKEND" | xargs echo "wantDrmBackend strings:"
    echo "=== pci virtio devices: ==="
    for d in /sys/bus/pci/devices/*/; do
        v=$(cat "$d/vendor" 2>/dev/null); [ "$v" = "0x1af4" ] && echo "$d: $(cat $d/device 2>/dev/null) $(cat $d/uevent 2>/dev/null | head -2 | tr '\n' ' ')"
    done
    echo "=== server log (full): ==="
    cat /tmp/srv.out
fi
LIBINPUT_LINES=$(grep -c "libinput:" /tmp/srv.out 2>/dev/null || true)
echo "=== vm-drm-e2e: client rc=$RC drm_lines=$DRM_LINES libinput_lines=$LIBINPUT_LINES ==="
if [ "$RC" -eq 0 ] && grep -q "CLIENT-OK" /tmp/cli.out &&
   [ "$DRM_LINES" -gt 0 ] && [ "$LIBINPUT_LINES" -gt 0 ]; then
    echo "VM-DRM-E2E-OK"
else
    echo "=== server log tail: ==="
    tail -40 /tmp/srv.out
    echo "=== client log tail: ==="
    tail -40 /tmp/cli.out
    echo "VM-DRM-E2E-FAILED"
fi
poweroff -f
