# The public surface.
#
#   inputs.nixzoid.overlays.default      zomboid-server / zomboid-server-unwrapped
#   inputs.nixzoid.nixosModules.default  services.zomboid on an existing host
#
# The overlay is the reason `nixosModules` can exist at all: a flake's
# `nixosModules` is not scoped by system, so a package cannot be passed into
# it. The module applies the overlays to `nixpkgs.overlays` instead and reaches
# the server through its own `pkgs`.
{ inputs, ... }:
{
  flake = {
    overlays.default = import ./overlay.nix;

    nixosModules.default = import ./nixos-module.nix {
      inherit (inputs) steam-fetcher coldstart;
      overlay = import ./overlay.nix;
    };
  };
}
