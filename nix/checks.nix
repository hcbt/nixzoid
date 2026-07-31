# Tests.
#
# Deliberately NONE of these build the server. The two Steam depots are ~7G
# unpacked, and a check that downloaded them would make `nix flake check` an
# hour-long operation on every commit and every CI run. What is checked here is
# everything that can go wrong WITHOUT the game content: that the derivations
# instantiate, that the launcher's arguments are the ones upstream specifies,
# and that the NixOS module wires the container correctly.
#
# `nix build .#zomboid-image` in the image workflow is what proves the heavy
# half works.
{ inputs, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      overlay = import ./overlay.nix;

      # The module, built the same way `flake.nixosModules.default` builds it —
      # but from the files rather than from this flake's outputs, so evaluating
      # it here cannot cycle.
      zomboidModule = import ./nixos-module.nix {
        inherit overlay;
        inherit (inputs) steam-fetcher coldstart;
      };

      evalHost =
        module:
        inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            zomboidModule
            (
              { ... }:
              {
                boot.loader.grub.enable = false;
                fileSystems."/".device = "/dev/null";
                system.stateVersion = "24.05";
              }
            )
            module
          ];
        };
    in
    {
      checks = {
        # Instantiation is the test: a bad `fetchSteam` argument, a missing
        # buildInput or a typo in the wrapper fails here, in seconds, without
        # fetching a byte of the game.
        packages-evaluate =
          let
            linuxPkgs = import inputs.nixpkgs {
              system = "x86_64-linux";
              overlays = [
                inputs.steam-fetcher.overlay
                overlay
              ];
              config.allowUnfreePredicate =
                pkg:
                builtins.elem (lib.getName pkg) [
                  "zomboid-server"
                  "zomboid-server-unwrapped"
                  "steamworks-sdk-redist"
                ];
            };
            drv = p: builtins.unsafeDiscardStringContext p.drvPath;
          in
          pkgs.runCommand "packages-evaluate" { } ''
            fail() { echo "FAIL: $*" >&2; exit 1; }
            eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

            echo ${lib.escapeShellArg (drv linuxPkgs.zomboid-server-unwrapped)}
            echo ${lib.escapeShellArg (drv linuxPkgs.zomboid-server)}

            # Both depots have to be inputs of the unwrapped derivation. If a
            # refactor ever dropped one, the server would build and then fail
            # at runtime with a missing jar or a missing native — the slowest
            # possible way to find out.
            eq 2 ${lib.escapeShellArg (toString (builtins.length linuxPkgs.zomboid-server-unwrapped.srcs))} \
              "the unwrapped server merges both Steam depots"

            eq "zomboid-server" ${lib.escapeShellArg linuxPkgs.zomboid-server.meta.mainProgram} \
              "the wrapper is the program consumers run"

            touch $out
          '';

        # The launcher replaces upstream's start-server.sh and
        # ProjectZomboid64.json, so it has to carry the same JVM arguments they
        # did. Asserting on the generated script is the only way to know: the
        # server starts happily without -Djava.library.path and then dies on
        # the first dlopen, several seconds later, with an UnsatisfiedLinkError
        # that names a class rather than the flag.
        launcher-arguments =
          let
            linuxPkgs = import inputs.nixpkgs {
              system = "x86_64-linux";
              overlays = [
                inputs.steam-fetcher.overlay
                overlay
              ];
              config.allowUnfreePredicate = _: true;
            };
            # `passthru`, not the built output: building would pull ~7G of
            # Steam depots into every `nix flake check`.
            #
            # The context has to be discarded as well. The script interpolates
            # the unwrapped server's store path, so handing the string to a
            # derivation makes that path an INPUT — and Nix then downloads both
            # depots to build a check that only ever greps text.
            script = builtins.unsafeDiscardStringContext linuxPkgs.zomboid-server.launcher;
          in
          pkgs.runCommand "launcher-arguments"
            {
              inherit script;
              passAsFile = [ "script" ];
            }
            ''
              fail() { echo "FAIL: $*" >&2; exit 1; }
              has() { grep -qF -- "$1" "$scriptPath" || fail "$2"; }

              has "-Djava.awt.headless=true" "a headless server must not try to open a display"
              has "-Dzomboid.steam=1" "without the Steam flag the server never registers with the master server"
              has "-Djava.library.path=" "the JNI natives are found through java.library.path, or the server dies on first dlopen"
              has "-XX:+UseZGC" "upstream selects ZGC; the default collector pauses a running world"
              # Retuning the heap must not require rebuilding a ~7G image.
              has 'ZOMBOID_HEAP:-' "the heap has to be overridable at runtime, with the built-in value as the default"
              has "zombie.network.GameServer" "the server main class"
              has "-cachedir=" "state has to be redirected out of the read-only store"
              # The server resolves its media through a scan rooted at the
              # WORKING DIRECTORY, so that has to be the install root — the
              # same thing upstream's start-server.sh does with `cd $INSTDIR`.
              # Anywhere else and it starts, then dies deep in world load on a
              # missing animation asset or a null worldgen table, naming no file.
              has "cd /nix/store" "the working directory must be the install root, not the state dir"
              has "LD_LIBRARY_PATH" "steamclient.so is resolved through LD_LIBRARY_PATH"

              # HOME and -cachedir= must agree. The server resolves some paths
              # from each, so setting only one scatters state across two
              # directories — one of them inside the store.
              has 'export HOME=' "HOME must be redirected alongside -cachedir="

              touch $out
            '';

        # The NixOS module's whole job is wiring coldstart's container
        # correctly. Evaluation is the test, and the assertions below are the
        # things that are wrong-but-valid rather than outright broken.
        nixos-module =
          let
            host = evalHost {
              services.zomboid = {
                enable = true;
                serverName = "apocalypse";
                port = 17000;
                directConnectPorts = 3;
                openFirewall = true;
                stateDir = "/srv/zomboid";
              };
            };
            container = host.config.containers.zomboid;
            # Context discarded for the same reason as in
            # `launcher-arguments`: `execStart` interpolates the server's store
            # path, and writing it into a derivation would make the ~7G of
            # Steam depots an input of a check that only reads strings.
            json = pkgs.writeText "nixos-module.json" (
              builtins.unsafeDiscardStringContext (
                builtins.toJSON {
                  udp = container.config.networking.firewall.allowedUDPPorts;
                  hostUdp = host.config.networking.firewall.allowedUDPPorts;
                  bind = container.bindMounts."/var/lib/zomboid".hostPath;
                  execStart = container.config.systemd.services.zomboid.serviceConfig.ExecStart;
                  user = container.config.systemd.services.zomboid.serviceConfig.User;
                  stateEnv = container.config.systemd.services.zomboid.environment.ZOMBOID_STATE_DIR;
                  privateNetwork = container.privateNetwork;
                }
              )
            );
          in
          pkgs.runCommand "nixos-module"
            {
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              fail() { echo "FAIL: $*" >&2; exit 1; }
              eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
              get() { jq -r "$1" ${json}; }

              # One game port plus one per direct connection. Getting this
              # wrong does not fail anything — the server starts, and the
              # Nth player simply cannot connect.
              eq "17000 17001 17002 17003" "$(get '.udp | join(" ")')" \
                "the game port plus one per direct-connect slot"
              eq "17000 17001 17002 17003" "$(get '.hostUdp | join(" ")')" \
                "openFirewall opens the same ports on the host"

              eq "/srv/zomboid" "$(get '.bind')" "saves live on the host, not in an ephemeral container root"
              eq "/var/lib/zomboid" "$(get '.stateEnv')" \
                "the wrapper is pointed at the same directory the volume is mounted on"
              eq "zomboid" "$(get '.user')" "the server runs unprivileged"
              eq "false" "$(get '.privateNetwork')" \
                "sharing the host netns by default — forwarding would rewrite the source address the ban list works on"

              case "$(get '.execStart')" in
                *"-servername"*"apocalypse"*) ;;
                *) fail "the configured server name never reaches the command line" ;;
              esac
              case "$(get '.execStart')" in
                *"-port"*"17000"*) ;;
                *) fail "the configured port never reaches the command line" ;;
              esac

              touch $out
            '';

        # `enable = false` must produce no container at all, rather than a
        # defined-but-stopped one that still holds the ports.
        nixos-module-disabled =
          let
            host = evalHost { services.zomboid.enable = false; };
          in
          pkgs.runCommand "nixos-module-disabled" { } ''
            fail() { echo "FAIL: $*" >&2; exit 1; }
            [ ${lib.escapeShellArg (toString (builtins.length (builtins.attrNames host.config.containers)))} = 0 ] \
              || fail "a disabled service still defined a container"
            touch $out
          '';
      };
    };
}
