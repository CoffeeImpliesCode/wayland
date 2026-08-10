#!/usr/bin/env bash
# Run the windowed raylib debug backend + a client (host-side tool).
#
# The raylib backend needs a live X11/Wayland session (GLFW opens the
# window); it feeds the seat from the window's own keyboard + mouse.
#
# Default client is a terminal (weston-terminal, else foot) so the raylib
# window's real input drives the demo. The synth-driven test client is NOT
# the default — it needs WAYLAND_SYNTH_INPUT=1 and conflicts with the
# window input. Set CLIENT to override.
#
#   scripts/run-raylib.sh                        # terminal in the raylib window
#   CLIENT='weston-terminal --font-size=14' scripts/run-raylib.sh
#   WAYLAND_CAMERA="cx=640,cy=360,zoom=1.5" scripts/run-raylib.sh
#   WAYLAND_LOG=err,server=debug scripts/run-raylib.sh
#
# The server runs until the client exits or you Ctrl-C; both kill it.
set -u

# The raylib window needs a live display; fail fast otherwise (GLFW's
# "Failed to connect to display" is not actionable).
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "run-raylib: no DISPLAY or WAYLAND_DISPLAY — the raylib window needs a live X11/Wayland session" >&2
    exit 1
fi

# A DEDICATED runtime dir for the demo. We NEVER reuse the caller's real
# XDG_RUNTIME_DIR (e.g. /run/user/$UID): that dir holds the live Wayland,
# D-Bus, pulse and dconf sockets of the user's session, and rm -rf on it
# would destroy them. WAYLAND_RT_DIR overrides the location.
RT="${WAYLAND_RT_DIR:-/tmp/rt-raylib}"
rm -rf "$RT"
mkdir -p "$RT"
chmod 700 "$RT"
export XDG_RUNTIME_DIR="$RT"

# Build the server if the binary is missing.
if [ ! -x ./zig-out/bin/wayland-server ]; then
    echo "run-raylib: building..."
    zig build || { echo "run-raylib: build failed" >&2; exit 1; }
fi

# Backend + camera + logging, all overridable from the environment. The
# demo stays up (no RUN_FRAMES, watchdog disabled). The raylib window's own
# keyboard/mouse feeds the seat (no WAYLAND_SYNTH_INPUT — the synth is for
# the headless/DRM E2E and conflicts with the window's real input).
export WAYLAND_BACKEND="${WAYLAND_BACKEND:-raylib}"
export WAYLAND_CAMERA="${WAYLAND_CAMERA:-cx=640,cy=360,zoom=1.5}"
# Debug-by-default so the demo shows what the server does; the per-frame
# render lines are change-driven (idle-skip), so this stays readable.
# Override with WAYLAND_LOG=err,server=info for quiet runs.
export WAYLAND_LOG="${WAYLAND_LOG:-err,server=debug,raylib=debug}"
export WAYLAND_WATCHDOG_DISABLE=1

LOG="$XDG_RUNTIME_DIR/raylib-server.log"
echo "run-raylib: starting server (backend=$WAYLAND_BACKEND, log=$LOG)..."
# The server's own Wayland socket lives in $XDG_RUNTIME_DIR (our dedicated
# dir). GLFW would find THAT socket via WAYLAND_DISPLAY and connect to the
# compositor it is itself serving — a deadlock before the window opens. Run
# the server with WAYLAND_DISPLAY unset so GLFW opens the window over X11
# (DISPLAY -> Xwayland on a Wayland session). Output is teed so the
# server's log is visible in this terminal while the file stays for
# harnesses (WAYLAND_SOCKET= is grepped from the log). Process
# substitution keeps $SRV the SERVER's pid (a `| tee` pipeline would make
# it the tee's, orphaning the server on kill).
env -u WAYLAND_DISPLAY ./zig-out/bin/wayland-server > >(tee "$LOG") 2>&1 &
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

# Client: a terminal by default (the raylib window's real input drives it —
# the test client is synth-driven and incompatible). CLIENT overrides.
if [ -n "${CLIENT:-}" ]; then
    echo "run-raylib: running client: $CLIENT"
    WAYLAND_DISPLAY="$SOCK" bash -c "$CLIENT"
    RC=$?
elif command -v weston-terminal >/dev/null 2>&1; then
    echo "run-raylib: running weston-terminal"
    WAYLAND_DISPLAY="$SOCK" weston-terminal
    RC=$?
elif command -v foot >/dev/null 2>&1; then
    echo "run-raylib: running foot"
    WAYLAND_DISPLAY="$SOCK" foot
    RC=$?
else
    echo "run-raylib: no terminal (weston-terminal/foot) — running the test client; it expects WAYLAND_SYNTH_INPUT=1 and may time out" >&2
    WAYLAND_DISPLAY="$SOCK" ./zig-out/bin/wayland-client
    RC=$?
fi

echo "run-raylib: client exited rc=$RC; stopping server"
