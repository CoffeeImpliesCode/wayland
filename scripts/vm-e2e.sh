#!/usr/bin/env bash
# In-guest headless E2E (run by the compositor-demo systemd service).
# Builds the repo with the guest toolchain into /tmp (the shared 9p dir
# stays untouched), then runs server + test client; CLIENT-OK on the
# console is the pass signal. Powers off afterwards.
set -uo pipefail
exec > /dev/console 2>&1

cd /shared/repo || { echo "VM-E2E-FAILED: repo share not mounted"; systemctl poweroff; exit 1; }
echo "=== vm-e2e: building with the guest toolchain (first boot compiles) ==="
# The guest E2E is headless: build without the raylib window backend
# (build.zig's -Denable_raylib=false also skips the raylib pkg-config probe).
zig build --prefix /tmp/zo --cache-dir /tmp/zc --global-cache-dir /tmp/zgc \
    -Denable_raylib=false > /tmp/build.log 2>&1
if [ ! -x /tmp/zo/bin/wayland-server ] || [ ! -x /tmp/zo/bin/wayland-client ]; then
    echo "=== build failed; log tail: ==="
    tail -40 /tmp/build.log
    echo "VM-E2E-FAILED: build did not produce binaries"
    systemctl poweroff
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
    systemctl poweroff
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
systemctl poweroff
