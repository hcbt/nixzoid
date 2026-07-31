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
{
  lib,
  stdenv,
  writeShellApplication,
  zomboid-server-unwrapped,
  steamworks-sdk-redist,
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
    mkdir -p "$state"

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

    exec ${root}/jre64/bin/java \
      "-Xmx''${ZOMBOID_HEAP:-${heapSize}}" \
      ${lib.escapeShellArgs vmArgs} \
      -cp ${lib.escapeShellArg "${root}/java/.:${root}/java/projectzomboid.jar"} \
      zombie.network.GameServer \
      -cachedir="$state" \
      "$@"
  '';
in
(writeShellApplication {
  name = "zomboid-server";
  runtimeInputs = [ coreutils ];
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
