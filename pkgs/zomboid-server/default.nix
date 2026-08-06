# The Project Zomboid dedicated server, assembled from its Steam depots.
#
# App 380870 splits the server across a shared depot and one per platform, and
# TWO of them are always required:
#
#   380871  platform-independent content — java/projectzomboid.jar, media/,
#           the Lua stdlib. ~6.9G unpacked, which is essentially all of it.
#   380873  the Linux half — the bundled Azul Zulu JRE, the JNI natives in
#           linux64/, and the pzexe launcher.
#   380872  the macOS half — an arm64 Azul Zulu JRE under jre/Contents/Home,
#           and universal x86_64+arm64 JNI natives in natives/. 205M.
#
# Neither half is useful alone: the jar is the server and the natives are what
# it dlopen()s on startup.
#
# ## Platforms
#
# `x86_64-linux` and `aarch64-darwin`. There is no `x86_64-darwin`: the macOS
# depot's `jre/Contents/Home/bin/java` is a thin arm64 Mach-O, so an Intel Mac
# has no JVM to run even though the natives themselves are universal.
#
# ## Updating to a new build
#
# `manifestId` pins an exact build, which is the only way a Steam fetch can be
# a fixed-output derivation — "whatever is current" has no hash. All three move
# together, because all three come out of one app build. Steam's own metadata
# API lists them, no credentials needed:
#
#   curl -s https://api.steamcmd.net/v1/info/380870 \
#     | jq '.data["380870"].depots | {"380871","380872","380873"} | map_values(.manifests.public.gid)'
#
# Put the new gids below, set the hashes to
# `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, and build — Nix
# reports the real hash. There is no way to compute it without downloading.
# A depot fetch is content-addressed, so the COMMON depot's hash can be taken
# on either host. Only the platform halves need their own.
#
# ## This is not optional maintenance
#
# Steam stops serving an old manifest to ANONYMOUS accounts once the app moves
# on. The pin does not go stale quietly — it goes 401:
#
#   No manifest request code was returned for depot 380871 ...
#   Suggestion: Try logging in with -username as old manifests may not be
#   available for anonymous accounts.
#   Encountered 401 for depot manifest 380871 5185212962431614537. Aborting.
#
# Nothing in `checks` can see this coming: the depots are never fetched there.
# The image workflow is what finds it, and it finds it as a build that worked
# last week and does not today, with no local change to explain it.
#
# The three ids also move INDEPENDENTLY. 380871 rotated on its own here while
# both platform halves stayed put, and the version string moved with it —
# 42.20.0 to 42.20.2 — because the jar lives in the shared depot.
{
  lib,
  stdenv,
  fetchSteam,
  autoPatchelfHook,
  zlib,
  alsa-lib,
  freetype,
  fontconfig,
  libGL,
  xorg,
}:
let
  # The build the manifests below actually contain, not the one they were
  # first labelled with. The server prints it at startup —
  # `version=42.20.0 a2947723ca` — and that line is the only authority: a
  # manifest id carries no version, so this string is maintained by hand and
  # drifts silently when it is not.
  version = "42.20.2";

  # Anonymous Steam access, so no credentials are involved anywhere here.
  common = fetchSteam {
    name = "zomboid-server-common";
    appId = "380870";
    depotId = "380871";
    manifestId = "2587362105419356756";
    hash = "sha256-pI7is306I6iHV/6ABuCGEI9EXtBuZYMOCaFLO4GSIew=";
  };

  # The platform half, keyed by system. Kept as one table rather than one file
  # per platform: the manifest ids are bumped together, and splitting them
  # across files is how one of them gets left on the previous build.
  platformDepots = {
    x86_64-linux = {
      depotId = "380873";
      manifestId = "4894029153115054997";
      hash = "sha256-hgQcKlG8vhOTX1k49MyiA9BQZ2ypPDe2ElJrd4XWNYk=";
    };
    aarch64-darwin = {
      depotId = "380872";
      manifestId = "918325764650181813";
      hash = "sha256-wLkOE+q9p+LW+9BogqqFtRPvZhfqIqfxMMCDFRHUiCo=";
    };
  };

  inherit (stdenv.hostPlatform) system;

  spec =
    platformDepots.${system}
      or (throw "nixzoid: the Zomboid dedicated server has no Steam depot for ${system}");

  platform = fetchSteam {
    name = "zomboid-server-${system}";
    appId = "380870";
    inherit (spec) depotId manifestId hash;
  };
in
stdenv.mkDerivation {
  pname = "zomboid-server-unwrapped";
  inherit version;

  # Two sources with no overlap, merged in installPhase. `srcs` rather than
  # `src` so neither is the "main" one and unpackPhase is skipped for both.
  srcs = [
    common
    platform
  ];

  # Prebuilt binaries: nothing to configure and nothing to build.
  dontConfigure = true;
  dontBuild = true;
  dontUnpack = true;

  # Every Mach-O in the macOS depot carries a signature — ad-hoc on the PZ
  # natives, an Azul certificate with the hardened runtime on the JRE. `strip`
  # rewrites the load commands and invalidates it, and macOS then refuses to
  # load the library with a SIGKILL that names no file. There is nothing to
  # strip here in any case: these are vendor binaries, not a local build.
  dontStrip = stdenv.hostPlatform.isDarwin;

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  # What the JRE and the JNI natives resolve against once the interpreter is
  # rewritten. The Xorg entries look wrong for a headless server and are not:
  # the bundled JRE's libawt_xawt links them unconditionally, and an
  # unresolved NEEDED entry fails the patch phase whether or not anything ever
  # calls into it.
  #
  # Linux only, and not because darwin needs different libraries — it needs
  # none. A Mach-O binary names its dependencies by absolute path or by
  # @rpath, and everything the macOS depot links lives in /usr/lib, which is
  # the dyld shared cache rather than a file. So nothing has to be rewritten,
  # and nothing has to be supplied.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    zlib
    alsa-lib
    freetype
    fontconfig
    libGL
    xorg.libX11
    xorg.libXext
    xorg.libXrender
    xorg.libXtst
    xorg.libXi
    xorg.libXxf86vm
    xorg.libXcursor
    xorg.libXrandr
    # libPZXInitThreads64.so links the X11 session-management pair. It is a
    # client-side concern that a headless server never calls into, but an
    # unresolved NEEDED entry fails the patch phase regardless of whether the
    # symbol is ever used — and these two are a few hundred kilobytes.
    xorg.libSM
    xorg.libICE
  ];

  # The default hook walks the WHOLE output, and this output is ~7G of game
  # assets with a few megabytes of ELF in it. Patching is driven explicitly in
  # postFixup instead, over just the directories that hold binaries.
  dontAutoPatchelf = true;

  # Client-only natives ship in the server depot and reference libraries a
  # headless server has no reason to carry (OpenAL, the full GL stack). They
  # are never dlopen()ed by `zombie.network.GameServer`, so an unresolved
  # NEEDED entry in one of them must not fail the build.
  autoPatchelfIgnoreMissingDeps = [
    "libopenal.so.1"
    "libSDL2-2.0.so.0"
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/zomboid-server
    for src in $srcs; do
      cp -r --no-preserve=mode,ownership "$src"/. $out/share/zomboid-server/
    done

    runHook postInstall
  '';

  postFixup = ''
    root=$out/share/zomboid-server
  ''
  + lib.optionalString stdenv.hostPlatform.isLinux ''
    # Only where ELF actually lives. media/ is 6.9G of assets and scanning it
    # would dominate the build for no result.
    autoPatchelf -- "$root/linux64" "$root/jre64" "$root/ProjectZomboid64"

    # The launcher scripts arrive non-executable from the depot, and the JRE's
    # binaries lose the bit through the copy above.
    chmod +x "$root/ProjectZomboid64" "$root/start-server.sh" || true
    chmod +x "$root"/jre64/bin/* || true
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    # The same bit, in the paths the macOS depot uses. Nothing else happens
    # here: patching a Mach-O would break the signature this build goes out
    # of its way to preserve.
    chmod +x "$root/StartServer.command" || true
    chmod +x "$root"/jre/Contents/Home/bin/* || true
  '';

  meta = {
    description = "Project Zomboid dedicated server";
    homepage = "https://steamdb.info/app/380870/";
    changelog = "https://store.steampowered.com/news/app/108600?updates=true";
    sourceProvenance = with lib.sourceTypes; [
      binaryNativeCode
      binaryBytecode
    ];
    # Not redistributable. The image built from this must not be published to a
    # public registry — see the README.
    license = lib.licenses.unfree;
    platforms = lib.attrNames platformDepots;
    mainProgram = "zomboid-server";
  };
}
