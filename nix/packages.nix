# The server, and the OCI image the cluster runs.
#
#   nix run  .#                    start a server here, on this machine
#   nix build .#zomboid-server     the launcher, on x86_64-linux or aarch64-darwin
#   nix build .#zomboid-image      the image, pushed to GHCR by CI
#
# The server exists wherever `pkgs/zomboid-server/default.nix` has a Steam
# depot for the system. The IMAGE stays Linux-only: dockerTools cannot build a
# Linux image from Darwin, and a package that evaluates everywhere but builds
# in one place is worse than one that is honestly absent.
#
# `coldstart.lib.mkImage` is called directly rather than through
# `coldstart.flakeModules.default`. The flake module only exists to turn an
# option set into this same call, and this flake no longer runs flake-parts.
{ inputs }:
{
  pkgs,
  lib,
  system,
}:
let
  onLinux = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux;

  # `meta.platforms` of the unwrapped server is the depot table's key set, so
  # this asks the package itself rather than repeating the list. Adding a depot
  # in `default.nix` is then the only edit an extra platform needs.
  onSupported = lib.optionalAttrs (lib.elem system pkgs.zomboid-server-unwrapped.meta.platforms);
in
onSupported {
  inherit (pkgs) zomboid-server zomboid-server-unwrapped;
  default = pkgs.zomboid-server;
}
// onLinux {
  zomboid-image = inputs.coldstart.lib.mkImage {
    inherit pkgs;
    name = "zomboid";
    packages = [ pkgs.zomboid-server ];

    # Nothing in the container builds a derivation, so Nix and its ~200M of
    # closure would be dead weight on top of an image that is already ~7G of
    # game content.
    #
    # What the image DOES carry, and did not before `--workshop`, is
    # DepotDownloader and the .NET runtime it needs — ~128M. That is not dead
    # weight: it is how a workshop mod reaches the container at all, now that
    # the server's own Steam download path is no longer the mechanism. Dropping
    # it would leave `ZOMBOID_WORKSHOP_ITEMS` as an option the Helm values can
    # set and the image cannot honour.
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

    # The wrapper defaults to /data, but the chart mounts the volume there and
    # being explicit is what keeps the two from drifting apart.
    env.ZOMBOID_STATE_DIR = "/data";

    # Links the GHCR package to this repo, so a package pushed by CI inherits
    # the repo's permissions instead of needing access granted by hand.
    labels."org.opencontainers.image.source" = "https://github.com/hcbt/nixzoid";
  };
}
