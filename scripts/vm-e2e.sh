#!/usr/bin/env bash
# In-guest headless E2E (run by the compositor-demo systemd service).
# Builds the repo with the guest toolchain into /tmp (the shared 9p dir
# stays untouched), then runs server + test client; CLIENT-OK on the
# console is the pass signal. Powers off afterwards.
set -uo pipefail
exec > /dev/console 2>&1

cd /shared/repo || { echo "VM-E2E-FAILED: repo share not mounted"; poweroff -f; exit 1; }
# 9p defaults to cache=loose: host-side edits can be invisible to the
# guest. Drop the cache so every boot builds the CURRENT source.
mount -o remount,cache=none /shared/repo 2>/dev/null || true
echo "=== share sanity: $(grep -c wantDrmBackend src/server/main.zig 2>/dev/null || echo 0) drm-wiring refs ==="
echo "=== vm-e2e: building with the guest toolchain (first boot compiles) ==="
# The guest E2E is headless: build without the raylib window backend
# (build.zig's -Denable_raylib=false also skips the raylib pkg-config probe).
# The systemd service has no HOME: zig's translate-c subprocess cannot
# resolve its cache dir (AppDataDirUnavailable). Give it one.
export HOME=/root
export XDG_CACHE_HOME=/tmp/zig-xdg
zig build --prefix /tmp/zo --cache-dir /tmp/zc --global-cache-dir /tmp/zgc \
    -Denable_raylib=false > /tmp/build.log 2>&1
if [ ! -x /tmp/zo/bin/wayland-server ] || [ ! -x /tmp/zo/bin/wayland-client ]; then
    echo "=== build failed; log tail: ==="
    tail -40 /tmp/build.log
    echo "VM-E2E-FAILED: build did not produce binaries"
    poweroff -f
    exit 1
fi
echo "=== vm-e2e: build ok, running headless E2E ==="

mkdir -p /tmp/rt
XDG_RUNTIME_DIR=/tmp/rt WAYLAND_BACKEND=headless WAYLAND_SYNTH_INPUT=1 \
    WAYLAND_LOG=err WAYLAND_RUN_FRAMES=400 \
    /tmp/zo/bin/wayland-server > /tmp/srv.out 2>/dev/null &
SRV=$!
SOCK=""
for _ in $(seq 1 40); do
    SOCK=$(grep -m1 '^WAYLAND_SOCKET=' /tmp/srv.out 2>/dev/null | cut -d= -f2)
    [ -n "$SOCK" ] && break
    sleep 0.5
done
if [ -z "$SOCK" ]; then
    echo "VM-E2E-FAILED: server did not print a socket"
    poweroff -f
    exit 1
fi

XDG_RUNTIME_DIR=/tmp/rt WAYLAND_DISPLAY="$SOCK" /tmp/zo/bin/wayland-client 2>/tmp/cli.log
RC=$?
kill "$SRV" 2>/dev/null
echo "=== vm-e2e: client rc=$RC ==="
if [ "$RC" -eq 0 ]; then
    echo "VM-E2E-OK"
else
    echo "VM-E2E-FAILED (client rc=$RC)"
fi
poweroff -f
