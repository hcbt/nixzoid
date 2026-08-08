{
  description = "A Project Zomboid dedicated server, built with Nix and deployed as a container";

  inputs = {
    # Declared directly now that nivis is gone. nivis used to supply
    # flake-parts, the dev shell, the hooks, the formatter and the generated
    # GitHub files. devenv covers the shell and the hooks; the GitHub files are
    # ordinary committed files again.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # NOT `follows`-ed onto this flake's nixpkgs, deliberately. devenv is Rust,
    # and the binaries on devenv.cachix.org are built against
    # `cachix/devenv-nixpkgs/rolling`. Overriding its nixpkgs changes the
    # derivation hash, every substituter misses, and devenv and its whole crate
    # graph compile from source on each machine and each CI run.
    #
    # Nothing is lost by leaving it alone: `devenv.lib.mkShell` takes `pkgs`
    # explicitly, so the shell's own tools still come from the package set
    # below. Only devenv's implementation rides on its own pin.
    devenv.url = "github:cachix/devenv";

    # This one DOES follow. The hooks format this repository's files, so they
    # must run the same nixpkgs the rest of it is built from.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

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

      # devenv's own package set — what the shell is built from.
      devenvPkgsFor = forEachSystem (system: import devenv.inputs.nixpkgs { inherit system; });

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
            inherit
              ((import ./devenv.nix {
                pkgs = pkgsFor system;
                # The hook TOOLS come from devenv's set, the same one the shell
                # is built from, so `prek run --all-files` in the shell and this
                # check cannot disagree about formatting. Only the tools — the
                # check itself stays on this flake's nixpkgs, because building
                # it from devenv's realises a second uncached closure on the
                # runner.
                toolPkgs = devenvPkgsFor.${system};
              }).git-hooks
              )
              hooks
              excludes
              ;
          };
        }
      );

      # `nix develop` / direnv. The shell itself is in devenv.nix so it can be
      # diffed against the other repos' copies.
      devShells = forEachSystem (system: {
        default = devenv.lib.mkShell {
          inherit inputs;

          # devenv's OWN package set, not this flake's.
          #
          # `mkShell` builds `devenv-tasks` — a Rust program — out of whatever
          # `pkgs` it is handed, and the binaries on devenv.cachix.org are
          # built against `cachix/devenv-nixpkgs/rolling`. Pass this flake's
          # nixpkgs-unstable instead and the derivation hash changes, every
          # substituter misses, and devenv-tasks and prek compile from source
          # on every machine and every CI run.
          #
          # Nothing needs the Zomboid overlay here. The shell holds helm,
          # kubectl, jq and the everyday utilities, none of which the server or
          # the image is built from — those still come from `pkgsFor`.
          pkgs = import devenv.inputs.nixpkgs { inherit system; };

          modules = [ ./devenv.nix ];
        };
      });
    };
}
