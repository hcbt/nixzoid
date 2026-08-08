{
  description = "A Project Zomboid dedicated server, built with Nix and deployed as a container";

  inputs = {
    # Declared directly now that nivis is gone. nivis used to supply
    # flake-parts, the dev shell, the hooks, the formatter and the generated
    # GitHub files. devenv covers the shell and the hooks; the GitHub files are
    # ordinary committed files again.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";

    # `follows` both ways is load-bearing. The hooks must run the same nixpkgs
    # the server is built from, and devenv must not pull a second git-hooks —
    # two copies means two prek versions writing the same
    # `.pre-commit-config.yaml`.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    devenv.inputs.git-hooks.follows = "git-hooks";

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

  # devenv publishes its own builds, so the shell comes down prebuilt instead of
  # being compiled on every machine and every CI run.
  nixConfig = {
    extra-substituters = "https://devenv.cachix.org";
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
  };

  outputs =
    inputs@{
      nixpkgs,
      devenv,
      ...
    }:
    let
      # Only what something actually checks. Each entry needs a runner in
      # .github/workflows/nix-check.yml, or it is a support claim nothing
      # verifies.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      forEachSystem = nixpkgs.lib.genAttrs systems;

      # nixpkgs with the Steam overlay and the unfree predicate. Every output
      # below goes through this rather than `legacyPackages`.
      pkgsFor = import ./nix/pkgs.nix { inherit inputs; };
    in
    # The system-independent surface: the overlay, the NixOS module and the
    # config renderers. devenv exposes none of these, which is why this flake
    # stays.
    import ./nix/lib.nix { inherit inputs; }
    // {
      packages = forEachSystem (
        system:
        import ./nix/packages.nix { inherit inputs; } {
          inherit system;
          pkgs = pkgsFor system;
          inherit (nixpkgs) lib;
        }
      );

      checks = forEachSystem (
        system:
        import ./nix/checks.nix { inherit inputs; } {
          pkgs = pkgsFor system;
          inherit (nixpkgs) lib;
        }
        // {
          # The hooks, as a check. `devenv.lib.mkShell` installs them for a
          # developer, but nothing in a devenv shell runs in CI — so without
          # this, an unformatted file reaches master and nothing says so. This
          # is what nivis' `checks.pre-commit` used to provide.
          pre-commit = inputs.git-hooks.lib.${system}.run {
            src = ./.;
            package = (pkgsFor system).prek;
            inherit ((import ./devenv.nix { pkgs = pkgsFor system; }).git-hooks) hooks excludes;
          };
        }
      );

      # `nix develop` / direnv. The shell itself is in devenv.nix so it can be
      # diffed against the other repos' copies.
      devShells = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [ ./devenv.nix ];
          };
        }
      );
    };
}
