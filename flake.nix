{
  description = "A Project Zomboid dedicated server, built with Nix and deployed as a container";

  inputs = {
    # The shared scaffolding: treefmt, the git hooks, mkDevShell, the app
    # helpers, and the generated GitHub-side files.
    nivis.url = "github:hcbt/nivis/v0.7.1";

    # flake-parts builds `pkgs` from the CONSUMING flake's own nixpkgs input,
    # so this cannot be dropped.
    nixpkgs.follows = "nivis/nixpkgs";

    # The generic half: the OCI image builder, the Helm chart, and the
    # systemd-nspawn NixOS container. Everything here is the Zomboid-specific
    # remainder.
    coldstart = {
      url = "github:hcbt/coldstart";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `fetchSteam`, which wraps DepotDownloader, and the Steamworks SDK redist
    # the server dlopen()s to reach the Steam master server.
    steam-fetcher = {
      url = "github:nix-community/steam-fetcher";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ nivis, ... }:
    nivis.inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nivis.lib.defaultSystems;

      imports = [
        (nivis.flakeModules.default {
          srcRoot = ./.;
          repo = {
            # Public repo, so GitHub-hosted runners are available and the Nix
            # installer is needed.
            checks = true;
            initialVersion = "0.1.0";
          };
        })

        ./nix/lib.nix # flake.overlays.default, nixosModules.default
        ./nix/pkgs.nix # the `pkgs` this flake builds against
        ./nix/packages.nix # the server, and the OCI image
        ./nix/checks.nix
        ./nix/shells.nix
        ./nix/format.nix
      ];
    };
}
