#!/usr/bin/env bash
# Run the windowed raylib debug backend + a client (host-side tool).
#
# The raylib backend needs a live X11/Wayland session (GLFW opens the
# window); it feeds the seat from the window's own keyboard + mouse.
#
# Default client is the wayland-client test client (runs its E2E:
# connect -> map a gradient -> screencopy verify -> synth zoom -> CLIENT-OK,
# then exits). Set CLIENT to a command (e.g. a terminal) to run that instead.
#
#   scripts/run-raylib.sh                        # test client, exits after E2E
#   CLIENT=foot scripts/run-raylib.sh            # launch a terminal instead
#   CLIENT='weston-terminal' scripts/run-raylib.sh
#   WAYLAND_CAMERA="cx=640,cy=360,zoom=1.5" scripts/run-raylib.sh
#   WAYLAND_LOG=err,server=debug scripts/run-raylib.sh
#
# The server runs until the client exits (test client) or you Ctrl-C
# (CLIENT=terminal); both paths kill the server.
set -u

# The raylib window needs a live display; fail fast otherwise (GLFW's
# "Failed to connect to display" is not actionable).
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "run-raylib: no DISPLAY or WAYLAND_DISPLAY — the raylib window needs a live X11/Wayland session" >&2
    exit 1
fi

# Fresh runtime dir so the socket name is predictable.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/rt}"
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Build the server if the binary is missing.
if [ ! -x ./zig-out/bin/wayland-server ]; then
    echo "run-raylib: building..."
    zig build || { echo "run-raylib: build failed" >&2; exit 1; }
fi

# Backend + camera + logging, all overridable from the environment. The
# demo stays up (no RUN_FRAMES, watchdog disabled); WAYLAND_SYNTH_INPUT is
# unset so the raylib window's own input drives the seat.
export WAYLAND_BACKEND="${WAYLAND_BACKEND:-raylib}"
export WAYLAND_CAMERA="${WAYLAND_CAMERA:-cx=640,cy=360,zoom=1.5}"
export WAYLAND_LOG="${WAYLAND_LOG:-err,server=info}"
export WAYLAND_WATCHDOG_DISABLE=1

LOG="$XDG_RUNTIME_DIR/raylib-server.log"
echo "run-raylib: starting server (backend=$WAYLAND_BACKEND, log=$LOG)..."
./zig-out/bin/wayland-server > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; exit 0' INT TERM EXIT

# The server prints its socket on stdout as WAYLAND_SOCKET=wayland-N;
# read it from the log (robust to pre-existing sockets).
SOCK=""
for _ in $(seq 1 100); do
    SOCK=$(grep -m1 '^WAYLAND_SOCKET=' "$LOG" 2>/dev/null | cut -d= -f2)
    if [ -n "$SOCK" ] && [ -S "$XDG_RUNTIME_DIR/$SOCK" ]; then
        break
    fi
    if ! kill -0 "$SRV" 2>/dev/null; then
        echo "run-raylib: server exited before the socket appeared" >&2
        tail -20 "$LOG"
        exit 1
    fi
    sleep 0.1
done

if [ -z "$SOCK" ] || [ ! -S "$XDG_RUNTIME_DIR/$SOCK" ]; then
    echo "run-raylib: server socket never appeared" >&2
    tail -20 "$LOG"
    exit 1
fi
echo "run-raylib: server ready (socket $SOCK, pid $SRV)"

# Client: the test client by default, or CLIENT=<command>.
if [ -n "${CLIENT:-}" ]; then
    echo "run-raylib: running client: $CLIENT"
    WAYLAND_DISPLAY="$SOCK" bash -c "$CLIENT"
    RC=$?
else
    echo "run-raylib: running test client (set CLIENT=... to override)"
    WAYLAND_DISPLAY="$SOCK" ./zig-out/bin/wayland-client
    RC=$?
fi

echo "run-raylib: client exited rc=$RC; stopping server"
