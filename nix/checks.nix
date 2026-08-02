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

      format = import ../pkgs/zomboid-server/config-format.nix { inherit lib; };

      # The server exists on two systems and these checks run wherever the
      # developer is — so each package set under test is built explicitly
      # rather than taken from `perSystem`. Nothing here is BUILT from either:
      # every use below reads a `drvPath` or a `passthru` string, which is what
      # lets the macOS assertions run on a Linux CI runner and the Linux ones
      # run on a laptop.
      pkgsFor =
        system:
        import inputs.nixpkgs {
          inherit system;
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

      linuxPkgs = pkgsFor "x86_64-linux";
      darwinPkgs = pkgsFor "aarch64-darwin";

      # `passthru`, not the built output: building would pull ~7G of Steam
      # depots into every `nix flake check`.
      #
      # The context has to be discarded as well. The script interpolates the
      # unwrapped server's store path, so handing the string to a derivation
      # makes that path an INPUT — and Nix then downloads both depots to build a
      # check that only ever reads text.
      scriptOf = p: builtins.unsafeDiscardStringContext p.zomboid-server.launcher;
      launcherScript = scriptOf linuxPkgs;
      darwinLauncherScript = scriptOf darwinPkgs;

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
        # The one check here that RUNS the thing it tests. `zomboid-merge-ini`
        # carries no game content, so it builds and executes on any platform —
        # and the merge is the only real behaviour in this repository, the
        # piece that decides whether a restart keeps or discards what the
        # server wrote for itself.
        merge-ini =
          let
            existing = pkgs.writeText "existing.ini" ''
              # written by the server
              PublicName=old name
              MaxPlayers=8
              Mods=
              SteamPort1=8766
            '';
            # Every value here is a shape that a sed-based implementation
            # mangles: a semicolon list, an "=" inside the value, a backslash,
            # and an ampersand.
            fragment = pkgs.writeText "fragment.ini" ''
              MaxPlayers=32
              Mods=tsarslib;Brita_2
              PublicName=Knox & Co
              ServerWelcomeMessage=a=b\c
            '';
          in
          pkgs.runCommand "merge-ini" { nativeBuildInputs = [ pkgs.zomboid-merge-ini ]; } ''
            fail() { echo "FAIL: $*" >&2; cat target.ini >&2; exit 1; }
            has() { grep -qxF -- "$1" target.ini || fail "$2"; }
            count() { [ "$(grep -c -- "$1" target.ini)" = "$2" ] || fail "$3"; }

            cp ${existing} target.ini
            chmod u+w target.ini
            zomboid-merge-ini ${fragment} target.ini

            has "MaxPlayers=32" "a declared key must replace the server's value"
            has "Mods=tsarslib;Brita_2" "a semicolon-joined list must survive verbatim"
            has "PublicName=Knox & Co" "an ampersand must not be treated as a replacement reference"
            has 'ServerWelcomeMessage=a=b\c' "a value containing = and a backslash must survive verbatim"

            # The whole point of merging rather than copying: a key the server
            # keeps for itself is still there afterwards.
            has "SteamPort1=8766" "an undeclared key must be left exactly as the server wrote it"
            has "# written by the server" "comments must be preserved"

            count "^MaxPlayers=" 1 "a replaced key must not also be appended"
            count "^PublicName=" 1 "a replaced key must not also be appended"

            # A fresh state directory has no file yet, and the first start must
            # not fail on that.
            rm -f fresh.ini
            zomboid-merge-ini ${fragment} fresh.ini
            grep -qxF -- "MaxPlayers=32" fresh.ini || { echo "FAIL: a missing target must be created" >&2; exit 1; }

            # Idempotent: the launcher runs this on every start, and a second
            # pass must not accumulate duplicates.
            zomboid-merge-ini ${fragment} target.ini
            count "^Mods=" 1 "merging twice must not duplicate a key"

            touch $out
          '';

        # The two renderers. Both produce text the server parses with no error
        # reporting worth the name: a boolean spelled "1" instead of "true" is
        # read as a default, not as a mistake.
        config-format =
          let
            ini = pkgs.writeText "rendered.ini" (
              format.mkServerIni {
                PVP = false;
                PauseEmpty = true;
                MaxPlayers = 16;
                Mods = [
                  "tsarslib"
                  "Brita_2"
                ];
                WorkshopItems = [
                  "2392709985"
                  2857548524
                ];
                # Handed back to the server rather than managed.
                RCONPassword = null;
              }
            );
            sandbox = pkgs.writeText "rendered.lua" (
              format.mkSandboxVars {
                Zombies = 3;
                XpMultiplier = 1.5;
                ZombieLore = {
                  Speed = 2;
                };
                Name = ''a "quoted" one'';
              }
            );
          in
          pkgs.runCommand "config-format" { } ''
            fail() { echo "FAIL: $*" >&2; exit 1; }
            ini() { grep -qxF -- "$1" ${ini} || { cat ${ini} >&2; fail "$2"; }; }
            lua() { grep -qF -- "$1" ${sandbox} || { cat ${sandbox} >&2; fail "$2"; }; }

            # `toString true` in Nix is "1", which the server reads as a
            # default rather than as false.
            ini "PVP=false" "booleans must render lowercase, not as 0/1"
            ini "PauseEmpty=true" "booleans must render lowercase, not as 0/1"
            ini "MaxPlayers=16" "integers render bare"

            # The two halves of enabling a mod, in the separator the server
            # splits on.
            ini "Mods=tsarslib;Brita_2" "mod ids join with a semicolon"
            ini "WorkshopItems=2392709985;2857548524" "workshop ids join with a semicolon, numbers included"

            grep -q "^RCONPassword=" ${ini} && fail "a null value must drop the key, leaving it to the server"

            lua "SandboxVars = {" "the file assigns the table the server reads"
            lua "Zombies = 3," "integers render bare"
            lua "ZombieLore = {" "nested sets become nested Lua tables"
            lua 'Name = "a \"quoted\" one",' "quotes inside a string must be escaped"

            touch $out
          '';

        # Instantiation is the test: a bad `fetchSteam` argument, a missing
        # buildInput or a typo in the wrapper fails here, in seconds, without
        # fetching a byte of the game.
        packages-evaluate =
          let
            drv = p: builtins.unsafeDiscardStringContext p.drvPath;
            arg = lib.escapeShellArg;
          in
          pkgs.runCommand "packages-evaluate" { } ''
            fail() { echo "FAIL: $*" >&2; exit 1; }
            eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
            ne() { [ "$1" != "$2" ] || fail "$3"; }

            echo ${arg (drv linuxPkgs.zomboid-server-unwrapped)}
            echo ${arg (drv linuxPkgs.zomboid-server)}
            echo ${arg (drv darwinPkgs.zomboid-server-unwrapped)}
            echo ${arg (drv darwinPkgs.zomboid-server)}

            # The shared depot plus the platform half. If a refactor ever
            # dropped one, the server would build and then fail at runtime with
            # a missing jar or a missing native — the slowest possible way to
            # find out.
            eq 2 ${arg (toString (builtins.length linuxPkgs.zomboid-server-unwrapped.srcs))} \
              "the Linux server merges the common depot and its own"
            eq 2 ${arg (toString (builtins.length darwinPkgs.zomboid-server-unwrapped.srcs))} \
              "the macOS server merges the common depot and its own"

            # Different halves, or one of the two platforms is silently
            # building the other one's binaries.
            ne ${arg (drv linuxPkgs.zomboid-server-unwrapped)} \
               ${arg (drv darwinPkgs.zomboid-server-unwrapped)} \
               "the two platforms must not resolve to one derivation"

            eq "zomboid-server" ${arg linuxPkgs.zomboid-server.meta.mainProgram} \
              "the wrapper is the program consumers run"
            eq "zomboid-server" ${arg darwinPkgs.zomboid-server.meta.mainProgram} \
              "the wrapper is the program consumers run on macOS too"

            # `nix run github:hcbt/nixzoid` resolves through mainProgram on the
            # DEFAULT package, so both platforms have to declare themselves
            # supported or the run has nothing to start.
            for p in ${arg (lib.concatStringsSep " " linuxPkgs.zomboid-server.meta.platforms)}; do
              echo "supported: $p"
            done
            case " ${lib.concatStringsSep " " linuxPkgs.zomboid-server.meta.platforms} " in
              *" x86_64-linux "*) ;;
              *) fail "x86_64-linux dropped out of meta.platforms" ;;
            esac
            case " ${lib.concatStringsSep " " darwinPkgs.zomboid-server.meta.platforms} " in
              *" aarch64-darwin "*) ;;
              *) fail "aarch64-darwin dropped out of meta.platforms" ;;
            esac

            touch $out
          '';

        # The launcher replaces upstream's start-server.sh and
        # ProjectZomboid64.json, so it has to carry the same JVM arguments they
        # did. Asserting on the generated script is the only way to know: the
        # server starts happily without -Djava.library.path and then dies on
        # the first dlopen, several seconds later, with an UnsatisfiedLinkError
        # that names a class rather than the flag.
        # `writeShellApplication` runs shellcheck at BUILD time, and this
        # launcher cannot be built without ~7G of Steam depots — so on a laptop,
        # and in every check run, that lint never happens. A shell mistake in
        # the launcher would surface only in the image workflow, an hour later,
        # as a build failure with the game already downloaded.
        #
        # This lints the same text the same way, in a second, from `passthru`.
        # Both platforms. The two scripts differ in more than a variable name
        # now — the argument parser is shared, but the Steam branch and the
        # library-path export are not — so linting one of them proves nothing
        # about the other.
        launcher-shellcheck =
          pkgs.runCommand "launcher-shellcheck"
            {
              linux = launcherScript;
              darwin = darwinLauncherScript;
              passAsFile = [
                "linux"
                "darwin"
              ];
              nativeBuildInputs = [ pkgs.shellcheck ];
            }
            ''
              for script in "$linuxPath" "$darwinPath"; do
                # The preamble writeShellApplication prepends. Without it
                # shellcheck lints a fragment with no shell dialect and no
                # `set -u`, which is not what actually runs.
                {
                  printf '#!/usr/bin/env bash\nset -o errexit\nset -o nounset\nset -o pipefail\n'
                  cat "$script"
                } > launcher.sh

                shellcheck launcher.sh
              done

              touch $out
            '';

        launcher-arguments =
          pkgs.runCommand "launcher-arguments"
            {
              linux = launcherScript;
              darwin = darwinLauncherScript;
              passAsFile = [
                "linux"
                "darwin"
              ];
            }
            ''
              fail() { echo "FAIL: $*" >&2; exit 1; }
              # Asserted against BOTH scripts unless a check says otherwise.
              # Everything below this line that differs by platform is in the
              # per-platform block at the end.
              has() { for s in "$linuxPath" "$darwinPath"; do grep -qF -- "$1" "$s" || fail "$2 ($s)"; done; }

              has "-Djava.awt.headless=true" "a headless server must not try to open a display"
              has "-Djava.library.path=" "the JNI natives are found through java.library.path, or the server dies on first dlopen"
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

              # HOME and -cachedir= must agree. The server resolves some paths
              # from each, so setting only one scatters state across two
              # directories — one of them inside the store.
              has 'export HOME=' "HOME must be redirected alongside -cachedir="

              # Config and mods arrive at runtime, never baked in. Baking them
              # would put the mod list inside a ~7G image, so adding one mod
              # would cost a rebuild and a re-push — the same reason the heap
              # is an environment variable.
              has 'ZOMBOID_CONFIG_FILE' "the server config has to be supplied at runtime, not built in"
              has 'ZOMBOID_SANDBOX_FILE' "the sandbox settings have to be supplied at runtime"
              has 'ZOMBOID_SERVER_NAME' "the server name has to be supplied at runtime"

              # The secret fragment is applied AFTER the declarative one and
              # after the flags, or a store-rendered empty Password= would
              # overwrite the real one. Ordering is checked on the MERGE calls,
              # not on the first mention of each variable — the parser reads
              # all of them at the top, in an order that means nothing.
              for s in "$linuxPath" "$darwinPath"; do
                frag=$(grep -n 'zomboid-merge-ini "\$config"' "$s" | head -1 | cut -d: -f1)
                flags=$(grep -n 'zomboid-merge-ini "\$work/fragment.ini"' "$s" | head -1 | cut -d: -f1)
                secret=$(grep -n 'zomboid-merge-ini "\$secret"' "$s" | head -1 | cut -d: -f1)
                [ -n "$frag" ] && [ -n "$flags" ] && [ -n "$secret" ] \
                  || fail "all three ini fragments must be merged, not just some of them ($s)"
                [ "$flags" -gt "$frag" ] \
                  || fail "a --set flag must be merged after the declared file, or the flag loses to it ($s)"
                [ "$secret" -gt "$flags" ] \
                  || fail "the secret config fragment must be merged last, or it loses to the others ($s)"
              done

              # Merged, not copied. A copy would reset every option the server
              # maintains for itself on each restart.
              has 'zomboid-merge-ini' "the ini is merged into the server's own, not written over it"

              # The flags exist for `nix run`, where there is no deployment to
              # set an environment. A flag that never reaches the renderer is
              # an option that parses and then does nothing.
              has 'zomboid-render-config' "the --set/--mod/--sandbox flags have to reach the renderer"
              has '--print-config' "rendering must be inspectable without starting a ~7G server"

              # Without an admin password a FIRST start blocks on an
              # interactive prompt that nothing in a container answers.
              has 'ZOMBOID_ADMIN_PASSWORD_FILE' "a first start needs a non-interactive admin password"
              has '-adminpassword' "the admin password reaches the server as a command-line argument"

              # The launcher owns -servername, so the name the config files are
              # called cannot drift from the name the server is told — the
              # image entrypoint passes no arguments at all.
              has '-servername' "the launcher supplies the server name itself"

              # ---- per platform ------------------------------------------
              #
              # Every one of these is a path or a flag the OTHER platform does
              # not have. Getting one wrong produces a server that starts and
              # then dies on the first dlopen, or does not start at all with an
              # error naming the JVM rather than the file.
              only() { grep -qF -- "$2" "$1" || fail "$3 ($1)"; }
              never() { grep -qF -- "$2" "$1" && fail "$3 ($1)"; true; }

              only "$linuxPath" "jre64/bin/java" "the Linux depot puts the JVM in jre64/"
              only "$linuxPath" "/linux64" "the Linux depot puts the JNI natives in linux64/"
              only "$linuxPath" "LD_LIBRARY_PATH" "steamclient.so is resolved through LD_LIBRARY_PATH"
              only "$linuxPath" "ZOMBOID_STEAM:-1" "Linux ships steamclient.so, so Steam networking defaults on"
              only "$linuxPath" "-XX:+UseZGC" "upstream selects ZGC; the default collector pauses a running world"
              never "$linuxPath" "-XstartOnFirstThread" "a macOS-only JVM flag would abort the JVM on Linux"

              only "$darwinPath" "jre/Contents/Home/bin/java" "the macOS depot puts the JVM in jre/Contents/Home"
              only "$darwinPath" "/natives" "the macOS depot puts the JNI natives in natives/"
              only "$darwinPath" "DYLD_LIBRARY_PATH" "dyld does not read LD_LIBRARY_PATH"
              only "$darwinPath" "-XstartOnFirstThread" "upstream's StartServer.command sets it"
              # Depot 1005, the macOS Steamworks redist, is not available to an
              # anonymous account — so there is no steamclient.dylib to ship
              # and the server has to start on libZNetNoSteam.dylib instead.
              only "$darwinPath" "ZOMBOID_STEAM:-0" "macOS has no shippable steamclient, so Steam networking defaults off"
              only "$darwinPath" "ZOMBOID_STEAMCLIENT_DIR" "a Mac with its own Steam install must be able to turn Steam back on"
              # `steamworks-sdk-redist` is a Linux-only package. Interpolating
              # its path into the darwin script would make it a dependency of a
              # macOS build, which then fails on a package that installs
              # nothing there.
              never "$darwinPath" "steamworks-sdk-redist" "the Linux-only Steamworks redist must not reach the macOS launcher"
              never "$darwinPath" "-XX:+UseZGC" "StartServer.command selects no collector, so neither does this"

              touch $out
            '';

        # The two renderers of one format, diffed.
        #
        # `config-format.nix` runs at EVALUATION time and serves the NixOS
        # module and the Helm values. `zomboid-render-config` runs at RUNTIME
        # and serves the flags, because `nix run … -- --mod tsarslib` has no
        # evaluation left by the time the flag is read. Two renderers of one
        # format drift, and the drift is invisible: both produce a file the
        # server parses, and a setting spelled differently is read as a default
        # rather than as an error.
        #
        # So they are diffed, byte for byte, on the values whose spellings are
        # not obvious — a list, a boolean, a float, a nested group and a string
        # holding the quote character the Lua needs escaped.
        render-config =
          let
            settings = {
              MaxPlayers = 16;
              PVP = false;
              PauseEmpty = true;
              Mods = [
                "tsarslib"
                "Brita_2"
              ];
              WorkshopItems = [
                "2392709985"
                "2857548524"
              ];
            };
            vars = {
              Zombies = 3;
              XpMultiplier = 1.5;
              ZombieLore.Speed = 2;
              Name = ''a "quoted" one'';
            };
          in
          pkgs.runCommand "render-config"
            {
              nativeBuildInputs = [ pkgs.zomboid-render-config ];
              nixIni = format.mkServerIni settings;
              nixLua = format.mkSandboxVars vars;
              passAsFile = [
                "nixIni"
                "nixLua"
              ];
            }
            ''
              fail() { echo "FAIL: $*" >&2; exit 1; }

              zomboid-render-config --out cli \
                --set MaxPlayers=16 \
                --set PVP=false \
                --set PauseEmpty=true \
                --mod tsarslib --mod Brita_2 \
                --workshop 2392709985 --workshop 2857548524 \
                --sandbox Zombies=3 \
                --sandbox XpMultiplier=1.5 \
                --sandbox ZombieLore.Speed=2 \
                --sandbox 'Name=a "quoted" one'

              diff -u "$nixIniPath" cli/fragment.ini \
                || fail "the flag renderer and mkServerIni disagree"
              diff -u "$nixLuaPath" cli/SandboxVars.lua \
                || fail "the flag renderer and mkSandboxVars disagree"

              # Neither file is written when nothing feeds it. The launcher
              # tests for their existence to decide whether to merge, so a
              # renderer that always wrote them would merge an empty fragment
              # over the server's own ini on every start.
              zomboid-render-config --out empty
              [ -e empty/fragment.ini ] && fail "an ini with no keys must not be written at all"
              [ -e empty/SandboxVars.lua ] && fail "a sandbox with no keys must not be written at all"

              # Two spellings of one key. Picking a winner silently is how half
              # a mod list goes missing.
              zomboid-render-config --out conflict --mod a --set Mods=b 2>/dev/null \
                && fail "--mod and --set Mods= together must be an error"

              # A key cannot be a value and a group at once. The Lua would
              # parse either way, so the server would load it and take defaults
              # for the whole group without saying so.
              zomboid-render-config --out nested --sandbox A=1 --sandbox A.B=2 2>/dev/null \
                && fail "a sandbox key used as both a value and a group must be an error"

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

                workshopItems = [
                  "2392709985"
                  "2857548524"
                ];
                mods = [
                  "tsarslib"
                  "Brita_2"
                ];
                settings = {
                  MaxPlayers = 16;
                  PVP = false;
                };
                sandbox.Zombies = 3;

                adminPasswordFile = "/run/secrets/zomboid-admin";
                secretConfigFile = "/run/secrets/zomboid-config";
              };
            };
            container = host.config.containers.zomboid;
            env = container.config.systemd.services.zomboid.environment;

            # Built, unlike everything else here — these are a few hundred
            # bytes of text and carry no dependency on the depots. Reading them
            # is what proves the module's options reach the running server
            # rather than merely rendering somewhere.
            renderedIni = env.ZOMBOID_CONFIG_FILE;
            renderedSandbox = env.ZOMBOID_SANDBOX_FILE;
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
                  stateEnv = env.ZOMBOID_STATE_DIR;
                  nameEnv = env.ZOMBOID_SERVER_NAME;
                  secretEnv = env.ZOMBOID_CONFIG_SECRET_FILE;
                  adminEnv = env.ZOMBOID_ADMIN_PASSWORD_FILE;
                  privateNetwork = container.privateNetwork;
                  mounts = lib.mapAttrs (_: m: {
                    inherit (m) hostPath isReadOnly;
                  }) container.bindMounts;
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
                *"-port"*"17000"*) ;;
                *) fail "the configured port never reaches the command line" ;;
              esac

              # The name goes through the environment, not the command line, so
              # that the image entrypoint — which takes no arguments — behaves
              # the same as the systemd unit.
              eq "apocalypse" "$(get '.nameEnv')" "the configured server name has to reach the launcher"

              # Both halves of enabling a mod, in one file. Only one of them
              # present is the failure that looks like the mod simply not
              # working.
              grep -qxF 'Mods=tsarslib;Brita_2' ${renderedIni} \
                || { cat ${renderedIni} >&2; fail "the mod ids never reach the rendered config"; }
              grep -qxF 'WorkshopItems=2392709985;2857548524' ${renderedIni} \
                || { cat ${renderedIni} >&2; fail "the workshop ids never reach the rendered config"; }
              grep -qxF 'MaxPlayers=16' ${renderedIni} \
                || { cat ${renderedIni} >&2; fail "settings never reach the rendered config"; }
              grep -qF 'Zombies = 3' ${renderedSandbox} \
                || { cat ${renderedSandbox} >&2; fail "sandbox settings never reach the rendered lua"; }

              # Secrets are passed by path and stay on the host. Rendering them
              # into the ini would put them in the world-readable store.
              eq "/run/secrets/zomboid-config" "$(get '.secretEnv')" "the secret fragment is passed by path"
              eq "/run/secrets/zomboid-admin" "$(get '.adminEnv')" "the admin password is passed by path"
              grep -q "run/secrets" ${renderedIni} && fail "a secret path must not be rendered into the store"

              # coldstart merges extraContainerConfig with `//`, so declaring
              # bindMounts there REPLACES its own. Losing the state mount would
              # put the saves in the container's ephemeral root and a restart
              # would quietly discard them.
              eq "/srv/zomboid" "$(get '.mounts["/var/lib/zomboid"].hostPath')" \
                "adding secret mounts must not drop the state mount"
              eq "false" "$(get '.mounts["/var/lib/zomboid"].isReadOnly')" \
                "the state mount stays writable"
              eq "true" "$(get '.mounts["/run/secrets/zomboid-admin"].isReadOnly')" \
                "secrets are mounted read-only"

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
