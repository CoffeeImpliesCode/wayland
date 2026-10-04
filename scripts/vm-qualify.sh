#!/usr/bin/env bash
# Host-side DRM qualification runner.
#
# Builds the guest VM from scripts/vm.nix and runs the in-guest DRM E2E
# (scripts/vm-drm-e2e.sh) headlessly, then decides the verdict from the
# marker lines the guest printed. No /tmp/wl-vm flake, no host flake: the
# nixpkgs the VM is built from is the one devenv.lock pins, so the guest
# and the host dev shell are the same package set.
#
# What this run does NOT do, by design:
#   - it never switches the host VT, never touches the host's session and
#     never suspends anything. Those are physical-host checks and need a
#     human at the machine (see "NOT COVERED" in the report below).
#   - it opens no window. The guest uses a serial console and the
#     host's desktop is untouched.
#   - it never reports a pass it did not see: the verdict comes from the
#     guest's marker lines in the captured console, and a run that
#     produced no marker is a failure.
#   - it never touches a HOST device. --hotplug plugs and unplugs the
#     GUEST's virtio input devices over QEMU's control socket, and the
#     guest takes one of its OWN DRM connectors off through the kernel's
#     connector force interface plus a real uevent. The host's cards,
#     connectors and input stack are only ever read.
#   - a guest run is a virtual-GPU proof, never a physical-GPU one. The
#     virgl profile uses host EGL/virglrenderer. The report distinguishes
#     bound host drivers from the unverified renderer selected by QEMU.
#     No host DRM master, VT, suspend, or device removal is requested.
#
# Artifacts (console log, build link, the QMP socket and the phase
# mailbox) are owned by this script and land under zig-out/qualification/
# unless WLVM_ARTIFACTS says otherwise. The guest writes only to its own
# /tmp and to the phase mailbox; the shared repo is never written to.
#
# Usage (from the repo root):
#   scripts/vm-qualify.sh                       # KMS-only profile, no dmabuf gate
#   scripts/vm-qualify.sh --profile virgl       # virtio-gpu-gl-pci (GPU) profile
#   scripts/vm-qualify.sh --profile virgl --outputs 2 --dmabuf required
#   scripts/vm-qualify.sh --outputs 2 --hotplug on
#   scripts/vm-qualify.sh --dmabuf required --renderer gles2
#   scripts/vm-qualify.sh --no-build            # reuse the last VM build
set -uo pipefail

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

  --hotplug on|off    run the connector off/on and input-device removal
                      qualification (default: off). "on" needs --outputs 2
                      (one connector goes away, one has to survive) and a
                      python3 on this host to speak QMP; it gives the VM a
                      control socket and is part of the verdict, never
                      silently skipped.
  --timeout SEC         hard wall clock for the VM (default 1800).
  --artifacts DIR       where to put the console log and the VM link
                        (default: <repo>/zig-out/qualification).
  --no-build            reuse an existing VM build in the artifact dir.
                        Incompatible with --hotplug on: a cached image was
                        built without the QMP socket the driver needs.
  --allow-tcg           run without /dev/kvm (slow; reported as such).
  -h, --help            this text.
EOF
}

# The host half of the --hotplug qualification. QEMU's control socket is
# on the host, so the guest cannot reach it: the two halves talk through a
# phase mailbox in the run's 9p share (the guest's /tmp/xchg). Each phase
# is one device operation the guest cannot do itself.
run_host_hotplug_driver() {
    python3 - "$QMP_SOCK" "$RUN_DIR/xchg/wlvm-phase" <<'PYEOF' || return 1
import json, os, socket, sys, time

SOCK, SHARE = sys.argv[1], sys.argv[2]
WAIT = 300.0
# PCI hot-unplug uses these qdev ids. Input events use DISPLAY instead:
# QMP's input device argument names a QemuConsole, not an input qdev.
KBD = ("virtio-keyboard-pci", "wlvm-kbd")
MOUSE = ("virtio-mouse-pci", "wlvm-mouse")
# QMP qcodes avoid confusing enum ordinals with PC scancodes.
# These produce the client's watched evdev codes 38 and 56, not synth A.
KEY_BEFORE, KEY_AFTER = "l", "alt"
DISPLAY = "wlvm-gpu"
# A guest needs a moment to enumerate a replugged PCI device, bind the
# driver and hand it to libinput; without it the events land on nothing.
SETTLE = 4.0


def log(message):
    print("=== host-hotplug: " + message, flush=True)


class Qmp:
    def __init__(self, path):
        # The launcher may still be creating the guest disk. Wait for QMP
        # to listen, rather than racing its Unix socket into ENOENT.
        deadline = time.monotonic() + 30.0
        while True:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(30.0)
            try:
                self.sock.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.sock.close()
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        self.stream = self.sock.makefile("rwb")
        self.events = []
        self.read()                      # the greeting
        self.call("qmp_capabilities")

    def receive(self):
        line = self.stream.readline()
        if not line:
            raise RuntimeError("QMP closed the connection")
        return json.loads(line.decode())

    def read(self):
        while True:
            message = self.receive()
            if "event" in message:
                self.events.append(message)
                continue
            return message

    def wait_deleted(self, device):
        deadline = time.monotonic() + WAIT
        while True:
            for index, message in enumerate(self.events):
                data = message.get("data", {})
                if data.get("device") != device and data.get("path") != "/machine/peripheral/" + device:
                    continue
                if message["event"] == "DEVICE_UNPLUG_GUEST_ERROR":
                    raise RuntimeError("guest refused removal of " + device)
                if message["event"] == "DEVICE_DELETED":
                    self.events.pop(index)
                    return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("no DEVICE_DELETED for " + device)
            self.sock.settimeout(remaining)
            message = self.receive()
            if "event" not in message:
                raise RuntimeError("unexpected QMP reply while waiting for device removal")
            self.events.append(message)

    def call(self, execute, arguments=None):
        request = {"execute": execute}
        if arguments is not None:
            request["arguments"] = arguments
        self.stream.write((json.dumps(request) + "\n").encode())
        self.stream.flush()
        reply = self.read()
        if "error" in reply:
            error = reply["error"]
            raise RuntimeError(
                "%s: %s" % (execute, error.get("desc") or error.get("class") or error))
        return reply.get("return")


def wait_done(phase):
    path = os.path.join(SHARE, phase + ".done")
    deadline = time.time() + WAIT
    while time.time() < deadline:
        if os.path.exists(path):
            log("the guest finished " + phase)
            return True
        time.sleep(0.2)
    return False


def release(phase):
    # The guest reads this through the 9p share it remounts cache=none, so
    # a plain write from the host side is enough.
    with open(os.path.join(SHARE, phase + ".go"), "w"):
        pass


def tap_key(qmp, qcode):
    qmp.call("input-send-event", {
        "device": DISPLAY,
        "head": 0,
        "events": [
            {"type": "key",
             "data": {"down": True, "key": {"type": "qcode", "data": qcode}}},
            {"type": "key",
             "data": {"down": False, "key": {"type": "qcode", "data": qcode}}},
        ],
    })


def plug(qmp, spec):
    qmp.call("device_add", {"driver": spec[0], "id": spec[1], "display": DISPLAY, "head": 0})
    log("plugged " + spec[0] + " as " + spec[1])
    time.sleep(SETTLE)


def unplug(qmp, spec):
    qmp.call("device_del", {"id": spec[1]})
    qmp.wait_deleted(spec[1])
    log("DEVICE_DELETED confirmed for " + spec[1])


def present(qmp):
    ids = set()
    listed = []
    for bus in qmp.call("query-pci") or []:
        for device in bus.get("devices", []):
            qdev_id = device.get("qdev_id")
            if qdev_id:
                ids.add(qdev_id)
                listed.append("%s (bus %s slot %s function %s)" % (
                    qdev_id, bus.get("bus"), device.get("slot"),
                    device.get("function")))
    log("named PCI devices: " + (", ".join(sorted(listed)) if listed else "NONE"))
    for spec in (KBD, MOUSE):
        if spec[1] not in ids:
            raise RuntimeError(
                "the guest's %s has no qdev id, so it cannot be unplugged "
                "by name; scripts/vm.nix must give it one" % spec[0])


def keyboard_gone(qmp):
    unplug(qmp, KBD)
    # QMP input targets a display, not a PCI input device. A fallback
    # handler can accept this; the client proves capability withdrawal.
    tap_key(qmp, KEY_BEFORE)
    log("injected a key after removal; the client checks the seat")


def keyboard_back(qmp):
    plug(qmp, KBD)
    tap_key(qmp, KEY_AFTER)
    log("injected left Alt into the replugged keyboard")


def mouse_gone(qmp):
    unplug(qmp, MOUSE)
    qmp.call("input-send-event", {
        "device": DISPLAY,
        "head": 0,
        "events": [{"type": "rel", "data": {"axis": "x", "value": 5}}],
    })
    log("injected relative motion after removal; the client checks silence")


def mouse_back(qmp):
    plug(qmp, MOUSE)
    qmp.call("input-send-event", {
        "device": DISPLAY,
        "head": 0,
        "events": [
            {"type": "rel", "data": {"axis": "x", "value": 40}},
            {"type": "rel", "data": {"axis": "y", "value": 30}},
        ],
    })
    log("injected relative motion into the replugged pointer")


def main():
    qmp = Qmp(SOCK)
    log("QMP connected to " + SOCK)
    phases = [
        ("start", lambda: present(qmp)),
        ("key-press", lambda: tap_key(qmp, KEY_BEFORE)),
        ("keyboard-del", lambda: keyboard_gone(qmp)),
        ("keyboard-add", lambda: keyboard_back(qmp)),
        ("mouse-del", lambda: mouse_gone(qmp)),
        ("mouse-add", lambda: mouse_back(qmp)),
    ]
    for name, action in phases:
        if not wait_done(name):
            log("the guest never finished " + name)
            return 1
        try:
            action()
        except Exception as exc:            # noqa: BLE001 - reported, not hidden
            log(name + " failed: " + str(exc))
            return 1
        release(name)
    log("every guest input-device transition ran")
    return 0


sys.exit(main())
PYEOF
}

die() {
    echo "vm-qualify: $*" >&2
    exit 2
}

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || die "cannot locate the repo root"
ARTIFACTS=${WLVM_ARTIFACTS:-$REPO_ROOT/zig-out/qualification}
PROFILE=vga
OUTPUTS=1
DMA_BUF=off
RENDERER=""
TIMEOUT=1800
DO_BUILD=1
HOTPLUG=off
RUN_DIR=""
QMP_SOCK=""
QMP_SOCK_NIX=null
ALLOW_TCG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=${2:?--profile needs a value}; shift 2 ;;
        --outputs) OUTPUTS=${2:?--outputs needs a value}; shift 2 ;;
        --dmabuf) DMA_BUF=${2:?--dmabuf needs a value}; shift 2 ;;
        --renderer) RENDERER=${2:?--renderer needs a value}; shift 2 ;;
        --timeout) TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
        --artifacts) ARTIFACTS=${2:?--artifacts needs a value}; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --hotplug) HOTPLUG=${2:?--hotplug needs a value}; shift 2 ;;
        --allow-tcg) ALLOW_TCG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

case "$PROFILE" in
    vga|virgl) ;;
    *) die "--profile must be vga or virgl (got '$PROFILE')" ;;
esac
case "$DMA_BUF" in
    required|off) ;;
    *) die "--dmabuf must be required or off (got '$DMA_BUF')" ;;
esac
case "$OUTPUTS" in
    ''|*[!0-9]*) die "--outputs must be an integer from 1 to 16 (got '$OUTPUTS')" ;;
esac
[ "$OUTPUTS" -ge 1 ] && [ "$OUTPUTS" -le 16 ] || die "--outputs must be between 1 and 16"
if [ -z "$RENDERER" ]; then
    if [ "$PROFILE" = "virgl" ]; then RENDERER=gles2; else RENDERER=pixman; fi
fi
case "$RENDERER" in
    pixman|gles2) ;;
    *) die "--renderer must be pixman or gles2 (got '$RENDERER')" ;;
esac
case "$TIMEOUT" in
    ''|*[!0-9]*) die "--timeout must be a number of seconds (got '$TIMEOUT')" ;;
esac
[ "$TIMEOUT" -ge 60 ] || die "--timeout must be at least 60s"

[ -f "$REPO_ROOT/scripts/vm.nix" ] || die "scripts/vm.nix is missing from $REPO_ROOT"
[ -f "$REPO_ROOT/scripts/vm-drm-e2e.sh" ] || die "scripts/vm-drm-e2e.sh is missing from $REPO_ROOT"
[ -f "$REPO_ROOT/devenv.lock" ] || die "devenv.lock is missing: the VM's nixpkgs comes from it"

mkdir -p "$ARTIFACTS" || die "cannot create the artifact directory $ARTIFACTS"
CONSOLE="$ARTIFACTS/console-$PROFILE.log"
VM_LINK="$ARTIFACTS/result"

# The QMP control socket and the phase mailbox, both under the artifact
# dir. The socket path is part of the VM BUILD (scripts/vm.nix bakes it
# into -qmp), so it has to be settled before the build, and a unix socket
# path is length limited: say so plainly rather than failing inside QEMU.
RUN_DIR="$ARTIFACTS/run-$PROFILE"
mkdir -p "$RUN_DIR" || die "cannot create the run directory $RUN_DIR"
QMP_SOCK="$RUN_DIR/qmp.sock"
HOTPLUG_NIX=false
if [ "$HOTPLUG" = "on" ]; then
    HOTPLUG_NIX=true
    QMP_SOCK_NIX="\"$QMP_SOCK\""
    if [ "${#QMP_SOCK}" -gt 100 ]; then
        die "--artifacts must give a short run directory: the QMP socket path $QMP_SOCK is ${#QMP_SOCK} bytes and a unix socket path cannot exceed 107"
    fi
fi

echo "=== bound host GPU driver (read only) ==="
# A sysfs driver binding does not identify QEMU's selected EGL device,
# vendor or hardware/software renderer. Report only what was observed.
HOST_GPU_DRIVER=UNKNOWN
for driver_link in /sys/class/drm/card*/device/driver; do
    [ -e "$driver_link" ] || continue
    resolved=$(readlink -f "$driver_link" 2>/dev/null) || continue
    HOST_GPU_DRIVER=$(basename "$resolved")
    break
done
if [ "$HOST_GPU_DRIVER" = "UNKNOWN" ]; then
    echo "  no bound DRM driver found under /sys/class/drm/card*/device/driver:"
    echo "  QEMU's actual host rendering substrate is UNKNOWN"
else
    echo "  bound driver: $HOST_GPU_DRIVER (sysfs only; not proof of QEMU's renderer)"
fi

case "$HOTPLUG" in
    on|off) ;;
    *) die "--hotplug must be on or off (got '$HOTPLUG')" ;;
esac
if [ "$HOTPLUG" = "on" ] && [ "$OUTPUTS" -lt 2 ]; then
    die "--hotplug on needs --outputs 2 or more: one connector goes away and one has to survive, and a single-output run has no survivor to compare it against"
fi
if [ "$HOTPLUG" = "on" ] && [ "$DO_BUILD" -eq 0 ]; then
    die "--hotplug on with --no-build: the cached VM was built without the QMP socket the driver needs. Rebuild once (drop --no-build)."
fi
if [ "$HOTPLUG" = "on" ] && ! command -v python3 >/dev/null 2>&1; then
    die "--hotplug on needs python3 on this host: QEMU's control socket speaks QMP (JSON over a unix socket) and there is no other standard client for it"
fi

command -v nix >/dev/null 2>&1 || die "nix is not on PATH (run this from the devenv shell, or with nix on PATH)"
command -v timeout >/dev/null 2>&1 || die "timeout(1) is required"
KVM_OK=0
[ -r /dev/kvm ] && [ -w /dev/kvm ] && KVM_OK=1
if [ "$KVM_OK" -eq 0 ] && [ "$ALLOW_TCG" -eq 0 ]; then
    die "/dev/kvm is not usable: a VM run would be emulated (TCG) and slow. Pass --allow-tcg if that is what you want."
fi

echo "=== host inventory (read only; nothing here is switched, suspended or unplugged) ==="
echo "kvm: /dev/kvm $([ "$KVM_OK" -eq 1 ] && echo usable || echo "MISSING (TCG emulation)")"
echo "dri nodes: $(ls /dev/dri 2>/dev/null | tr '\n' ' ' || echo "none")"
for node in /dev/dri/renderD* /dev/dri/card*; do
    [ -e "$node" ] || continue
    printf '  %s -> %s\n' "$node" "$(readlink -f "$node" 2>/dev/null)"
done
echo "sessions (loginctl, read only):"
loginctl list-sessions --no-legend 2>/dev/null | sed 's/^/  /' || echo "  (loginctl unavailable)"
echo "bound host GPU driver (not QEMU renderer evidence): $HOST_GPU_DRIVER"
echo "planned run:"
echo "  profile=$PROFILE outputs=$OUTPUTS renderer=$RENDERER dmabuf=$DMA_BUF hotplug=$HOTPLUG timeout=${TIMEOUT}s"
if [ "$PROFILE" = "virgl" ] && [ "$RENDERER" = "gles2" ]; then
    echo "  claim: VIRTUAL GPU proof inside the guest (virtio-gpu-gl-pci + virgl) - NOT a physical GPU proof"
else
    echo "  claim: NOT a GPU proof (software or KMS-only guest)"
fi
echo "  QEMU host EGL device/vendor/renderer: UNKNOWN until observed from this run"
if [ "$HOTPLUG" = "on" ]; then
    echo "  hotplug: one GUEST DRM connector forced off then on, with a real uevent;"
    echo "           the guest's virtio keyboard and mouse unplugged and replugged over QMP"
fi
echo "  artifacts: $ARTIFACTS"

if [ "$DO_BUILD" -eq 1 ]; then
    echo "=== building the guest VM from scripts/vm.nix (nixpkgs from devenv.lock) ==="
    LOCK_PATH="$REPO_ROOT/devenv.lock"
    NIX_EXPR=$(cat <<EOF
let
  lock = builtins.fromJSON (builtins.readFile "$LOCK_PATH");
  node = lock.nodes.nixpkgs-src.locked;
  src = builtins.fetchTarball {
    url = "https://github.com/\${node.owner}/nixpkgs/archive/\${node.rev}.tar.gz";
    sha256 = node.narHash;
  };
in (import (src + "/nixos/lib/eval-config.nix") {
  system = "x86_64-linux";
  specialArgs = { repoPath = "$REPO_ROOT"; };
  modules = [
    (builtins.toPath "$REPO_ROOT/scripts/vm.nix")
    ({ ... }: {
      wlvm.graphics = "$PROFILE";
      wlvm.outputCount = $OUTPUTS;
      wlvm.hotplug = $HOTPLUG_NIX;
      wlvm.qmpSocket = $QMP_SOCK_NIX;
    })
  ];
}).config.system.build.vm
EOF
)
    VM_PATH=$(nix build --impure --no-link --print-out-paths --expr "$NIX_EXPR" 2>"$ARTIFACTS/nix-build.log")
    BUILD_RC=$?
    if [ "$BUILD_RC" -ne 0 ] || [ -z "$VM_PATH" ]; then
        echo "vm-qualify: the VM build failed; tail of the nix log:" >&2
        tail -40 "$ARTIFACTS/nix-build.log" >&2
        exit 1
    fi
    ln -sfn "$VM_PATH" "$VM_LINK" || die "cannot link the VM into $VM_LINK"
    echo "  VM: $VM_PATH"
else
    [ -e "$VM_LINK" ] || die "--no-build given, but $VM_LINK does not exist"
    VM_PATH=$(readlink -f "$VM_LINK")
    echo "=== reusing the VM at $VM_PATH ==="
fi

RUN_SCRIPT=""
for candidate in "$VM_PATH"/bin/run-*-vm; do
    if [ -x "$candidate" ]; then
        RUN_SCRIPT=$candidate
        break
    fi
done
[ -n "$RUN_SCRIPT" ] || die "no run-*-vm script in $VM_PATH/bin"

echo "=== booting the guest (serial only, no window, ${TIMEOUT}s cap) ==="
# The kernel cmdline is how the guest learns the mode: reliable, unlike a
# 9p file check (cache=loose serves stale views).
#
# The VM runs in the BACKGROUND: with --hotplug the host driver has to
# talk to QEMU while the guest waits on its phase mailbox, so this script
# cannot block on QEMU. The console still lands in the same artifact file.
rm -f "$QMP_SOCK"
rm -rf "$RUN_DIR/xchg"
mkdir -p "$RUN_DIR/xchg/wlvm-phase"
TMPDIR="$RUN_DIR" USE_TMPDIR=1 \
NIX_DISK_IMAGE="$ARTIFACTS/disk-$PROFILE.qcow2" \
QEMU_KERNEL_PARAMS="wlvm.renderer=$RENDERER wlvm.dmabuf=$DMA_BUF wlvm.graphics=$PROFILE wlvm.outputs=$OUTPUTS wlvm.hotplug=$HOTPLUG" \
    timeout --foreground -k 30 "$TIMEOUT" "$RUN_SCRIPT" > "$CONSOLE" 2>&1 &
QEMU_PID=$!
HOST_DRIVER_STATUS=0
if [ "$HOTPLUG" = "on" ]; then
    echo "=== host driver: driving the guest's input devices over QMP at $QMP_SOCK ==="
    run_host_hotplug_driver || HOST_DRIVER_STATUS=$?
    [ "$HOST_DRIVER_STATUS" -ne 0 ] && echo "  host driver failed (status $HOST_DRIVER_STATUS)"
fi
wait "$QEMU_PID"
VM_RC=$?
echo "=== guest exited (status $VM_RC); console kept at $CONSOLE ==="

# --- the verdict ----------------------------------------------------------
E2E_OK=0
QUAL_OK=0
grep -qx "VM-DRM-E2E-OK" "$CONSOLE" && E2E_OK=1
grep -qx "VM-DMABUF-QUAL-OK" "$CONSOLE" && QUAL_OK=1
FAIL_LINE=$(grep -n -m1 -E "^VM-(DRM-E2E|DMABUF-QUAL|HOTPLUG)-FAILED" "$CONSOLE" || true)
HOTPLUG_OK=0
grep -qx "VM-HOTPLUG-OK" "$CONSOLE" && HOTPLUG_OK=1

STATUS=0
if [ "$E2E_OK" -eq 1 ] && { [ "$DMA_BUF" != "required" ] || [ "$QUAL_OK" -eq 1 ]; } &&
   { [ "$HOTPLUG" != "on" ] || [ "$HOTPLUG_OK" -eq 1 ]; }; then
    echo "QUALIFY-RESULT: PASS ($PROFILE/$RENDERER, dmabuf=$DMA_BUF, hotplug=$HOTPLUG)"
else
    STATUS=1
    echo "QUALIFY-RESULT: FAIL ($PROFILE/$RENDERER, dmabuf=$DMA_BUF, hotplug=$HOTPLUG)"
    if [ -n "$FAIL_LINE" ]; then
        echo "  first failure marker: ${FAIL_LINE}"
    elif [ "$VM_RC" -eq 124 ]; then
        echo "  the guest hit the ${TIMEOUT}s cap before printing a verdict"
    elif ! grep -q "^VM-DRM-E2E-OK" "$CONSOLE"; then
        echo "  the guest printed no VM-DRM-E2E-OK (build failure, crash or poweroff before the E2E)"
    fi
    if [ "$DMA_BUF" = "required" ] && [ "$QUAL_OK" -eq 0 ]; then
        echo "  the DMA-BUF qualification did not pass; see the CLIENT-DMABUF lines above"
    fi
    if [ "$HOTPLUG" = "on" ] && [ "$HOTPLUG_OK" -eq 0 ]; then
        echo "  the connector / input-device qualification did not pass"
        if [ "$HOST_DRIVER_STATUS" -ne 0 ]; then
            echo "  the host QMP driver failed (status $HOST_DRIVER_STATUS); see the host-hotplug lines above"
        fi
        grep -n -m1 "CLIENT-HOTPLUG-ERROR" "$CONSOLE" | sed 's/^/  client said: /'
        grep "^VM-HOTPLUG-FAILED" "$CONSOLE" | tail -3 | sed 's/^/  /'
    fi
    echo "  console: $CONSOLE"
    tail -30 "$CONSOLE" | sed 's/^/  | /'
fi

echo
echo "=== what this run does not prove ==="
cat <<'EOF'
  - A physical GPU. This is a guest. virtio-vga (profile vga) has no
    renderable GBM at all, and the virgl profile is a VIRTUAL GPU behind
    virtio whose GLES2 is executed by host EGL/virglrenderer. A bound host
    driver is not proof of the EGL device or hardware/software renderer
    QEMU selected. Nothing here says the host's physical card passed.
  - A physical connector. QEMU's virtio-gpu has no runtime per-connector
    switch - its connector properties (max_outputs, outputs) are read at
    realize time and QEMU exposes no scanout QMP command - so --hotplug
    takes a GUEST connector off through the kernel's DRM connector force
    interface and a real uevent. That drives the compositor's real udev
    hotplug, output-destruction and output-re-creation path. It is not a
    cable being pulled out of the host.
  - A physical input device. --hotplug unplugs the GUEST's virtio
    keyboard and mouse over QEMU's control socket. The devices it removes
    belong to the guest, and the host's own input stack is never touched.
  - Host-session behaviour, which this runner never touches:
      * VT switch / restore on a dedicated physical session
      * suspend / resume with fd stability across the sleep
      * a hotplug event on the host's own connectors
    These need a human at the machine and a second, dedicated seat; the
    host's live session is never switched or suspended by this harness.
  - Anything the guest could not reach: if the guest had no /dev/dri, no
    GBM device, no linux-dmabuf global, no connector force interface or no
    QMP socket, the run reports FAIL, never a pass.
EOF
exit "$STATUS"