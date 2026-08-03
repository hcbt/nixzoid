# `services.zomboid` — the server on an existing NixOS host, in a
# systemd-nspawn container.
#
#   imports = [ inputs.nixzoid.nixosModules.default ];
#   services.zomboid = {
#     enable = true;
#     openFirewall = true;
#     stateDir = "/srv/zomboid";
#
#     # Downloaded on start by the launcher, and enabled on their own. `mods`
#     # is only needed for a hand-placed mod or to fix the load order.
#     workshopItems = [ "2392709985" "2857548524" ];
#
#     settings = {
#       PublicName = "…";
#       MaxPlayers = 16;
#       PVP = false;
#     };
#     sandbox.Zombies = 3;
#
#     adminPasswordFile = "/run/secrets/zomboid-admin";
#   };
#
# The containerisation is coldstart's; everything here is the Zomboid-shaped
# half — which ports, which heap, where the saves live, and what goes in the two
# config files.
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

  format = import ../pkgs/zomboid-server/config-format.nix { inherit lib; };

  # Where the state volume lands INSIDE the container. Bound in two places —
  # coldstart's own mount and the restated one below — so it is named once.
  containerStateDir = "/var/lib/zomboid";

  # Recursive, because SandboxVars groups its settings into nested tables
  # (`ZombieLore.Speed`, `Map.AllowMiniMap`). Same shape nixpkgs' own
  # `formats.json` uses for the same reason.
  sandboxValue =
    with lib.types;
    nullOr (oneOf [
      bool
      int
      float
      str
      (attrsOf sandboxValue)
    ]);

  # Host paths that have to be readable from inside the container. Secrets only:
  # everything else the launcher reads is a store path, and /nix/store is
  # already mounted.
  secretFiles = lib.filter (f: f != null) [
    cfg.adminPasswordFile
    cfg.secretConfigFile
  ];

  configFile = pkgs.writeText "${cfg.serverName}.ini" (format.mkServerIni cfg.settings);
  sandboxFile = pkgs.writeText "${cfg.serverName}_SandboxVars.lua" (format.mkSandboxVars cfg.sandbox);
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

    # ---- mods --------------------------------------------------------------

    workshopItems = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.str lib.types.int);
      default = [ ];
      example = [
        "2392709985"
        "2857548524"
      ];
      description = ''
        Steam Workshop ids to install. The LAUNCHER downloads each one on
        start with DepotDownloader, anonymously, into the state directory —
        nothing is baked into the image, so adding a mod costs a restart rather
        than a ~7G rebuild.

        Enough on its own. Every mod an item carries is installed and enabled,
        with the mod ids read out of each `mod.info`, so `mods` is only needed
        for a mod placed under the state directory by hand or to fix the load
        order.

        This does NOT set `WorkshopItems=`, which asks the server to download
        through Steam instead. Running both would fetch each item twice, at
        possibly different versions, and the server's own copy wins — its mod
        folder order is `workshop,steam,mods`. Set it through `settings` if you
        want that path.

        The trade for not pinning: a mod author's update lands on the next
        restart, unannounced. Steam has to be reachable from wherever the
        server runs, unless `workshopOffline` is set.
      '';
    };

    workshopOffline = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reuse whatever `workshopItems` has already downloaded and contact Steam
        for nothing. A restart then cannot pick up a mod update — which is the
        point, when a world is mid-run and a mod changing underneath it is the
        risk being avoided.

        A first start with this set fails, rather than starting without the
        mods.
      '';
    };

    mods = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "tsarslib"
        "Brita_2"
      ];
      description = ''
        Mod ids to ENABLE, rendered into the config's `Mods=`. These are the
        internal names out of each mod's `mod.info`, not the Workshop ids — a
        single Workshop item often ships several, and they rarely match the
        title.

        Rarely needed alongside `workshopItems`, which enables what it
        downloads on its own. What it is still for: a mod placed under
        `''${stateDir}/mods` by hand, and load order — `Mods=` loads in the
        order given, ids listed here come first, and a library has to load
        before whatever needs it.
      '';
    };

    # ---- configuration -----------------------------------------------------

    settings = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          nullOr (oneOf [
            bool
            int
            float
            str
            (listOf (either str int))
          ])
        );
      default = { };
      example = lib.literalExpression ''
        {
          PublicName = "Knox County";
          MaxPlayers = 16;
          PVP = false;
          PauseEmpty = true;
        }
      '';
      description = ''
        Keys for `Server/<serverName>.ini`, written verbatim as `Key=value`.
        Booleans render as `true`/`false` and lists join with `;`.

        Only the keys declared here are managed. On every start they are merged
        into the file the server maintains, so the other ~150 options it keeps
        for itself are preserved — and an in-game change to a key declared here
        is overwritten at the next restart. Set a key to `null` to hand it back
        to the server.

        Not the place for `Password` or `RCONPassword`: everything here lands in
        the world-readable Nix store. Use `secretConfigFile`.
      '';
    };

    sandbox = lib.mkOption {
      type = lib.types.attrsOf sandboxValue;
      default = { };
      example = lib.literalExpression ''
        {
          Zombies = 3;
          Distribution = 1;
          ZombieLore = {
            Speed = 2;
            Strength = 2;
          };
        }
      '';
      description = ''
        Contents of `Server/<serverName>_SandboxVars.lua` — the world's rules,
        as opposed to the server's. Nested sets become nested Lua tables.

        Unlike `settings` this file is rewritten IN FULL on every start, because
        merging it would mean parsing Lua and a line-oriented approximation
        corrupts a nested group instead of failing. Keys left out take the
        server's own defaults, so a short declaration is a complete one. Leave
        the option empty and the file is not touched at all.
      '';
    };

    spawnRegionsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./spawnregions.lua";
      description = ''
        A `Server/<serverName>_spawnregions.lua`, copied into place on every
        start. Needed when a map mod adds its own spawn points.

        A store path — a literal `./file` becomes one. Unlike the secret options
        below it needs no bind mount, because /nix/store is already in the
        container.
      '';
    };

    # ---- secrets -----------------------------------------------------------

    secretConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/zomboid-config";
      description = ''
        An absolute path ON THE HOST to a second config fragment, in the same
        `Key=value` form as `settings` and applied after it. For the keys that
        must not reach the Nix store, which is world-readable:

        ```
        Password=…
        RCONPassword=…
        ```

        Bind-mounted read-only into the container at the same path, so it has to
        exist before the container starts and has to be readable by the
        unprivileged `zomboid` user.
      '';
    };

    adminUsername = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Name of the administrator account created on first start.";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/zomboid-admin-password";
      description = ''
        An absolute path ON THE HOST to a file holding the administrator
        password, bind-mounted read-only into the container.

        Effectively required for a first start. With no administrator in the
        state directory the server prompts for one on stdin and waits, and
        nothing in a container answers — the start hangs with a log that stops
        mid-way and names nothing.

        The password reaches the server on its command line, where the process
        table exposes it. The server offers no other way in; what this keeps out
        of reach is the Nix store.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "-steamvac"
        "false"
      ];
      description = ''
        Extra arguments appended to the server command line. `-servername`,
        `-cachedir`, `-adminusername` and `-adminpassword` are already supplied
        from the options above.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # `mkDefault`, so `mods` is just a spelling of an ini key and
    # `settings.Mods` still wins if someone would rather write it out directly.
    #
    # `workshopItems` is NOT here. It reaches the launcher through the
    # environment instead, because the launcher downloads those items itself —
    # rendering them into `WorkshopItems=` would hand the job back to the
    # server's Steam path and run both.
    services.zomboid.settings = lib.mkIf (cfg.mods != [ ]) { Mods = lib.mkDefault cfg.mods; };

    coldstart.containers.zomboid = {
      inherit (cfg) openFirewall privateNetwork;

      # No `-servername` here: the launcher passes it from the environment, so
      # that the name the config files are called and the name the server is
      # told cannot drift apart. The image entrypoint takes no arguments at
      # all, and this is what makes both paths behave the same.
      execStart = lib.escapeShellArgs (
        [
          (lib.getExe cfg.package)
          "-port"
          (toString cfg.port)
        ]
        ++ cfg.extraArgs
      );

      hostStateDir = cfg.stateDir;
      stateDir = containerStateDir;

      environment = {
        ZOMBOID_STATE_DIR = containerStateDir;
        ZOMBOID_SERVER_NAME = cfg.serverName;
        ZOMBOID_ADMIN_USERNAME = cfg.adminUsername;
      }
      // lib.optionalAttrs (cfg.workshopItems != [ ]) {
        # Space separated: a systemd `Environment=` line carries one string,
        # and `zomboid-workshop` splits on either separator.
        ZOMBOID_WORKSHOP_ITEMS = lib.concatMapStringsSep " " toString cfg.workshopItems;
      }
      // lib.optionalAttrs cfg.workshopOffline {
        ZOMBOID_WORKSHOP_OFFLINE = "1";
      }
      // lib.optionalAttrs (cfg.settings != { }) {
        ZOMBOID_CONFIG_FILE = toString configFile;
      }
      // lib.optionalAttrs (cfg.sandbox != { }) {
        ZOMBOID_SANDBOX_FILE = toString sandboxFile;
      }
      // lib.optionalAttrs (cfg.spawnRegionsFile != null) {
        ZOMBOID_SPAWNREGIONS_FILE = toString cfg.spawnRegionsFile;
      }
      // lib.optionalAttrs (cfg.secretConfigFile != null) {
        ZOMBOID_CONFIG_SECRET_FILE = cfg.secretConfigFile;
      }
      // lib.optionalAttrs (cfg.adminPasswordFile != null) {
        ZOMBOID_ADMIN_PASSWORD_FILE = cfg.adminPasswordFile;
      };

      # The game port, plus one per concurrent direct connection.
      ports.udp = [ cfg.port ] ++ lib.genList (i: cfg.port + 1 + i) cfg.directConnectPorts;

      # coldstart merges this with `//`, so declaring `bindMounts` REPLACES its
      # own rather than adding to it — which is why the state mount is restated
      # here. Without the restatement the saves would land in the container's
      # ephemeral root and a restart would lose them, silently.
      extraContainerConfig = lib.mkIf (secretFiles != [ ]) {
        bindMounts = {
          ${containerStateDir} = {
            hostPath = toString cfg.stateDir;
            isReadOnly = false;
          };
        }
        // lib.listToAttrs (
          map (
            f:
            lib.nameValuePair f {
              hostPath = f;
              isReadOnly = true;
            }
          ) secretFiles
        );
      };
    };

    warnings =
      # `workshopItems` alone is now the CORRECT spelling — the launcher
      # enables what it installs — so the pairing that used to be warned about
      # is gone. What is left is the two ways to say the same thing at once.
      lib.optional (cfg.workshopItems != [ ] && cfg.settings ? WorkshopItems) ''
        services.zomboid.workshopItems and settings.WorkshopItems are both set.
        Those are two different downloaders for one job: the launcher fetches
        the first with DepotDownloader, and the server fetches the second
        through Steam. Each item would be downloaded twice, at possibly
        different versions, and the server's copy wins — its mod folder order
        is workshop,steam,mods. Use one of them.
      ''
      ++ lib.optional (cfg.mods != [ ] && cfg.workshopItems == [ ]) ''
        services.zomboid.mods is set but services.zomboid.workshopItems is
        empty. The server will try to enable mods it never downloaded, unless
        every one of them is already present under ${cfg.stateDir}/mods.
      ''
      ++ lib.optional (cfg.workshopOffline && cfg.workshopItems == [ ]) ''
        services.zomboid.workshopOffline is set but workshopItems is empty, so
        it has nothing to act on.
      ''
      ++ lib.optional (cfg.adminPasswordFile == null) ''
        services.zomboid.adminPasswordFile is unset. On a first start — an empty
        state directory — the server asks for an administrator password on
        stdin and waits for an answer that nothing in the container can give,
        and the start hangs part-way through with nothing in the log naming the
        prompt.
      '';

    assertions = [
      {
        assertion = cfg.directConnectPorts >= 1;
        message = "services.zomboid.directConnectPorts must be at least 1 — with none, no player can connect.";
      }
      {
        # It becomes a filename under Server/, and the failure of a bad one is a
        # server that starts against a config it did not write.
        assertion = cfg.serverName != "" && !(lib.hasInfix "/" cfg.serverName);
        message = "services.zomboid.serverName must be a non-empty name without a slash — it names files under Server/ in the state directory.";
      }
      {
        assertion = lib.all (f: lib.hasPrefix "/" f) secretFiles;
        message = "services.zomboid.adminPasswordFile and secretConfigFile must be absolute host paths — they are bind-mounted into the container at the same path.";
      }
    ];
  };
}
