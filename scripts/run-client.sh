#!/usr/bin/env bash
# Run a Wayland client against the nested compositor and report a verdict.
#
# Usage: run-client.sh <client> [args...]
#   client  - the client binary name or path (run with WAYLAND_DISPLAY set
#             to our nested server's socket)
#
# Environment:
#   XDG_RUNTIME_DIR   - must be set (defaults to /tmp/wlrt)
#   PARENT_SOCKET     - parent weston socket name (default weston-parent)
#   CLIENT_TIMEOUT    - seconds to run the client (default 5)
#
# Prints:  PASS <client> | FAIL <client> (<reason>)
# Exits:   0 on pass, 1 on fail.
#
# Verdict rules:
#   - exit 124 (timeout) = client ran the full window without dying = PASS
#   - nonzero exit with "Connection" / protocol error on stderr = FAIL
#   - the client log is kept at $XDG_RUNTIME_DIR/client-<name>.log

set -u

CLIENT="$1"; shift || true
NAME="$(basename "$CLIENT")"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/wlrt}"
PARENT_SOCKET="${PARENT_SOCKET:-weston-parent}"
TIMEOUT="${CLIENT_TIMEOUT:-5}"
LOG="$XDG_RUNTIME_DIR/client-$NAME.log"

# Ensure the runtime dir exists with correct perms (nested backend needs 0700).
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

# The parent weston provides the nested backend's parent surface. Start it
# if it is not already running on PARENT_SOCKET.
if ! weston --backend=headless --socket="$PARENT_SOCKET" --idle-time=0 \
    --log="$XDG_RUNTIME_DIR/weston-parent.log" >/dev/null 2>&1 & then
    :
fi
WESTON_PID=$!
# Give weston a moment to create its socket.
for _ in $(seq 1 20); do
    [ -S "$XDG_RUNTIME_DIR/$PARENT_SOCKET" ] && break
    sleep 0.1
done

# Start our nested compositor; stdout carries the WAYLAND_SOCKET line.
SERVER_LOG="$XDG_RUNTIME_DIR/server.log"
rm -f "$SERVER_LOG"
env WAYLAND_DISPLAY="$PARENT_SOCKET" WAYLAND_BACKEND=nested \
    zig-out/bin/wayland-server >"$XDG_RUNTIME_DIR/server.stdout" 2>"$SERVER_LOG" &
SERVER_PID=$!

# Wait for the socket line.
OUR_SOCKET=""
for _ in $(seq 1 50); do
    if [ -s "$XDG_RUNTIME_DIR/server.stdout" ]; then
        OUR_SOCKET="$(grep -o 'WAYLAND_SOCKET=[^ ]*' "$XDG_RUNTIME_DIR/server.stdout" | head -1 | cut -d= -f2)"
        [ -n "$OUR_SOCKET" ] && break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
done

if [ -z "$OUR_SOCKET" ]; then
    echo "FAIL $NAME (server did not print WAYLAND_SOCKET; server log:)"
    tail -5 "$SERVER_LOG" 2>/dev/null
    kill "$SERVER_PID" "$WESTON_PID" 2>/dev/null
    exit 1
fi

# Run the client.
env WAYLAND_DISPLAY="$OUR_SOCKET" timeout "$TIMEOUT" "$CLIENT" "$@" >"$LOG" 2>&1
RC=$?
kill "$SERVER_PID" "$WESTON_PID" 2>/dev/null

case "$RC" in
    0|124)
        echo "PASS $NAME (exit $RC)"
        exit 0
        ;;
    *)
        echo "FAIL $NAME (exit $RC)"
        echo "--- client log ---"
        tail -15 "$LOG" 2>/dev/null
        echo "--- server log tail ---"
        tail -15 "$SERVER_LOG" 2>/dev/null
        exit 1
        ;;
esac
