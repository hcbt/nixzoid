# The public surface.
#
#   inputs.nixzoid.overlays.default      zomboid-server / zomboid-server-unwrapped
#   inputs.nixzoid.nixosModules.default  services.zomboid on an existing host
#   inputs.nixzoid.lib.mkServerIni       render a <name>.ini fragment
#   inputs.nixzoid.lib.mkSandboxVars     render a <name>_SandboxVars.lua
#
# The overlay is the reason `nixosModules` can exist at all: a flake's
# `nixosModules` is not scoped by system, so a package cannot be passed into
# it. The module applies the overlays to `nixpkgs.overlays` instead and reaches
# the server through its own `pkgs`.
#
# `lib` is exported for the OTHER consumer. On NixOS the module renders both
# files and points the launcher at the store; on Kubernetes the chart is
# coldstart's and knows nothing about Zomboid, so the cluster repository renders
# them itself into a ConfigMap and sets `ZOMBOID_CONFIG_FILE` to where it is
# mounted. Same renderer either way, so the two deployments cannot drift into
# different spellings of the same setting.
#
# System-independent, so `inputs.nixpkgs.lib` rather than a `perSystem` `pkgs` —
# these are string functions, and nothing here builds.
{ inputs, ... }:
{
  flake = {
    overlays.default = import ./overlay.nix;

    lib = import ../pkgs/zomboid-server/config-format.nix { inherit (inputs.nixpkgs) lib; };

    nixosModules.default = import ./nixos-module.nix {
      inherit (inputs) steam-fetcher coldstart;
      overlay = import ./overlay.nix;
    };
  };
}
