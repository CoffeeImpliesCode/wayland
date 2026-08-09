{ config, pkgs, ... }:
{
  # Minimal NixOS VM for native compositor testing.
  #
  # Run (from a flake wrapper that points `nixpkgs` at your registry entry):
  #   nix build /tmp/wl-vm#nixosConfigurations.wlvm.config.system.build.vm
  #   ./result/bin/run-wlvm-vm -nographic
# The VM shares the repo read-write via 9p (/shared/repo) and builds it
# with the guest toolchain. Two E2E modes run as boot-time oneshot
# services, each printing its OK line before powering off:
#   - compositor-demo-drm (boot default, wantedBy multi-user.target):
#     DRM/KMS backend on the virtio-gpu device (/dev/dri/card0) plus the
#     libinput source on the virtio keyboard/mouse evdev devices
#     (/dev/input/*; virtio-mouse is absolute). Prints VM-DRM-E2E-OK.
#   - compositor-demo (manual, `systemctl start compositor-demo`): the
#     headless E2E (libinput-capable seat + virtual pixman framebuffer).
#     Prints VM-E2E-OK.
# The host desktop (niri) is never in the loop.
  # Serial console only: no graphics stack in the guest.
  boot.kernelParams = [ "console=ttyS0" "drm.debug=0xf" ];
  boot.loader.grub.device = "/dev/vda";
  virtualisation.graphics = false;
  # Guest DRM + input devices for the DRM/libinput E2E: virtio-gpu-pci is
  # the guest DRM device (/dev/dri/card0); the keyboard/mouse are the guest
  # evdev devices (/dev/input/*). Serial console only; pixel verification
  # is guest-side.
  virtualisation.qemu.options = [
    "-device virtio-gpu-pci,xres=1280,yres=720"
    "-device virtio-keyboard-pci"
    "-device virtio-mouse-pci"
    "-no-reboot"
  ];
  virtualisation.memorySize = 2048;
  virtualisation.diskSize = 4096;
  virtualisation.sharedDirectories = {
    repo = {
      source = "~/projects/wayland";
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
  ];
  environment.variables.PKG_CONFIG_PATH =
    "${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${pkgs.libxkbcommon.dev}/lib/pkgconfig:${pkgs.systemd.dev}/lib/pkgconfig:${pkgs.libdrm.dev}/lib/pkgconfig:${pkgs.libinput.dev}/lib/pkgconfig";

  # Boot-time E2Es: build the repo in the guest (isolated caches so the
  # shared dir stays host-clean) and run the DRM + libinput E2E at boot
  # (compositor-demo-drm, the default); the headless regression
  # (compositor-demo) stays available as a manually-started unit.
  systemd.services.compositor-demo-drm = {
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      # The script's /usr/bin/env shebang does not exist on NixOS; invoke
      # bash from the store directly (the service PATH is minimal).
      ExecStart = "${pkgs.bash}/bin/bash /shared/repo/scripts/vm-drm-e2e.sh";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      # environment.variables does not reliably reach systemd services;
      # give the build the .pc search path explicitly.
      Environment = "PKG_CONFIG_PATH=${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${pkgs.libxkbcommon.dev}/lib/pkgconfig:${pkgs.systemd.dev}/lib/pkgconfig:${pkgs.libdrm.dev}/lib/pkgconfig:${pkgs.libinput.dev}/lib/pkgconfig";
    };
    # The minimal systemd service PATH does not include the system
    # packages: give the script the toolchain it needs.
    path = [ pkgs.zig pkgs.pkg-config ];
  };

  # Headless regression E2E: not wanted at boot; run with
  # `systemctl start compositor-demo`.
  systemd.services.compositor-demo = {
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      # The script's /usr/bin/env shebang does not exist on NixOS; invoke
      # bash from the store directly (the service PATH is minimal).
      ExecStart = "${pkgs.bash}/bin/bash /shared/repo/scripts/vm-e2e.sh";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      # environment.variables does not reliably reach systemd services;
      # give the build the .pc search path explicitly.
      Environment = "PKG_CONFIG_PATH=${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${pkgs.libxkbcommon.dev}/lib/pkgconfig:${pkgs.systemd.dev}/lib/pkgconfig:${pkgs.libdrm.dev}/lib/pkgconfig:${pkgs.libinput.dev}/lib/pkgconfig";
    };
    # The minimal systemd service PATH does not include the system
    # packages: give the script the toolchain it needs.
    path = [ pkgs.zig pkgs.pkg-config ];
  };
}
