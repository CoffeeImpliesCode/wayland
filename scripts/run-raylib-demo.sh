#!/usr/bin/env bash
# M2 raylib debug backend demo: a compositor window showing a spinning
# client surface (weston-simple-shm).
#
# Usage: ./scripts/run-raylib-demo.sh [frames]
#   frames — stop the server after N rendered frames (default 0 = forever)
#
# Ctrl-C (or client exit) stops both processes.

set -euo pipefail
cd "$(dirname "$0")/.."

FRAMES="${1:-0}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/m1xdg}"
SERVER_BIN=./zig-out/bin/wayland-server
CLIENT_BIN=~/projects/freedesktop-wayland-weston/build/clients/weston-simple-shm
WAYLAND_LIB_PATH=/tmp/wlprefix/usr/local/lib # libwayland for the C client
SERVER_OUT="$(mktemp)"

cleanup() {
    kill "${CLIENT_PID:-}" "${SERVER_PID:-}" 2>/dev/null || true
    rm -f "$SERVER_OUT"
}
trap cleanup EXIT INT TERM

if [ ! -x "$SERVER_BIN" ]; then
    echo "server binary missing — run: zig build" >&2
    exit 1
fi
if [ ! -x "$CLIENT_BIN" ]; then
    echo "weston-simple-shm missing — build the weston clients first" >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR"
unset WAYLAND_DISPLAY # let SDL pick the X11 driver for the window

echo "starting raylib compositor (window: wayland-m2, ${FRAMES:-unlimited} frames)..."
XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_BACKEND=raylib \
    WAYLAND_LOG="${WAYLAND_LOG:-info}" \
    WAYLAND_RUN_FRAMES="$FRAMES" \
    "$SERVER_BIN" >"$SERVER_OUT" 2>&1 &
SERVER_PID=$!

SOCKET=""
for _ in $(seq 1 40); do
    SOCKET="$(grep -m1 '^WAYLAND_SOCKET=' "$SERVER_OUT" | cut -d= -f2)" || true
    [ -n "$SOCKET" ] && break
    sleep 0.5
done
if [ -z "$SOCKET" ]; then
    echo "server did not print a socket; log:" >&2
    tail -20 "$SERVER_OUT" >&2
    exit 1
fi
echo "server ready: WAYLAND_DISPLAY=$SOCKET"

echo "launching weston-simple-shm (spinning pattern, top-left of the window)..."
LD_LIBRARY_PATH="$WAYLAND_LIB_PATH" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    WAYLAND_DISPLAY="$SOCKET" \
    "$CLIENT_BIN" &
CLIENT_PID=$!

wait "$CLIENT_PID"
echo "client exited; stopping server"
