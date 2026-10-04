#!/usr/bin/env bash
# In-guest DRM/KMS + libinput E2E (run by the compositor-demo-drm systemd
# service). Builds the repo with the guest toolchain into /tmp (the shared
# 9p dir stays untouched), then runs the DRM backend on the guest's GPU
# device (/dev/dri/card0) with the libinput source on /dev/input/*
# (virtio keyboard + mouse) plus the test client. Verdicts go to the
# console; CLIENT-OK plus drm:/libinput: lines in the server log are the
# pass signals. Powers off on every path.
#
# Host wrapper contract: scripts/vm-qualify.sh runs this under `timeout`,
# captures the serial console to its own artifact file and decides the
# verdict from the marker lines below. The guest powers off on every path;
# a run that never prints a marker is a FAILURE for the wrapper, never a
# pass.
#
#   VM-DRM-E2E-OK          the DRM + libinput + client E2E passed
#   VM-DMABUF-QUAL-OK      the real DMA-BUF qualification passed
#   VM-DMABUF-QUAL-SKIPPED the qualification was explicitly disabled
#   VM-DMABUF-QUAL-FAILED  the qualification ran and failed
#   VM-HOTPLUG-OK          the connector off/on and input-device removal
#                          qualification passed
#   VM-HOTPLUG-FAILED      it was requested and did not pass (or the
#                          hardware path it needs is not there)
#   VM-DRM-E2E-FAILED      something failed
#
# Mode is chosen on the kernel cmdline (the runner sets it, and a cmdline
# is reliable where a 9p file check is not):
#   wlvm.renderer=pixman|gles2   which renderer the server composites with
#   wlvm.dmabuf=required|off     run the client's DMA-BUF qualification
#   wlvm.graphics=vga|virgl      which guest GPU the run is on (logged, so
#                                a software run is never read as GPU proof)
#   wlvm.hotplug=on|off          run the connector off/on and input-device
#                                removal qualification (needs --outputs 2)
set -uo pipefail
exec > /dev/console 2>&1

# Interactive mode: launched with QEMU_KERNEL_PARAMS="demo.interactive"
# (kernel cmdline — reliable, unlike 9p file checks, which cache=loose
# serves stale). Skips the auto E2E and starts the interactive demo.
if grep -q demo.interactive /proc/cmdline; then
    echo "=== auto E2E skipped (demo.interactive on the cmdline); starting interactive demo ==="
    systemctl start compositor-demo-interactive
    poweroff -f
    exit 0
fi
RENDERER=pixman
DMA_BUF_MODE=off
GRAPHICS=${WLVM_GRAPHICS:-unknown}
EXPECTED_OUTPUTS=1
HOTPLUG_MODE=off

# What the runner asked for. The values below are the defaults the
# previous harness ran with; the cmdline overrides them.
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        wlvm.renderer=*) RENDERER=${arg#*=} ;;
        wlvm.dmabuf=*) DMA_BUF_MODE=${arg#*=} ;;
        wlvm.graphics=*) GRAPHICS=${arg#*=} ;;
        wlvm.outputs=*) EXPECTED_OUTPUTS=${arg#*=} ;;
        wlvm.hotplug=*) HOTPLUG_MODE=${arg#*=} ;;
    esac
done

echo "=== vm-drm-e2e: renderer=$RENDERER dmabuf=$DMA_BUF_MODE graphics=$GRAPHICS outputs=$EXPECTED_OUTPUTS ==="
# The GPU claim is part of the verdict: a run on a software renderer or a
# KMS-only device is a software proof, and says so here as well.
if [ "$GRAPHICS" = "virgl" ] && [ "$RENDERER" = "gles2" ]; then
    echo "=== profile: virtio-gpu-gl-pci (virgl): a GPU DMA-BUF/GLES2 proof ==="
else
    echo "=== profile: NOT a GPU proof (graphics=$GRAPHICS renderer=$RENDERER) ==="
fi
echo "=== vm-drm-e2e: hotplug=$HOTPLUG_MODE (connector off/on + input device removal) ==="
if [ "$HOTPLUG_MODE" = "on" ] && [ "$EXPECTED_OUTPUTS" -lt 2 ]; then
    echo "VM-HOTPLUG-FAILED: hotplug needs at least 2 scanouts (one to remove, one to survive), the cmdline asks for $EXPECTED_OUTPUTS"
    poweroff -f
    exit 1
fi

# The mailbox. The client and this script share one (tmpfs, both in the
# guest); this script and the host share the other (9p, so the host can
# drive the guest's PCI devices over QMP). Both are phase files: `<phase>.done`
# is written by whoever finished its half, `<phase>.go` releases the other.
PHASE_DIR=/tmp/wlvm-phase
PHASE_MOUNT=/tmp/xchg
PHASE_SHARE=$PHASE_MOUNT/wlvm-phase

# Bound on every wait, so a run can never hang on a phase that will not
# come. Generous: a modeset, a udev event and a device_add are not instant.
PHASE_WAIT=${WLVM_PHASE_WAIT:-300}

# This script's half: wait for the client to finish its half of a phase.
await_client() {
    local phase=$1 waited=0
    while [ "$waited" -lt "$PHASE_WAIT" ]; do
        if [ -e "$PHASE_DIR/$phase.done" ]; then
            echo "=== hotplug: client finished phase $phase (after ${waited}s) ==="
            publish_phase "$phase"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "VM-HOTPLUG-FAILED: the client never finished phase $phase within ${PHASE_WAIT}s"
    return 1
}

# The host's half: wait for the answer the host driver leaves in the share.
# The xchg mount is remounted with cache=none first, so this never reads a
# cached "not there" for a file the host has just created.
await_go() {
    local phase=$1 waited=0
    while [ "$waited" -lt "$PHASE_WAIT" ]; do
        if [ -e "$PHASE_SHARE/$phase.go" ]; then
            echo "=== hotplug: host released phase $phase (after ${waited}s) ==="
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "VM-HOTPLUG-FAILED: the host never released phase $phase within ${PHASE_WAIT}s"
    return 1
}

# Guest -> host. sync(1) forces the write out of this guest's page cache
# to the 9p server, so the host polling the share sees it now rather than
# at the next writeback.
publish_phase() {
    mkdir -p "$PHASE_SHARE" 2>/dev/null
    : > "$PHASE_SHARE/$1.done" 2>/dev/null || {
        echo "VM-HOTPLUG-FAILED: cannot write the phase marker for $1 into $PHASE_SHARE"
        return 1
    }
    sync
}

# Hand a phase to the client. The client reads its mailbox on tmpfs, so a
# connector answer has to land in BOTH places: the share copy is what the
# host sees, the tmpfs copy is what the client is blocked on.
release_go() {
    : > "$PHASE_SHARE/$1.go" || return 1
    sync
    : > "$PHASE_DIR/$1.go" || return 1
}

# The DRM connector debugfs tree. One `force` file per connector, under
# /sys/kernel/debug/dri/<primary minor>/<connector name>/. Writing "off"
# makes the generic DRM probe report that connector disconnected, which is
# exactly the state a yanked cable produces and exactly what the
# compositor's connectorStillUsable asks KMS about.
#
# QEMU's virtio-gpu has no runtime per-connector switch: its only
# connector properties (max_outputs, outputs) are read at realize time, and
# QEMU exposes no scanout QMP command. This is the supported guest-side
# way to take one connector away, and it drives the compositor's real
# udev hotplug path rather than a synthesised one.
connector_forces() {
    local f
    for f in /sys/kernel/debug/dri/*/*/force; do
        [ -w "$f" ] && printf '%s\n' "$f"
    done
}

ensure_debugfs() {
    if [ -d /sys/kernel/debug/dri ]; then
        return 0
    fi
    command -v mount >/dev/null 2>&1 || {
        echo "VM-HOTPLUG-FAILED: /sys/kernel/debug is not mounted and there is no mount(8) to mount it"
        return 1
    }
    mkdir -p /sys/kernel/debug || return 1
    mount -t debugfs debugfs /sys/kernel/debug || {
        echo "VM-HOTPLUG-FAILED: cannot mount debugfs (the kernel has no CONFIG_DEBUG_FS, so the connector force interface is absent)"
        return 1
    }
    [ -d /sys/kernel/debug/dri ]
}

# Raise a real uevent for one connector, so the compositor's udev monitor
# wakes up and reconciles. Writing the connector's own uevent file is the
# most targeted way; udevadm is the fallback.
raise_connector_change() {
    local connector=$1 sysdir=/sys/class/drm/$1
    if [ -w "$sysdir/uevent" ] && printf 'change\n' > "$sysdir/uevent" 2>/dev/null; then
        echo "=== hotplug: change uevent written to $sysdir/uevent ==="
        return 0
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm trigger --subsystem-match=drm --action=change \
            && { echo "=== hotplug: udevadm triggered a drm change ==="; return 0; }
    fi
    echo "VM-HOTPLUG-FAILED: no way to raise a uevent for connector $connector"
    return 1
}

set_connector_force() {
    local force_file=$1 value=$2
    if ! printf '%s\n' "$value" > "$force_file" 2>/dev/null; then
        echo "VM-HOTPLUG-FAILED: cannot write '$value' to $force_file"
        return 1
    fi
    echo "=== hotplug: $force_file = $(cat "$force_file" 2>/dev/null) ==="
}

# The guest half of the qualification. Runs while the client waits on the
# mailbox: this script raises the connector transitions, the host driver
# (scripts/vm-qualify.sh) raises the PCI input-device transitions.
run_hotplug_guest_half() {
    local force_file victim
    command -v mount >/dev/null 2>&1 \
        && mount -o remount,cache=none "$PHASE_MOUNT" 2>/dev/null \
        || echo "=== hotplug: WARNING: $PHASE_MOUNT remount with cache=none failed; the host mailbox may be read stale ==="
    mkdir -p "$PHASE_DIR" "$PHASE_SHARE" || {
        echo "VM-HOTPLUG-FAILED: cannot create the phase mailbox"
        return 1
    }

    # The host driver proves it can reach QEMU before anything moves.
    publish_phase start || return 1
    await_go start || return 1

    ensure_debugfs || return 1
    force_file=$(connector_forces | sort | tail -1)
    [ -n "$force_file" ] || {
        echo "VM-HOTPLUG-FAILED: no writable DRM connector force file under /sys/kernel/debug/dri"
        return 1
    }
    victim=$(basename "$(dirname "$force_file")")
    echo "=== hotplug: connectors ==="
    connector_forces | sed 's/^/  /'
    echo "=== hotplug: taking connector $victim off, leaving the rest alone ==="

    # The client has captured and fingerprinted every output: take one
    # connector off and let the compositor discover it.
    await_client connector-off || return 1
    set_connector_force "$force_file" off || return 1
    raise_connector_change "$victim" || return 1
    release_go connector-off || return 1

    # The client has seen the removal and proved the survivor is untouched.
    await_client connector-on || return 1
    set_connector_force "$force_file" unspecified || return 1
    raise_connector_change "$victim" || return 1
    release_go connector-on || return 1

    # Everything left is a QMP transition on the host: the guest only hands
    # over each marker and waits for the answer.
    local phase
    for phase in key-press keyboard-del keyboard-add mouse-del mouse-add; do
        await_client "$phase" || return 1
        await_go "$phase" || return 1
    done
    echo "=== hotplug: guest half done ==="
}

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
# The drm + libinput + GLES2 backends compile unconditionally, so no extra
# -D options are needed (the guest has no raylib).
# Forced clean build: no stale artifacts from any cache (the 9p view
# was stale across boots despite the remount; start from zero each time).
rm -rf /tmp/zo /tmp/zc /tmp/zgc
# The systemd service has no HOME: zig's translate-c subprocess cannot
# resolve its cache dir (AppDataDirUnavailable). Give it one.
export HOME=/root
export XDG_CACHE_HOME=/tmp/zig-xdg
# The EGL/GLES2 probe and the GBM include/lib resolution need the guest's
# libglvnd + mesa (installed by scripts/vm.nix); PKG_CONFIG_PATH comes
# from the unit's Environment.
echo "=== egl/glesv2/gbm configure probe ==="
pkg-config --exists egl && echo "egl.pc ok" || echo "egl.pc MISSING"
pkg-config --exists glesv2 && echo "glesv2.pc ok" || echo "glesv2.pc MISSING"
pkg-config --cflags egl glesv2 || echo "pkg-config --cflags egl glesv2 FAILED"
zig build --prefix /tmp/zo --cache-dir /tmp/zc --global-cache-dir /tmp/zgc \
    -Denable_raylib=false > /tmp/build.log 2>&1
BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ] || [ ! -x /tmp/zo/bin/wayland-server ] || [ ! -x /tmp/zo/bin/wayland-client ]; then
    echo "=== build failed (rc=$BUILD_RC); log tail: ==="
    tail -40 /tmp/build.log
    echo "VM-DRM-E2E-FAILED: build did not produce binaries"
    [ "$DMA_BUF_MODE" = "required" ] && echo "VM-DMABUF-QUAL-FAILED: no binaries to qualify"
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
    [ "$DMA_BUF_MODE" = "required" ] && echo "VM-DMABUF-QUAL-FAILED: stale binary, qualification not run"
    poweroff -f
    exit 1
fi
# The qualification mode needs the client's GBM-backed dmabuf path in
# the binary. Its env var name is unique to that code, so a binary built
# from older sources fails here instead of "passing" a mode it cannot run.
if [ "$DMA_BUF_MODE" = "required" ]; then
    QUAL_WIRED=$(grep -a -c "WAYLAND_CLIENT_DMABUF" /tmp/zo/bin/wayland-client || true)
    echo "=== client dmabuf-qualification wiring present: $QUAL_WIRED refs ==="
    if [ "$QUAL_WIRED" -eq 0 ]; then
        echo "VM-DMABUF-QUAL-FAILED: the client has no dmabuf qualification (WAYLAND_CLIENT_DMABUF absent)"
        echo "VM-DRM-E2E-FAILED: dmabuf qualification requested but not built in"
        poweroff -f
        exit 1
    fi
fi
# DRM init failures are diagnosed in the failure branch below (kernel
# log, server log, client log).
echo "=== vm-drm-e2e: build ok, running DRM E2E ==="

mkdir -p /tmp/rt
# Server log (stderr) goes to /tmp/srv.out so the drm:/libinput: lines are
# greppable. WAYLAND_LOG=err would hide info-level lines; keep the rest of
# the log quiet but let the drm + libinput tags through.
# The server stops itself after WAYLAND_RUN_FRAMES, so its lifetime is
# bounded no matter what; the client is bounded by its own waits and by
# the wrapper's timeout on top. The budget is per output, and the
# hotplug phase holds the compositor alive across several real device
# transitions, so it asks for a frame budget that cannot expire halfway
# through one (every wait in the phase is separately bounded).
if [ "$HOTPLUG_MODE" = "on" ]; then
    RUN_FRAMES=$((EXPECTED_OUTPUTS * 12000))
else
    RUN_FRAMES=2400
fi
echo "=== vm-drm-e2e: server frame budget $RUN_FRAMES (${EXPECTED_OUTPUTS} output(s)) ==="
XDG_RUNTIME_DIR=/tmp/rt WAYLAND_BACKEND=drm WAYLAND_LIBINPUT=1 \
    WAYLAND_SYNTH_INPUT=1 \
    WAYLAND_CAMERA="cx=640,cy=360,zoom=2" WAYLAND_RENDERER="$RENDERER" \
    WAYLAND_LOG=err,server=debug,surface=debug,xdg=debug,shm=debug,drm=info,libinput=info,gles2=info WAYLAND_RUN_FRAMES="$RUN_FRAMES" \
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
    echo "=== server log: ==="
    cat /tmp/srv.out 2>/dev/null
    [ "$DMA_BUF_MODE" = "required" ] && echo "VM-DMABUF-QUAL-FAILED: no server to qualify"
    poweroff -f
    exit 1
fi

CLIENT_DMABUF=0
[ "$DMA_BUF_MODE" = "required" ] && CLIENT_DMABUF=1
CLIENT_HOTPLUG=0
[ "$HOTPLUG_MODE" = "on" ] && CLIENT_HOTPLUG=1
rm -rf "$PHASE_DIR" "$PHASE_SHARE"
# The client runs in the BACKGROUND: the connector transitions have to
# happen WHILE it waits on the mailbox, so the script cannot block on it.
XDG_RUNTIME_DIR=/tmp/rt WAYLAND_DISPLAY="$SOCK" WAYLAND_CAMERA="cx=640,cy=360,zoom=2" \
    WAYLAND_CLIENT_DMABUF="$CLIENT_DMABUF" WAYLAND_CLIENT_HOTPLUG="$CLIENT_HOTPLUG" \
    /tmp/zo/bin/wayland-client > /tmp/cli.out 2>&1 &
CLI=$!
HOTPLUG_RUN=skipped
if [ "$HOTPLUG_MODE" = "on" ]; then
    echo "=== vm-drm-e2e: driving the connector off/on, the host driver the input devices ==="
    if run_hotplug_guest_half; then
        HOTPLUG_RUN=ran
    else
        HOTPLUG_RUN=failed
        # The client is waiting for a phase that will never come: stop it
        # here rather than letting it sit out its own timeout, and let the
        # verdict below report which transition was missing.
        kill "$CLI" 2>/dev/null
    fi
fi
wait "$CLI"
RC=$?
# The server stops itself after WAYLAND_RUN_FRAMES; wait briefly, then kill.
for _ in $(seq 1 40); do
    kill -0 "$SRV" 2>/dev/null || break
    sleep 0.5
done
kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

DRM_LINES=$(grep -c "drm: modeset ok" /tmp/srv.out 2>/dev/null || true)
# One successful initial modeset per requested scanout on the same card.
echo "=== vm-drm-e2e: outputs live=$DRM_LINES requested=$EXPECTED_OUTPUTS ==="
# The startup logs (drm:/libinput:) live at the HEAD of the log; the tail
# is dominated by teardown noise. Show both when the E2E failed.
if [ "$RC" -ne 0 ] || [ "$DRM_LINES" -lt "$EXPECTED_OUTPUTS" ]; then
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
# Whether the compositor could import a client dma-buf at all, straight
# from the backend's own words.
if grep -q "format/modifier pairs" /tmp/srv.out; then
    GBM_LINE=$(grep -m1 "format/modifier pairs" /tmp/srv.out)
    echo "=== guest dmabuf import device: $GBM_LINE ==="
else
    GBM_LINE=$(grep -m1 "dmabuf import disabled" /tmp/srv.out || echo "no GBM decision line in the server log")
    echo "=== guest dmabuf import device: $GBM_LINE ==="
fi
echo "=== vm-drm-e2e: client rc=$RC drm_lines=$DRM_LINES libinput_lines=$LIBINPUT_LINES ==="
echo "=== leak check: $LEAKS (expect 0; DebugAllocator at server exit) ==="

# --- the connector / input-device qualification verdict ---------------------
# Every CLIENT-HOTPLUG-* line the client prints is required, plus the
# guest-half marker. A run that skipped a step prints fewer lines, which
# is a failure here, not a pass. The transition itself was a real guest
# connector force with a real uevent (see run_hotplug_guest_half) and a
# real PCI hot-unplug on the host; nothing above reports a removal the
# compositor did not actually reconcile.
HOTPLUG_STATUS=0
if [ "$HOTPLUG_MODE" = "on" ]; then
    echo "=== vm-drm-e2e: connector force + hotplug client markers ==="
    grep "CLIENT-HOTPLUG" /tmp/cli.out 2>/dev/null || echo "=== (the client printed no hotplug line at all) ==="
    HOTPLUG_MISSING=""
    for marker in CLIENT-HOTPLUG-BASELINE CLIENT-HOTPLUG-REMOVE \
                  CLIENT-HOTPLUG-SURVIVOR CLIENT-HOTPLUG-READD \
                  CLIENT-HOTPLUG-KEY CLIENT-HOTPLUG-KEYBOARD-GONE \
                  CLIENT-HOTPLUG-KEYBOARD-BACK CLIENT-HOTPLUG-POINTER-GONE \
                  CLIENT-HOTPLUG-POINTER-BACK CLIENT-HOTPLUG-OK; do
        grep -q "$marker" /tmp/cli.out || HOTPLUG_MISSING="$HOTPLUG_MISSING $marker"
    done
    if grep -q "CLIENT-HOTPLUG-ERROR" /tmp/cli.out; then
        echo "VM-HOTPLUG-FAILED: the client reported a hotplug failure"
        HOTPLUG_STATUS=1
    elif [ "$HOTPLUG_RUN" != "ran" ]; then
        echo "VM-HOTPLUG-FAILED: the guest half of the qualification did not finish ($HOTPLUG_RUN)"
        HOTPLUG_STATUS=1
    elif [ -n "$HOTPLUG_MISSING" ]; then
        echo "VM-HOTPLUG-FAILED: missing client verdict lines:$HOTPLUG_MISSING"
        HOTPLUG_STATUS=1
    elif [ "$RC" -ne 0 ]; then
        echo "VM-HOTPLUG-FAILED: client rc=$RC after the hotplug markers"
        HOTPLUG_STATUS=1
    else
        echo "VM-HOTPLUG-OK"
    fi
else
    echo "VM-HOTPLUG-SKIPPED: wlvm.hotplug not set to on on the kernel cmdline"
fi

# --- the DMA-BUF qualification verdict -------------------------------------
# Every CLIENT-DMABUF-* line the client prints is required. A run that
# skipped a step prints fewer lines, which is a failure here, not a pass.
QUAL_STATUS=0
if [ "$DMA_BUF_MODE" = "required" ]; then
    MISSING=""
    for marker in CLIENT-DMABUF-IMPORT CLIENT-DMABUF-CAPTURE CLIENT-DMABUF-PIXELS \
                  CLIENT-DMABUF-DETACH CLIENT-DMABUF-REUSE CLIENT-DMABUF-RESTORE CLIENT-DMABUF-OK; do
        grep -q "$marker" /tmp/cli.out || MISSING="$MISSING $marker"
    done
    if grep -q "CLIENT-DMABUF-ERROR" /tmp/cli.out; then
        echo "=== client dmabuf verdict lines: ==="
        grep "CLIENT-DMABUF" /tmp/cli.out
        echo "VM-DMABUF-QUAL-FAILED: the client reported a dmabuf failure"
        QUAL_STATUS=1
    elif [ -n "$MISSING" ]; then
        echo "VM-DMABUF-QUAL-FAILED: missing client verdict lines:$MISSING"
        QUAL_STATUS=1
    elif [ "$RC" -ne 0 ]; then
        echo "VM-DMABUF-QUAL-FAILED: client rc=$RC after the qualification markers"
        QUAL_STATUS=1
    else
        echo "VM-DMABUF-QUAL-OK"
    fi
else
    echo "VM-DMABUF-QUAL-SKIPPED: wlvm.dmabuf not set to required on the kernel cmdline"
fi
STATUS=0
if [ "$RC" -eq 0 ] && grep -q "CLIENT-OK" /tmp/cli.out &&
   [ "$DRM_LINES" -ge "$EXPECTED_OUTPUTS" ] && [ "$LIBINPUT_LINES" -gt 0 ] && [ "$LEAKS" -eq 0 ]; then
    echo "VM-DRM-E2E-OK"
    # A required qualification is part of the verdict, not a footnote.
    [ "$QUAL_STATUS" -ne 0 ] && STATUS=1
    # A requested qualification that did not pass is a failure of the run,
    # not a footnote beside a pass.
    [ "$HOTPLUG_MODE" = "on" ] && [ "$HOTPLUG_STATUS" -ne 0 ] && STATUS=1
else
    echo "=== kernel log (virtio-gpu/kms): ==="
    journalctl -k --no-pager 2>/dev/null | grep -iE "virtio|drm|atomic|kms" | tail -40
    echo "=== server log tail: ==="
    tail -40 /tmp/srv.out
    echo "=== client log tail: ==="
    tail -40 /tmp/cli.out
    echo "VM-DRM-E2E-FAILED"
    STATUS=1
fi
poweroff -f
exit "$STATUS"