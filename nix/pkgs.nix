# The package set everything here builds against.
#
# flake-parts builds a default `pkgs` with no overlays and no `config`, and
# neither default works here: the server comes from `steam-fetcher`'s overlay,
# and Project Zomboid is unfree — an unconfigured nixpkgs refuses to evaluate it
# at all, with an error about `allowUnfreePredicate` rather than about the game.
#
# Scoped with a predicate rather than `allowUnfree = true`, so a stray unfree
# dependency arriving through some other package still has to be named here.
{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        # `import ./overlay.nix` rather than `inputs.self.overlays.default`:
        # `pkgs` is what every other module here is evaluated with, so reading
        # it back out of this flake's own outputs is a cycle waiting to happen.
        overlays = [
          inputs.steam-fetcher.overlay
          (import ./overlay.nix)
        ];
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (inputs.nixpkgs.lib.getName pkg) [
            "zomboid-server"
            "zomboid-server-unwrapped"
            "steamworks-sdk-redist"
          ];
      };
    };
}
