# The launcher.
#
# Upstream ships `start-server.sh`, which cd's into the install directory and
# runs the `pzexe` launcher, which in turn reads ProjectZomboid64.json and
# execs the bundled JRE. None of that survives being put in the Nix store: the
# install directory is read-only, and every path in that json — the classpath,
# `-Djava.library.path`, even the heap size — is relative to a working
# directory the server is no longer allowed to write to.
#
# So this skips both and invokes the JVM directly with absolute paths. The
# arguments are exactly the ones ProjectZomboid64.json specifies, plus the heap
# made configurable rather than frozen at upstream's 8g.
#
# ## The runtime interface
#
# Everything a deployment sets is read from the environment, never baked in —
# this derivation carries ~7G of Steam depots, and a value baked into it costs a
# full image rebuild and re-push to change.
#
#   ZOMBOID_STATE_DIR            saves, config and logs                (/data)
#   ZOMBOID_HEAP                 JVM heap                              (8g)
#   ZOMBOID_SERVER_NAME          names the config files, -servername   (servertest)
#   ZOMBOID_CONFIG_FILE          <name>.ini fragment, merged key by key
#   ZOMBOID_CONFIG_SECRET_FILE   the same, applied after — for Password/RCONPassword
#   ZOMBOID_SANDBOX_FILE         <name>_SandboxVars.lua, copied whole
#   ZOMBOID_SPAWNREGIONS_FILE    <name>_spawnregions.lua, copied whole
#   ZOMBOID_ADMIN_USERNAME       admin account name                    (admin)
#   ZOMBOID_ADMIN_PASSWORD_FILE  without it, a FIRST boot hangs on a prompt
#
# `nixzoid.lib.mkServerIni` and `mkSandboxVars` render the two files; the NixOS
# module and the Helm values are both meant to go through them.
{
  lib,
  stdenv,
  writeShellApplication,
  zomboid-server-unwrapped,
  steamworks-sdk-redist,
  zomboid-merge-ini,
  coreutils,

  # The JVM heap, as a DEFAULT — `$ZOMBOID_HEAP` overrides it at runtime.
  #
  # Upstream hard-codes -Xmx8g in ProjectZomboid64.json, and a container with a
  # lower memory limit and an 8g heap is an OOMKill waiting for the first busy
  # night. Baking it would mean rebuilding a ~7G image to retune memory, so the
  # value the deployment actually uses comes from the environment.
  heapSize ? "8g",

  # Where the server keeps its state: server config, saves, logs, the Lua
  # sandbox settings. Upstream calls this the cache directory and defaults it
  # to ~/Zomboid.
  #
  # Passed as `-cachedir=` rather than left to $HOME: the server resolves a few
  # paths from HOME and others from the cache dir, and setting only one of them
  # scatters state across two places — one of which is usually the read-only
  # store.
  stateDir ? "/data",

  # The server name, as a DEFAULT — `$ZOMBOID_SERVER_NAME` overrides it.
  #
  # It names the config files under `Server/`, and the launcher passes it as
  # `-servername` itself so that the two cannot disagree. Upstream's default,
  # kept because changing it means the server writes a fresh config and appears
  # to have lost its settings.
  serverName ? "servertest",

  extraVmArgs ? [ ],
}:
let
  root = "${zomboid-server-unwrapped}/share/zomboid-server";

  # Upstream's ProjectZomboid64.json, verbatim, except that the relative paths
  # are absolute and the heap is a parameter. Any divergence here is a runtime
  # failure several seconds after a successful start, so `checks.launcher-arguments`
  # asserts on the rendered script.
  # -Xmx is deliberately absent here; it is assembled in the script so that
  # $ZOMBOID_HEAP can override it without a rebuild.
  vmArgs = [
    "-Djava.awt.headless=true"
    "-Dzomboid.steam=1"
    "-Dzomboid.znetlog=1"
    "-Djava.library.path=${root}/linux64"
    "-Djava.security.egd=file:/dev/urandom"
    "-XX:+UseZGC"
    "-XX:-OmitStackTraceInFastThrow"
  ]
  ++ extraVmArgs;

  launcher = ''
    state="''${ZOMBOID_STATE_DIR:-${stateDir}}"
    name="''${ZOMBOID_SERVER_NAME:-${serverName}}"

    # Server/ is where both config files live, and the server does not create
    # it before trying to read them.
    mkdir -p "$state" "$state/Server"

    # The working directory must be the INSTALL ROOT, exactly as upstream's
    # start-server.sh arranges with `cd "$INSTDIR"`. The server resolves its
    # media — the animation assets, the worldgen Lua, the map data — through a
    # scan rooted here, and it is a scan rather than direct opens because the
    # game asks for lowercase logical names (`bob/bob_idle`) against a tree that
    # is actually cased (`Bob/Bob_Idle.x`).
    #
    # Running from the state directory instead, even with the whole install tree
    # symlinked into it, does not work: the scan resolves out of the base
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

    # libsteam_api.so dlopen()s steamclient.so by bare name at runtime, and
    # ships in neither depot — it comes from the Steamworks redist (app 1007).
    # Without it the server starts, fails to reach the Steam master server, and
    # never appears in the in-game browser, with nothing in the log that names
    # the missing library.
    export LD_LIBRARY_PATH="${root}/linux64:${root}:${steamworks-sdk-redist}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # steam_appid.txt needs no handling: the Steam API reads it from the working
    # directory, which is now the install root, and the depot ships it there.

    # ---- configuration -------------------------------------------------
    #
    # All of it arrives at RUNTIME, through the environment, and none of it is
    # baked into this derivation. Baking it would put the mod list and the
    # server settings inside a ~7G image, so adding one mod would mean
    # rebuilding and re-pushing the whole thing. Same reasoning as the heap
    # above.

    # Merged key by key rather than copied over: the server maintains ~150
    # options in this file and rewrites it as it runs, so replacing it would
    # reset every option not declared in Nix on each restart.
    if [ -n "''${ZOMBOID_CONFIG_FILE:-}" ]; then
      zomboid-merge-ini "$ZOMBOID_CONFIG_FILE" "$state/Server/$name.ini"
    fi

    # Applied after, so a password out of a Kubernetes Secret or a systemd
    # credential wins over anything the declarative half set — and never has to
    # pass through the world-readable Nix store to get here.
    if [ -n "''${ZOMBOID_CONFIG_SECRET_FILE:-}" ]; then
      zomboid-merge-ini "$ZOMBOID_CONFIG_SECRET_FILE" "$state/Server/$name.ini"
    fi

    # Whole-file, unlike the ini: merging Lua means parsing Lua, and a
    # line-oriented approximation corrupts a nested group instead of failing.
    # `install` rather than `cp`, for the write bit — the source is in the
    # read-only store and the server rewrites both of these itself.
    if [ -n "''${ZOMBOID_SANDBOX_FILE:-}" ]; then
      install -m 0644 "$ZOMBOID_SANDBOX_FILE" "$state/Server/''${name}_SandboxVars.lua"
    fi

    if [ -n "''${ZOMBOID_SPAWNREGIONS_FILE:-}" ]; then
      install -m 0644 "$ZOMBOID_SPAWNREGIONS_FILE" "$state/Server/''${name}_spawnregions.lua"
    fi

    # ---- admin account -------------------------------------------------
    #
    # With no admin in the state directory the server PROMPTS for one on stdin
    # and waits. Under systemd or in a pod there is nothing to answer it, so a
    # first boot without this hangs — with a log that ends mid-startup and
    # names nothing.
    #
    # The password reaches the server on its command line, where /proc exposes
    # it to anything that can read the process table. The server offers no
    # other way in; the file itself is what stays out of the store.
    admin=()
    if [ -n "''${ZOMBOID_ADMIN_PASSWORD_FILE:-}" ]; then
      admin=(
        -adminusername "''${ZOMBOID_ADMIN_USERNAME:-admin}"
        -adminpassword "$(cat "$ZOMBOID_ADMIN_PASSWORD_FILE")"
      )
    fi

    exec ${root}/jre64/bin/java \
      "-Xmx''${ZOMBOID_HEAP:-${heapSize}}" \
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
      platforms = [ "x86_64-linux" ];
      mainProgram = "zomboid-server";
      broken = !stdenv.hostPlatform.isLinux;
    };
  })
