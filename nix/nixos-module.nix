# `services.zomboid` — the server on an existing NixOS host, in a
# systemd-nspawn container.
#
#   imports = [ inputs.nixzoid.nixosModules.default ];
#   services.zomboid = {
#     enable = true;
#     openFirewall = true;
#     stateDir = "/srv/zomboid";
#   };
#
# The containerisation is coldstart's; everything here is the Zomboid-shaped
# half — which ports, which heap, where the saves live.
#
# Takes the overlay and the two flakes it needs, because a flake's
# `nixosModules` is not scoped by system and so cannot be handed a package.
# The overlay arrives as a value rather than via `self` so that `nix/checks.nix`
# can evaluate this module without reaching into the flake's own outputs.
{
  overlay,
  steam-fetcher,
  coldstart,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zomboid;
in
{
  imports = [
    coldstart.nixosModules.default

    # The overlays live in a module of their OWN, and one that takes no module
    # arguments at all. Setting `nixpkgs.overlays` in the same module that
    # reads `pkgs` — as `services.zomboid.package`'s default does — is an
    # infinite recursion: `pkgs` is built from the overlays, the overlays come
    # from `config`, and `config` needs the option default that reads `pkgs`.
    # The error names `_module.args` and points at lib/modules.nix, which says
    # nothing about either overlay.
    #
    # `lib` is safe to take here — it is a fixed point of nixpkgs' own library,
    # not of `config`. Only `pkgs` and `config` close the loop.
    (
      { lib, ... }:
      {
        nixpkgs.overlays = [
          steam-fetcher.overlay
          overlay
        ];

        # Project Zomboid is unfree, so an unconfigured nixpkgs refuses to
        # evaluate it — with an error about the predicate rather than about the
        # game.
        nixpkgs.config.allowUnfreePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "zomboid-server"
            "zomboid-server-unwrapped"
            "steamworks-sdk-redist"
          ];
      }
    )
  ];

  options.services.zomboid = {
    enable = lib.mkEnableOption "Project Zomboid dedicated server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zomboid-server;
      defaultText = lib.literalExpression "pkgs.zomboid-server";
      description = "The server package. Override to pin a heap size or extra JVM arguments.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/zomboid";
      description = ''
        Host directory holding the saves, server config and logs. This is the
        only thing here worth backing up — everything else is re-derivable from
        the flake.
      '';
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      default = "servertest";
      description = ''
        Names the server's config files under `Server/` in the state
        directory — `<name>.ini`, `<name>_SandboxVars.lua`. Changing it after
        first start means the server writes a FRESH config and appears to have
        lost its settings, so pick one before the first boot.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 16261;
      description = "UDP port clients connect to.";
    };

    directConnectPorts = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = ''
        How many consecutive UDP ports above `port` to open for direct player
        connections — the server uses one per connected player. The default of
        one matches a small private server; raise it to the player cap.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the game ports in the host firewall.";
    };

    privateNetwork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Give the container its own network namespace, with the ports forwarded
        from the host. Off by default: forwarding rewrites the source address,
        and Project Zomboid's own ban list works on IP.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "-adminusername"
        "admin"
      ];
      description = "Extra arguments appended to the server command line.";
    };
  };

  config = lib.mkIf cfg.enable {
    coldstart.containers.zomboid = {
      inherit (cfg) openFirewall privateNetwork;

      execStart = lib.escapeShellArgs (
        [
          (lib.getExe cfg.package)
          "-servername"
          cfg.serverName
          "-port"
          (toString cfg.port)
        ]
        ++ cfg.extraArgs
      );

      hostStateDir = cfg.stateDir;
      stateDir = "/var/lib/zomboid";
      environment.ZOMBOID_STATE_DIR = "/var/lib/zomboid";

      # The game port, plus one per concurrent direct connection.
      ports.udp = [ cfg.port ] ++ lib.genList (i: cfg.port + 1 + i) cfg.directConnectPorts;
    };

    assertions = [
      {
        assertion = cfg.directConnectPorts >= 1;
        message = "services.zomboid.directConnectPorts must be at least 1 — with none, no player can connect.";
      }
    ];
  };
}
