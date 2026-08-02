# The launcher.
#
# Upstream ships `start-server.sh` on Linux and `StartServer.command` on macOS.
# Both cd into the install directory and run the bundled JRE, and on Linux the
# `pzexe` launcher reads ProjectZomboid64.json first. None of that survives
# being put in the Nix store: the install directory is read-only, and every
# path in that json — the classpath, `-Djava.library.path`, even the heap size
# — is relative to a working directory the server is no longer allowed to write
# to.
#
# So this skips all of it and invokes the JVM directly with absolute paths. The
# arguments are exactly the ones upstream specifies for the platform, plus the
# heap made configurable rather than frozen at 8g.
#
# ## The runtime interface
#
# Everything a deployment sets is read from the environment or from a flag, and
# none of it is baked in — this derivation carries ~7G of Steam depots, and a
# value baked into it costs a full image rebuild and re-push to change.
#
#   ZOMBOID_STATE_DIR            saves, config and logs        (see stateDir)
#   ZOMBOID_HEAP                 JVM heap                                (8g)
#   ZOMBOID_STEAM                1 or 0, the Steam networking stack
#   ZOMBOID_SERVER_NAME          names the config files, -servername (servertest)
#   ZOMBOID_CONFIG_FILE          <name>.ini fragment, merged key by key
#   ZOMBOID_CONFIG_SECRET_FILE   the same, applied after — for Password/RCONPassword
#   ZOMBOID_SANDBOX_FILE         <name>_SandboxVars.lua, copied whole
#   ZOMBOID_SPAWNREGIONS_FILE    <name>_spawnregions.lua, copied whole
#   ZOMBOID_ADMIN_USERNAME       admin account name                   (admin)
#   ZOMBOID_ADMIN_PASSWORD_FILE  without it, a FIRST boot prompts on stdin
#   ZOMBOID_STEAMCLIENT_DIR      a directory holding steamclient.so/.dylib
#
# Every one of them has a flag, and the flag wins. The flags exist for the
# `nix run` case, where there is no deployment to set an environment:
#
#   nix run github:hcbt/nixzoid -- --name knox --mod tsarslib --set MaxPlayers=16
#
# `--set`, `--mod`, `--workshop` and `--sandbox` go to `zomboid-render-config`,
# which writes the same two files the environment variables point at. So a flag
# and a hand-written file reach the server by one path, and
# `nixzoid.lib.mkServerIni` renders that file identically —
# `checks.render-config` diffs the two renderers to keep it that way.
#
# ## Steam, and why macOS defaults to off
#
# On Linux `libsteam_api.so` dlopen()s `steamclient.so`, which comes from the
# Steamworks redist (app 1007, depot 1006) and fetches anonymously. The macOS
# depot of that redist is 1005, and Steam refuses it to an anonymous account:
#
#   Depot 1005 is not available from this account.
#
# So there is no `steamclient.dylib` to ship, and macOS defaults to
# `-Dzomboid.steam=0`. The server then uses `libZNetNoSteam.dylib`, does not
# register with the Steam master server, and is reachable by direct connection
# only. `--steam` turns it back on for a host that has its own copy —
# `ZOMBOID_STEAMCLIENT_DIR` pointed at a local Steam install is enough, and
# needs no rebuild.
{
  lib,
  stdenv,
  writeShellApplication,
  zomboid-server-unwrapped,
  steamworks-sdk-redist,
  zomboid-merge-ini,
  zomboid-render-config,
  coreutils,

  # The JVM heap, as a DEFAULT — `$ZOMBOID_HEAP` and `--heap` override it.
  #
  # Upstream hard-codes -Xmx8g in ProjectZomboid64.json, and a container with a
  # lower memory limit and an 8g heap is an OOMKill waiting for the first busy
  # night. Baking it would mean rebuilding a ~7G image to retune memory, so the
  # value the deployment actually uses comes from outside.
  heapSize ? "8g",

  # Where the server keeps its state: server config, saves, logs, the Lua
  # sandbox settings. Upstream calls this the cache directory and defaults it
  # to ~/Zomboid.
  #
  # `/data` on Linux, because that is where the image and the chart mount the
  # volume. Upstream's own `$HOME/Zomboid` on darwin, because there is no
  # volume there — a Mac running `nix run` has a home directory and no `/data`,
  # and a default it cannot create is a first start that fails on mkdir.
  #
  # Passed as `-cachedir=` rather than left to $HOME: the server resolves a few
  # paths from HOME and others from the cache dir, and setting only one of them
  # scatters state across two places — one of which is usually the read-only
  # store.
  stateDir ? (if stdenv.hostPlatform.isDarwin then "$HOME/Zomboid" else "/data"),

  # The server name, as a DEFAULT — `$ZOMBOID_SERVER_NAME` and `--name`
  # override it.
  #
  # It names the config files under `Server/`, and the launcher passes it as
  # `-servername` itself so that the two cannot disagree. Upstream's default,
  # kept because changing it means the server writes a fresh config and appears
  # to have lost its settings.
  serverName ? "servertest",

  extraVmArgs ? [ ],
}:
let
  inherit (stdenv.hostPlatform) isDarwin;

  root = "${zomboid-server-unwrapped}/share/zomboid-server";

  # Where each depot puts the JVM and the JNI natives. Nothing here is a
  # preference: these are the paths the two depots actually ship.
  javaBin = if isDarwin then "jre/Contents/Home/bin/java" else "jre64/bin/java";
  nativesDir = if isDarwin then "natives" else "linux64";

  # dyld reads DYLD_LIBRARY_PATH, ld.so reads LD_LIBRARY_PATH. Same job,
  # different name, and neither platform reads the other one.
  libPathVar = if isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";

  # Whether the server registers with the Steam master server. See the header:
  # macOS has no anonymously fetchable steamclient, so it starts at 0.
  steamDefault = if isDarwin then "0" else "1";

  # Upstream's arguments, verbatim, except that the relative paths are absolute
  # and the heap is a parameter. Any divergence here is a runtime failure
  # several seconds after a successful start, so `checks.launcher-arguments`
  # asserts on the rendered script.
  #
  # -Xmx and -Dzomboid.steam are deliberately absent; both are assembled in the
  # script so that they can be overridden without a rebuild.
  vmArgs = [
    "-Djava.awt.headless=true"
    "-Dzomboid.znetlog=1"
    "-Djava.library.path=${root}/${nativesDir}"
    "-Djava.security.egd=file:/dev/urandom"
    "-XX:-OmitStackTraceInFastThrow"
  ]
  ++ lib.optionals (!isDarwin) [
    # Upstream selects ZGC in ProjectZomboid64.json, and the default collector
    # pauses a running world. StartServer.command selects no collector at all,
    # so macOS does not get one either — upstream's launcher is the spec on
    # both platforms, and guessing differently here is how a Mac ends up on a
    # GC configuration nobody has ever run the game under.
    "-XX:+UseZGC"
  ]
  ++ lib.optionals isDarwin [
    # Upstream's StartServer.command sets it. The JVM on macOS wants the main
    # thread for its Cocoa event loop, and a headless server that never opens a
    # window still goes through the same startup path.
    "-XstartOnFirstThread"
  ]
  ++ extraVmArgs;

  launcher = ''
    usage() {
      cat >&2 <<'EOF'
    usage: zomboid-server [options] [-- server arguments]

    Every option below also has an environment variable, named in brackets.
    The flag wins.

      --name NAME              server name, and the name of its config files
                               [ZOMBOID_SERVER_NAME]
      --state DIR              saves, config and logs [ZOMBOID_STATE_DIR]
      --heap SIZE              JVM heap, for example 6g [ZOMBOID_HEAP]
      --steam / --no-steam     register with the Steam master server
                               [ZOMBOID_STEAM]

      --set KEY=VALUE          one <name>.ini key, repeatable
      --mod ID                 append to Mods, repeatable
      --workshop ID            append to WorkshopItems, repeatable
      --sandbox KEY=VALUE      one SandboxVars key, repeatable.
                               A dotted KEY nests: ZombieLore.Speed=2

      --config FILE            an <name>.ini fragment, merged key by key
                               [ZOMBOID_CONFIG_FILE]
      --secret-config FILE     the same, merged after — for Password and
                               RCONPassword [ZOMBOID_CONFIG_SECRET_FILE]
      --sandbox-file FILE      a whole <name>_SandboxVars.lua
                               [ZOMBOID_SANDBOX_FILE]
      --spawnregions-file FILE a whole <name>_spawnregions.lua
                               [ZOMBOID_SPAWNREGIONS_FILE]

      --admin-username NAME    admin account name [ZOMBOID_ADMIN_USERNAME]
      --admin-password-file F  read the admin password from F. Without it a
                               FIRST start prompts on stdin
                               [ZOMBOID_ADMIN_PASSWORD_FILE]

      --print-config           render the config, print it, and do not start
    EOF
      exit 2
    }

    die() { echo "zomboid-server: $*" >&2; exit 2; }
    need() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

    state="''${ZOMBOID_STATE_DIR:-${stateDir}}"
    name="''${ZOMBOID_SERVER_NAME:-${serverName}}"
    heap="''${ZOMBOID_HEAP:-${heapSize}}"
    steam="''${ZOMBOID_STEAM:-${steamDefault}}"
    config="''${ZOMBOID_CONFIG_FILE:-}"
    secret="''${ZOMBOID_CONFIG_SECRET_FILE:-}"
    sandboxFile="''${ZOMBOID_SANDBOX_FILE:-}"
    spawnregionsFile="''${ZOMBOID_SPAWNREGIONS_FILE:-}"
    adminUser="''${ZOMBOID_ADMIN_USERNAME:-admin}"
    adminFile="''${ZOMBOID_ADMIN_PASSWORD_FILE:-}"
    render=()
    printOnly=0

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) need "$1" "$#"; name=$2; shift 2 ;;
        --state) need "$1" "$#"; state=$2; shift 2 ;;
        --heap) need "$1" "$#"; heap=$2; shift 2 ;;
        --steam) steam=1; shift ;;
        --no-steam) steam=0; shift ;;
        --set | --mod | --workshop | --sandbox)
          need "$1" "$#"; render+=("$1" "$2"); shift 2 ;;
        --config) need "$1" "$#"; config=$2; shift 2 ;;
        --secret-config) need "$1" "$#"; secret=$2; shift 2 ;;
        --sandbox-file) need "$1" "$#"; sandboxFile=$2; shift 2 ;;
        --spawnregions-file) need "$1" "$#"; spawnregionsFile=$2; shift 2 ;;
        --admin-username) need "$1" "$#"; adminUser=$2; shift 2 ;;
        --admin-password-file) need "$1" "$#"; adminFile=$2; shift 2 ;;
        --print-config) printOnly=1; shift ;;
        -h | --help) usage ;;
        # Everything after this reaches the server untouched, which is how an
        # option this launcher does not know about still gets through.
        --) shift; break ;;
        *) break ;;
      esac
    done

    # Server/ is where both config files live, and the server does not create
    # it before trying to read them.
    mkdir -p "$state" "$state/Server"

    # ---- configuration -------------------------------------------------
    #
    # All of it arrives at RUNTIME and none of it is baked into this
    # derivation. Baking it would put the mod list and the server settings
    # inside a ~7G image, so adding one mod would mean rebuilding and
    # re-pushing the whole thing. Same reasoning as the heap above.

    # Rendered outside the state directory, not into it: these are inputs to
    # this start rather than state, and a stray fragment.ini beside the saves
    # reads like something the server wrote.
    work=$(mktemp -d)
    if [ ''${#render[@]} -gt 0 ]; then
      zomboid-render-config --out "$work" "''${render[@]}"
    fi

    # A whole-file sandbox and a per-key one both write the same file, so one
    # of them would silently lose. The ini has no such problem — there the two
    # merge, in a defined order.
    if [ -n "$sandboxFile" ] && [ -e "$work/SandboxVars.lua" ]; then
      die "--sandbox-file and --sandbox both write ''${name}_SandboxVars.lua — use one of them"
    fi

    if [ "$printOnly" = 1 ]; then
      for f in "$config" "$work/fragment.ini" "$secret" "$sandboxFile" "$work/SandboxVars.lua"; do
        if [ -n "$f" ] && [ -e "$f" ]; then
          echo "# ---- $f"
          cat "$f"
        fi
      done
      rm -rf "$work"
      exit 0
    fi

    # Merged key by key rather than copied over: the server maintains ~150
    # options in this file and rewrites it as it runs, so replacing it would
    # reset every option not declared here on each restart.
    if [ -n "$config" ]; then
      zomboid-merge-ini "$config" "$state/Server/$name.ini"
    fi

    # After the file, so a flag on the command line beats the deployment's
    # declared value rather than losing to it.
    if [ -e "$work/fragment.ini" ]; then
      zomboid-merge-ini "$work/fragment.ini" "$state/Server/$name.ini"
    fi

    # Applied last, so a password out of a Kubernetes Secret or a systemd
    # credential wins over everything above — and never has to pass through the
    # world-readable Nix store to get here.
    if [ -n "$secret" ]; then
      zomboid-merge-ini "$secret" "$state/Server/$name.ini"
    fi

    # Whole-file, unlike the ini: merging Lua means parsing Lua, and a
    # line-oriented approximation corrupts a nested group instead of failing.
    # `install` rather than `cp`, for the write bit — the source may be in the
    # read-only store and the server rewrites both of these itself.
    if [ -n "$sandboxFile" ]; then
      install -m 0644 "$sandboxFile" "$state/Server/''${name}_SandboxVars.lua"
    elif [ -e "$work/SandboxVars.lua" ]; then
      install -m 0644 "$work/SandboxVars.lua" "$state/Server/''${name}_SandboxVars.lua"
    fi

    if [ -n "$spawnregionsFile" ]; then
      install -m 0644 "$spawnregionsFile" "$state/Server/''${name}_spawnregions.lua"
    fi

    # Everything above has been copied into the state directory, and the exec
    # below replaces this shell — so a trap would never fire, and this is the
    # last point at which the scratch directory can be removed.
    rm -rf "$work"

    # ---- admin account -------------------------------------------------
    #
    # With no admin in the state directory the server PROMPTS for one on stdin
    # and waits. Under systemd or in a pod there is nothing to answer it, so a
    # first boot without this hangs — with a log that ends mid-startup and
    # names nothing. Under `nix run` in a terminal the prompt is answerable,
    # which is why this stays optional rather than required.
    #
    # The password reaches the server on its command line, where the process
    # table exposes it to anything that can read it. The server offers no other
    # way in; the file itself is what stays out of the store.
    admin=()
    if [ -n "$adminFile" ]; then
      admin=(
        -adminusername "$adminUser"
        -adminpassword "$(cat "$adminFile")"
      )
    fi

    # The working directory must be the INSTALL ROOT, exactly as upstream's
    # start-server.sh and StartServer.command both arrange. The server resolves
    # its media — the animation assets, the worldgen Lua, the map data —
    # through a scan rooted here, and it is a scan rather than direct opens
    # because the game asks for lowercase logical names (`bob/bob_idle`)
    # against a tree that is actually cased (`Bob/Bob_Idle.x`).
    #
    # Running from the state directory instead, even with the whole install
    # tree symlinked into it, does not work: the scan resolves out of the base
    # directory and indexes nothing. The server then starts, and dies deep in
    # world load on whichever lookup comes first:
    #
    #   Required Animation Asset not found: bob/bob_idle
    #   attempted index: biomes of non-table: null   (WorldGenOverride.lua:4)
    #
    # Neither names a missing file, and every one of those files is present.
    #
    # The store is read-only and that is fine: the server writes nothing here.
    # Everything it persists goes to -cachedir/HOME below.
    cd ${root}

    # The server resolves several paths from HOME independently of
    # -cachedir=, so both have to agree or state lands in two places.
    export HOME="$state"

    # The JNI natives, and on Linux the Steamworks redist. `libsteam_api.so`
    # dlopen()s `steamclient.so` by bare name at runtime and ships in neither
    # depot. Without it the server starts, fails to reach the Steam master
    # server, and never appears in the in-game browser, with nothing in the log
    # that names the missing library.
    #
    # ZOMBOID_STEAMCLIENT_DIR is how a macOS host supplies its own: there is no
    # redist to ship there, so `--steam` on a Mac needs a directory holding
    # steamclient.dylib, usually inside a local Steam install.
    export ${libPathVar}="${root}/${nativesDir}:${root}${
      lib.optionalString (!isDarwin) ":${steamworks-sdk-redist}/lib"
    }''${ZOMBOID_STEAMCLIENT_DIR:+:$ZOMBOID_STEAMCLIENT_DIR}''${${libPathVar}:+:''$${libPathVar}}"

    # steam_appid.txt needs no handling: the Steam API reads it from the working
    # directory, which is now the install root, and the depot ships it there.

    exec ${root}/${javaBin} \
      "-Xmx$heap" \
      "-Dzomboid.steam=$steam" \
      ${lib.escapeShellArgs vmArgs} \
      -cp ${lib.escapeShellArg "${root}/java/.:${root}/java/projectzomboid.jar"} \
      zombie.network.GameServer \
      -cachedir="$state" \
      -servername "$name" \
      ''${admin[@]+"''${admin[@]}"} \
      "$@"
  '';
in
(writeShellApplication {
  name = "zomboid-server";
  runtimeInputs = [
    coreutils
    zomboid-merge-ini
    zomboid-render-config
  ];
  text = launcher;
}).overrideAttrs
  (old: {
    # The rendered script, reachable WITHOUT building — building would pull in
    # ~7G of Steam depots. `checks.launcher-arguments` reads this.
    passthru = (old.passthru or { }) // {
      inherit launcher vmArgs;
      unwrapped = zomboid-server-unwrapped;
    };

    meta = zomboid-server-unwrapped.meta // {
      description = "Project Zomboid dedicated server, launched directly on the bundled JVM";
      mainProgram = "zomboid-server";
    };
  })
