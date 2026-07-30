# The server, and the OCI image the cluster runs.
#
#   nix build .#zomboid-server     the launcher, runnable on any Linux host
#   nix build .#zomboid-image      the image, pushed to GHCR by CI
#
# Linux only. DepotDownloader is the smaller reason; the real one is that
# dockerTools cannot build a Linux image from Darwin, and a package that
# evaluates everywhere but builds in one place is worse than one that is
# honestly absent.
{ inputs, ... }:
{
  imports = [ inputs.coldstart.flakeModules.default ];

  # The Linux guard is applied to each attribute's VALUE, never to the module's
  # definition set. `perSystem = { pkgs, ... }: lib.optionalAttrs …` would make
  # *which options exist* depend on `pkgs` — and `pkgs` is itself a module
  # argument, so the module system cannot decide what is declared without
  # already having it. That is an infinite recursion, and it reports itself as
  # `_module.args` in lib/modules.nix with nothing pointing back here.
  perSystem =
    { pkgs, lib, ... }:
    let
      onLinux = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux;
    in
    {
      packages = onLinux {
        inherit (pkgs) zomboid-server zomboid-server-unwrapped;
        default = pkgs.zomboid-server;
      };

      coldstart.images = onLinux {
        zomboid-image = {
          name = "zomboid";
          packages = [ pkgs.zomboid-server ];

          # Nothing in the container builds a derivation, so Nix and its ~200M of
          # closure would be dead weight on top of an image that is already ~7G
          # of game content.
          withNix = false;

          # The server reaches the Steam master server over TLS.
          withCacert = true;

          entrypoint = [ (lib.getExe pkgs.zomboid-server) ];

          # Metadata only — the chart is what actually publishes them.
          exposedPorts = {
            "16261/udp" = { };
            "16262/udp" = { };
          };

          user = {
            name = "zomboid";
            uid = 1000;
            gid = 1000;
            home = "/data";
          };

          # The wrapper defaults to /data, but the chart mounts the volume there
          # and being explicit is what keeps the two from drifting apart.
          env.ZOMBOID_STATE_DIR = "/data";

          # Links the GHCR package to this repo, so a package pushed by CI
          # inherits the repo's permissions instead of needing access granted by
          # hand.
          labels."org.opencontainers.image.source" = "https://github.com/hcbt/nixzoid";
        };
      };
    };
}
