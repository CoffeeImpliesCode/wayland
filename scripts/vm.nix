# Minimal NixOS VM for native compositor testing.
#
# Run (from a flake wrapper that points `nixpkgs` at your registry entry):
#   nix build /tmp/wl-vm#nixosConfigurations.wlvm.config.system.build.vm
#   ./result/bin/run-wlvm-vm -nographic
#
# The VM shares the repo read-write via 9p (/shared/repo), builds it with
# the guest toolchain, and runs the headless E2E (libinput-capable seat +
# virtual pixman framebuffer) at boot, printing VM-E2E-OK before powering
# off. The host desktop (niri) is never in the loop.
{ config, pkgs, ... }:
{
  # Serial console only: no graphics stack in the guest.
  boot.kernelParams = [ "console=ttyS0" ];
  boot.loader.grub.device = "/dev/vda";
  virtualisation.graphics = false;
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
  ];
  environment.variables.PKG_CONFIG_PATH =
    "${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${pkgs.libxkbcommon.dev}/lib/pkgconfig";

  # Boot-time E2E: build the repo in the guest (isolated caches so the
  # shared dir stays host-clean) and run the headless server + test client.
  systemd.services.compositor-demo = {
    wantedBy = [ "multi-user.target" ];
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
      Environment = "PKG_CONFIG_PATH=${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${pkgs.libxkbcommon.dev}/lib/pkgconfig";
    };
    # The minimal systemd service PATH does not include the system
    # packages: give the script the toolchain it needs.
    path = [ pkgs.zig pkgs.pkg-config ];
  };
}
