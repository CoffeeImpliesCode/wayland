{ config, pkgs, lib, modulesPath, repoPath ? null, ... }:
let
  cfg = config.wlvm;

  # libglvnd ships egl.pc / glesv2.pc in its dev output; the pkg-config
  # path must point at whichever output carries them.
  glvnd = if (pkgs.libglvnd ? dev) then pkgs.libglvnd.dev else pkgs.libglvnd;

  # Everything the guest build resolves through pkg-config at configure
  # time. `zig build` runs `pkg-config --cflags <pc>` for libdrm and
  # pixman-1 and, NOT optionally, for egl and glesv2: the GLES2 renderer
  # is linked into the library, the server and the client, so a guest
  # without libglvnd's .pc files fails at configure time, not at run
  # time. libgbm has no entry here because nixpkgs ships no gbm.pc that
  # this search path would find; build.zig resolves its include and lib
  # dirs by scanning the store for mesa-libgbm (gbmDirs), so mesa-libgbm
  # only has to be in the closure.
  guestPkgConfigPackages = [
    pkgs.wayland.dev
    pkgs.wayland-protocols
    pkgs.libxkbcommon.dev
    pkgs.systemd.dev
    pkgs.libdrm.dev
    pkgs.libinput.dev
    pkgs.pixman
    glvnd
  ];
  guestPkgConfig =
    lib.makeSearchPath "lib/pkgconfig" guestPkgConfigPackages
    + ":" + lib.makeSearchPath "share/pkgconfig" guestPkgConfigPackages;

  # Mesa's loader configuration. Without these the guest libEGL cannot
  # find its vendor library or the DRI drivers, so the renderer never
  # reaches a driver (gles2.zig creates a surfaceless EGL display).
  mesaEnv = {
    LIBGL_DRIVERS_PATH = "${pkgs.mesa}/lib/dri";
    __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
    EGL_PLATFORM = "surfaceless";
    EGL_LOG_LEVEL = "error";
  } // (
    if cfg.graphics == "virgl" then {
      # The virgl profile: the guest GPU is a real virtio-gpu render node,
      # so GLES2 runs on it (virgl over virtio-gpu), not on llvmpipe.
      GALLIUM_DRIVER = "virgl";
      LIBGL_ALWAYS_SOFTWARE = "0";
    } else {
      # virtio-vga is KMS only: it has no renderable, so the only GL the
      # guest can have is llvmpipe. A run on this profile is NEVER GPU
      # proof, and the E2E says so in its verdict.
      GALLIUM_DRIVER = "llvmpipe";
      LIBGL_ALWAYS_SOFTWARE = "1";
    }
  );

  # max_outputs realizes connectors but enables only the first one.
  # QEMU 11's per-output resolution enables every requested connector.
  graphicsOptions = [
    "-vga"
    "none"
    "-device"
    (lib.escapeShellArg (builtins.toJSON {
      driver = if cfg.graphics == "virgl" then "virtio-gpu-gl-pci" else "virtio-vga";
      id = "wlvm-gpu";
      max_outputs = cfg.outputCount;
      outputs = lib.genList (i: {
        name = "wlvm-${toString (i + 1)}";
        xres = 1280;
        yres = 720;
      }) cfg.outputCount;
    }))
    "-display"
    (if cfg.graphics == "virgl" then "egl-headless" else "none")
    "-serial"
    "stdio"
    "-monitor"
    "none"
  ];

  # QMP, when the qualification asked for it: the host needs a control
  # channel to unplug a guest device, and a monitor socket is the
  # supported one. `-monitor none` (the baseline) is left alone.
  qmpOptions =
    if cfg.qmpSocket == null then
      []
    else
      [
        "-qmp"
        "unix:${cfg.qmpSocket},server=on,wait=off"
      ];

  # The whole E2E environment the compositor-demo-drm unit runs with.
  # environment.variables does not reliably reach systemd services, so
  # it is written out here instead.
  e2eEnvironment = {
    PKG_CONFIG_PATH = guestPkgConfig;
    WLVM_GRAPHICS = cfg.graphics;
  } // mesaEnv;

  # The qualification's mailbox, shared with scripts/vm-qualify.sh
  # through the 9p xchg mount. It has to exist before the E2E script runs,
  # because the client writes into it from the moment it starts; a unit
  # that could not create it must fail loudly instead of leaving the
  # harness waiting for a phase that can never arrive.
  phaseDir = {
    unit = "wlvm-phase-dir";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/mkdir -p /tmp/wlvm-phase";
    };
  };
in
{
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];
  # Guest VM for the compositor's DRM qualification.
  #
  # Build (scripts/vm-qualify.sh does this for you; there is no flake
  # requirement any more). nixpkgs comes from devenv.lock, so this is
  # the same package set the host dev shell uses:
  #   nix build --impure --expr 'let
  #     lock = builtins.fromJSON (builtins.readFile ./devenv.lock);
  #     rev = lock.nodes.nixpkgs-src.locked.rev;
  #     src = builtins.fetchTarball
  #       "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
  #   in (import (src + "/nixos/lib/eval-config.nix") {
  #     specialArgs = { repoPath = ~/projects/wayland; };
  #     modules = [ ./scripts/vm.nix ];
  #   }).config.system.build.vm'
  #   ./result/bin/run-wlvm-vm
  #
  # The VM shares the repo via 9p (/shared/repo) and builds it with the
  # guest toolchain. Two E2E modes run as boot-time oneshot services,
  # each printing its OK line before powering off:
  #   - compositor-demo-drm (boot default, wantedBy multi-user.target):
  #     DRM/KMS backend on the guest's GPU device (/dev/dri/card0) plus
  #     the libinput source on the virtio keyboard/mouse evdev devices
  #     (/dev/input/*; virtio-mouse is absolute). Prints
  #     VM-DRM-E2E-OK, plus VM-DMABUF-QUAL-OK when the DMA-BUF
  #     qualification ran.
  #   - compositor-demo (manual, `systemctl start compositor-demo`): the
  #     headless E2E (libinput-capable seat + virtual pixman framebuffer).
  #     Prints VM-E2E-OK.
  # The host desktop is never in the loop: no VT switch, no session
  # manipulation, no suspend.
  #
  # Options (scripts/vm-qualify.sh passes them; anything set through the
  # kernel cmdline wlvm.* overrides the E2E's own choice):
  #   graphics = "vga"   virtio-vga, KMS only, no DMA-BUF, no GPU GL
  #   graphics = "virgl" virtio-gpu-gl-pci, GPU GL + DMA-BUF import
  #   outputCount = 2   two scanouts on the same DRM card
  #   hotplug = true    the connector off/on and input-device removal
  #                     qualification: a QMP control socket, named input
  #                     devices the host can unplug, and no second
  #                     (id-less) keyboard on the seat.
  #   qmpSocket = path  the host socket scripts/vm-qualify.sh drives
  options.wlvm = {
    graphics = lib.mkOption {
      type = lib.types.enum [ "vga" "virgl" ];
      default = "vga";
      description = "Guest display device: vga = virtio-vga (KMS only, no renderable GBM); virgl = virtio-gpu-gl-pci (GPU: renderable GBM, dma-buf import, virgl GLES2).";
    };
    outputCount = lib.mkOption {
      type = lib.types.ints.between 1 16;
      default = 1;
      description = "Scanouts on the single guest DRM card, for per-output rendering and hotplug checks.";
    };
    hotplug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the device-removal qualification. It needs the input
        device set to be exactly the one this module declares: the
        qemu-vm module adds a `virtio-keyboard` with no qdev id, which
        cannot be hot-unplugged and would keep the keyboard capability
        alive after every keyboard was unplugged. Turning it off leaves
        the seat with the two named PCI devices below, so unplugging the
        keyboard really does withdraw the capability.
      '';
    };
    qmpSocket = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path of a QMP unix socket (`-qmp unix:<path>`). It is how
        scripts/vm-qualify.sh hot-unplugs the guest's input devices
        (device_del / device_add) and injects real input events
        (input-send-event). Null: no control socket at all, which is the
        baseline run and needs nothing else.
      '';
    };
  };

  config = {
    system.stateVersion = "26.11";
    # No host window: the explicit display backend is none or egl-headless.
    boot.kernelParams = [
      "console=ttyS0"
      # KMS debug, as before: the DRM E2E diagnoses itself from it.
      "drm.debug=0xf"
    ]
    ++ lib.optional (cfg.graphics == "virgl") "virgl.dmabuf=1"
    # Otherwise the legacy PS/2 keyboard keeps wl_seat.keyboard alive
    # after the named virtio keyboard is removed.
    ++ lib.optionals cfg.hotplug [ "i8042.nokbd=1" "i8042.noaux=1" ];
    boot.loader.grub.device = "/dev/vda";
    virtualisation.graphics = true;
    virtualisation.qemu.consoles = [ "ttyS0" ];
    virtualisation.qemu.options = graphicsOptions ++ qmpOptions ++ [
      # libinput input devices for the DRM E2E. Pixel verification is
      # guest-side; nothing here touches the host's input stack. The ids
      # are what the qualification unpluggs by name.
      "-device"
      ("virtio-keyboard-pci,id=wlvm-kbd" + lib.optionalString cfg.hotplug ",display=wlvm-gpu,head=0")
      "-device"
      ("virtio-mouse-pci,id=wlvm-mouse" + lib.optionalString cfg.hotplug ",display=wlvm-gpu,head=0")
      "-no-reboot"
    ];
    # The qemu-vm module's own id-less virtio-keyboard would sit on the
    # seat for the whole run; the hotplug profile needs the keyboard set
    # to be exactly the named device above, so that unplugging it really
    # does withdraw the keyboard capability.
    virtualisation.qemu.virtioKeyboard = lib.mkIf cfg.hotplug false;
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 8192;
    virtualisation.sharedDirectories = {
      repo = {
        # The repo root, passed as a specialArgs by scripts/vm-qualify.sh.
        # A relative path literal cannot be used here: this module is
        # copied into the store on import, so "./.." would resolve inside
        # the store and mount nothing.
        source =
          if repoPath == null then
            throw "scripts/vm.nix: pass repoPath (specialArgs) — the repo root to share into the guest"
          else
            repoPath;
        target = "/shared/repo";
      };
    };

    # Guest toolchain: zig + the wayland/xkbcommon dev outputs the build
    # links against (pkg-config resolved inside the guest, so the built
    # binaries carry guest store RPATHs).
    environment.systemPackages = [
      pkgs.zig
      pkgs.pkg-config
      pkgs.wayland
      pkgs.wayland.dev
      pkgs.wayland-protocols
      pkgs.libxkbcommon
      pkgs.libxkbcommon.dev
      # DRM + libinput backends: libdrm.dev/libinput.dev provide the .pc
      # files; libinput pulls libevdev at runtime (nix handles it).
      pkgs.libdrm
      pkgs.libdrm.dev
      pkgs.libinput
      pkgs.libinput.dev
      pkgs.libevdev
      # Canvas renderer: the real pixman library (SIMD compositor).
      pkgs.pixman
      # GLES2 renderer + the client's own GBM allocations: libglvnd for
      # the EGL/GLES loader and headers, mesa for the DRI drivers and
      # libgbm (the guest must be able to create AND export a DMA-BUF for
      # the client qualification to mean anything).
      glvnd
      pkgs.mesa
      # Interactive demo client (foot terminal on the canvas).
      pkgs.foot
      # Reference terminal client (weston-terminal) — used by the
      # interactive demo instead of foot (a simpler standard xdg_shell
      # client).
      pkgs.weston
      # The DRM E2E script's own tools. coreutils for grep/tail/sync (the
      # qualification hands the host a phase marker with `sync`), and
      # util-linux for mount(8): the guest remounts the 9p shares and, on
      # a kernel without systemd's debugfs unit, mounts /sys/kernel/debug
      # to reach the connector `force` file.
      pkgs.coreutils
      pkgs.util-linux
    ];
    environment.variables.PKG_CONFIG_PATH = guestPkgConfig;

    # Console root login for manual gates (headless E2E): auto-login on
    # the serial console (the VM image locks root's password regardless of
    # hashedPassword — auto-login sidesteps it for this disposable test
    # VM).
    services.getty.autologinUser = "root";
    systemd.services.${phaseDir.unit} = builtins.removeAttrs phaseDir [ "unit" ];


    systemd.services.compositor-demo-drm = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "${phaseDir.unit}.service" ];
      after = [ "local-fs.target" "${phaseDir.unit}.service" ];
      serviceConfig = {
        Type = "oneshot";
        # The script's /usr/bin/env shebang does not exist on NixOS;
        # invoke bash from the store directly (the service PATH is
        # minimal).
        ExecStart = "${pkgs.bash}/bin/bash /shared/repo/scripts/vm-drm-e2e.sh";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        Environment = lib.concatStringsSep " " (lib.mapAttrsToList (
          key: value: "${key}=${value}"
        ) e2eEnvironment);
      };
      # The minimal systemd service PATH does not include the system
      # packages: give the script the toolchain it needs. coreutils and
      # util-linux are the E2E script's own tools (the hotplug profile
      # writes the phase mailbox to the 9p share with `sync`, and mounts
      # /sys/kernel/debug when systemd has not).
      path = [ pkgs.zig pkgs.pkg-config pkgs.coreutils pkgs.util-linux ];
    };

    # Interactive canvas demo: DRM server + foot terminal on the guest
    # GPU output. Started by the compositor-demo-drm gate when the host
    # created /shared/repo/.no-auto-demo; run the VM WITHOUT -nographic
    # so qemu opens a window (virtio input reaches the seat through
    # libinput: drag pans, wheel zooms).
    systemd.services.compositor-demo-interactive = {
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash /shared/repo/scripts/vm-interactive.sh";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        Environment = "TERM=${pkgs.weston}/bin/weston-terminal";
      };
    };

    # Headless regression E2E: not wanted at boot; run with
    # `systemctl start compositor-demo`.
    systemd.services.compositor-demo = {
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        # The script's /usr/bin/env shebang does not exist on NixOS;
        # invoke bash from the store directly (the service PATH is
        # minimal).
        ExecStart = "${pkgs.bash}/bin/bash /shared/repo/scripts/vm-e2e.sh";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        Environment = lib.concatStringsSep " " (lib.mapAttrsToList (
          key: value: "${key}=${value}"
        ) e2eEnvironment);
      };
      # The minimal systemd service PATH does not include the system
      # packages: give the script the toolchain it needs.
      path = [ pkgs.zig pkgs.pkg-config ];
    };
  };
}