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
    cd "$state"

    # The server resolves several paths from HOME independently of
    # -cachedir=, so both have to agree or state lands in two places.
    export HOME="$state"

    # libsteam_api.so dlopen()s steamclient.so by bare name at runtime, and
    # ships in neither depot — it comes from the Steamworks redist (app 1007).
    # Without it the server starts, fails to reach the Steam master server, and
    # never appears in the in-game browser, with nothing in the log that names
    # the missing library.
    export LD_LIBRARY_PATH="${root}/linux64:${root}:${steamworks-sdk-redist}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # The game data has to be reachable RELATIVE TO THE WORKING DIRECTORY.
    #
    # Upstream's start-server.sh runs `cd "$INSTDIR"` first, and the server
    # leans on that: `media/` and the Lua tree are resolved against the cwd, not
    # against the classpath or any flag. Running from the state directory
    # instead gets a server that starts, finds nothing, and dies well into
    # world load:
    #
    #   Looking in these map folders:
    #   <End of map-folders list>
    #   java.lang.NullPointerException: ... "zombie.Lua.LuaManager.env" is null
    #       at zombie.iso.worldgen.WorldGenChunk.<init>(WorldGenChunk.java:82)
    #
    # An empty map-folder list and a null Lua env are the same symptom: no
    # media/. Neither names a missing directory.
    #
    # `cd`ing into the store instead is not an option — the server writes into
    # its working directory, and the store is read-only. So the install tree is
    # symlinked INTO the writable state directory, which satisfies the relative
    # lookups while leaving somewhere to write. Only names that do not already
    # exist are linked, so the server's own Saves/, Server/, Logs/ and db/ are
    # never shadowed, and a re-run is idempotent.
    for entry in ${root}/*; do
      name="$(basename "$entry")"
      [ -e "$state/$name" ] || ln -s "$entry" "$state/$name"
    done

    # The Steam API reads the app id from the working directory, not from an
    # argument. A copy rather than the symlink made above: some Steam versions
    # refuse to follow one, so this replaces it.
    rm -f "$state/steam_appid.txt"
    cp ${root}/steam_appid.txt "$state/steam_appid.txt"
    chmod u+w "$state/steam_appid.txt"

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
