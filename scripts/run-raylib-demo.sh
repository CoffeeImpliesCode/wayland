#!/usr/bin/env bash
# M2 raylib debug backend demo: a compositor window showing a spinning
# client surface (weston-simple-shm).
#
# Usage: ./scripts/run-raylib-demo.sh [frames]
#   frames — stop the server after N rendered frames (default 0 = forever)
#
# Requires: `zig build` done, `devenv shell` run at least once (the devenv
# env provides LD_LIBRARY_PATH for raylib/wayland/xorg — no manual paths),
# and the weston clients built (default path below, overridable).
#
# Ctrl-C (or client exit) stops both processes.

set -euo pipefail
cd "$(dirname "$0")/.."

FRAMES="${1:-0}"
SERVER_BIN=./zig-out/bin/wayland-server
CLIENT_BIN="${WAYLAND_DEMO_CLIENT:-~/projects/freedesktop-wayland-weston/build/clients/weston-simple-shm}"
SERVER_OUT="$(mktemp)"

# The devenv shell env supplies LD_LIBRARY_PATH/PKG_CONFIG_PATH from the
# nix closure (wayland, raylib, xorg, ...). Source it if present.
if [ -f .devenv/shell-env.sh ]; then
    # shellcheck disable=SC1091
    source .devenv/shell-env.sh
fi

# SDL needs a reachable display: prefer the session wayland socket.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -S "/run/user/$(id -u)/wayland-1" ]; then
    export WAYLAND_DISPLAY=wayland-1
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
fi

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
    echo "weston-simple-shm missing at $CLIENT_BIN" >&2
    echo "set WAYLAND_DEMO_CLIENT to its path, or build the weston clients" >&2
    exit 1
fi

echo "starting raylib compositor (window: wayland-m2, ${FRAMES:-unlimited} frames)..."
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
echo "server ready: WAYLAND_DISPLAY=$SOCKET (window on $WAYLAND_DISPLAY)"

echo "launching weston-simple-shm (spinning pattern, top-left of the window)..."
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    WAYLAND_DISPLAY="$SOCKET" \
    "$CLIENT_BIN" &
CLIENT_PID=$!

wait "$CLIENT_PID"
echo "client exited; stopping server"
