#!/usr/bin/env bash
# In-guest DRM/KMS + libinput E2E (run by the compositor-demo-drm systemd
# service). Builds the repo with the guest toolchain into /tmp (the shared
# 9p dir stays untouched), then runs the DRM backend on /dev/dri/card0
# (virtio-gpu) with the libinput source on /dev/input/* (virtio keyboard +
# mouse) plus the test client. Verdicts go to the console; CLIENT-OK plus
# drm:/libinput: lines in the server log are the pass signals. Powers off.
#
# Host wrapper contract: the runner invokes this script under `timeout
# 480`; exit 124 with the OK/FAIL line in the log is the expected
# termination. The guest powers off on every path.
set -uo pipefail
exec > /dev/console 2>&1

# Interactive mode: when the HOST created /shared/repo/.no-auto-demo, skip
# the auto E2E and start the interactive demo (DRM server + foot) instead.
if [ -f /shared/repo/.no-auto-demo ]; then
    echo "=== auto E2E skipped (.no-auto-demo present); starting interactive demo ==="
    systemctl start compositor-demo-interactive
    poweroff -f
    exit 0
fi

cd /shared/repo || { echo "VM-DRM-E2E-FAILED: repo share not mounted"; poweroff -f; exit 1; }
# 9p defaults to cache=loose: host-side edits can be invisible to the
# guest. Drop the cache so every boot builds the CURRENT source.
# The guest image ships no mount(8): when it is absent, the forced
# cache clean below plus the wiring grep are the staleness defenses.
if command -v mount >/dev/null 2>&1; then
    if ! mount -o remount,cache=none /shared/repo; then
        echo "VM-DRM-E2E-FAILED: 9p remount failed"
        poweroff -f
        exit 1
    fi
else
    echo "=== vm-drm-e2e: 9p remount skipped: no mount(8) in guest (cache=none mitigation unavailable); cache clean + wiring grep are the staleness defenses ==="
fi
echo "=== share sanity: $(grep -c wantDrmBackend src/server/main.zig 2>/dev/null || echo 0) marker refs ==="
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
# WAYLAND_BACKEND would match both wantDrmBackend and wantRaylibBackend;
# WAYLAND_DRM_DEVICE appears only in wantDrmBackend (main.zig:1018-1024),
# so it proves the DRM path is actually compiled in.
# Note: the guest has no `strings` binary; grep -a reads the binary text.
WIRED=$(grep -a -c "WAYLAND_DRM_DEVICE" /tmp/zo/bin/wayland-server || true)
echo "=== drm wiring present: $WIRED refs ==="
if [ "$WIRED" -eq 0 ]; then
    echo "=== diagnostics: ==="
    echo "zig: $(zig version)"
    echo "source md5: $(md5sum src/server/main.zig | cut -d' ' -f1)"
    echo "binary md5: $(md5sum /tmp/zo/bin/wayland-server | cut -d' ' -f1)"
    echo "=== build.log tail: ==="
    tail -15 /tmp/build.log
    echo "VM-DRM-E2E-FAILED: binary has no WAYLAND_DRM_DEVICE (drm wiring missing; stale build)"
    poweroff -f
    exit 1
fi
# DRM init failures are diagnosed in the failure branch below (kernel
# log, server log, client log).
echo "=== vm-drm-e2e: build ok, running DRM E2E ==="

mkdir -p /tmp/rt
# Server log (stderr) goes to /tmp/srv.out so the drm:/libinput: lines are
# greppable. WAYLAND_LOG=err would hide info-level lines; keep the rest of
# the log quiet but let the drm + libinput tags through.
XDG_RUNTIME_DIR=/tmp/rt WAYLAND_BACKEND=drm WAYLAND_LIBINPUT=1 \
    WAYLAND_SYNTH_INPUT=1 \
    WAYLAND_CAMERA="cx=640,cy=360,zoom=2" \
    WAYLAND_LOG=err,server=debug,surface=debug,xdg=debug,shm=debug,drm=info,libinput=info WAYLAND_RUN_FRAMES=900 \
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

XDG_RUNTIME_DIR=/tmp/rt WAYLAND_DISPLAY="$SOCK" WAYLAND_CAMERA="cx=640,cy=360,zoom=2" /tmp/zo/bin/wayland-client \
    > /tmp/cli.out 2>&1
RC=$?
# The server stops itself after WAYLAND_RUN_FRAMES; wait briefly, then kill.
for _ in $(seq 1 40); do
    kill -0 "$SRV" 2>/dev/null || break
    sleep 0.5
done
kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

DRM_LINES=$(grep -c "drm: modeset ok" /tmp/srv.out 2>/dev/null || true)
# The startup logs (drm:/libinput:) live at the HEAD of the log; the tail
# is dominated by teardown noise. Show both when the E2E failed.
if [ "$RC" -ne 0 ] || [ "$DRM_LINES" -eq 0 ]; then
    echo "=== /dev/dri: ==="
    ls -la /dev/dri 2>&1
    echo "=== virtio modules: ==="
    grep -E "virtio|drm" /proc/modules 2>/dev/null | head -8
    echo "=== binary evidence (drm branch wired?): ==="
    grep -a -c "WAYLAND_DRM_DEVICE" /tmp/zo/bin/wayland-server | xargs echo "WAYLAND_DRM_DEVICE refs:"
    echo "=== pci virtio devices: ==="
    for d in /sys/bus/pci/devices/*/; do
        v=$(cat "$d/vendor" 2>/dev/null); [ "$v" = "0x1af4" ] && echo "$d: $(cat $d/device 2>/dev/null) $(cat $d/uevent 2>/dev/null | head -2 | tr '\n' ' ')"
    done
    echo "=== server log (full): ==="
    cat /tmp/srv.out
fi
LIBINPUT_LINES=$(grep -c "libinput:" /tmp/srv.out 2>/dev/null || true)
LEAKS=$(grep -c "leaked" /tmp/srv.out 2>/dev/null || true)
echo "=== vm-drm-e2e: client rc=$RC drm_lines=$DRM_LINES libinput_lines=$LIBINPUT_LINES ==="
echo "=== leak check: $LEAKS (expect 0; DebugAllocator at server exit) ==="
if [ "$RC" -eq 0 ] && grep -q "CLIENT-OK" /tmp/cli.out &&
   [ "$DRM_LINES" -gt 0 ] && [ "$LIBINPUT_LINES" -gt 0 ] && [ "$LEAKS" -eq 0 ]; then
    echo "VM-DRM-E2E-OK"
else
    echo "=== kernel log (virtio-gpu/kms): ==="
    journalctl -k --no-pager 2>/dev/null | grep -iE "virtio|drm|atomic|kms" | tail -40
    echo "=== server log tail: ==="
    tail -40 /tmp/srv.out
    echo "=== client log tail: ==="
    tail -40 /tmp/cli.out
    echo "VM-DRM-E2E-FAILED"
fi
poweroff -f
