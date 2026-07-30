# The Project Zomboid dedicated server, assembled from its Steam depots.
#
# App 380870 splits the server across two depots, and BOTH are required:
#
#   380871  platform-independent content — java/projectzomboid.jar, media/,
#           the Lua stdlib. ~6.9G unpacked, which is essentially all of it.
#   380873  the Linux half — the bundled Azul Zulu JRE, the JNI natives in
#           linux64/, and the pzexe launcher.
#
# Neither is useful alone: the jar is the server and the natives are what it
# dlopen()s on startup.
#
# ## Updating to a new build
#
# `manifestId` pins an exact build, which is the only way a Steam fetch can be
# a fixed-output derivation — "whatever is current" has no hash. Steam's own
# metadata API lists them, no credentials needed:
#
#   curl -s https://api.steamcmd.net/v1/info/380870 \
#     | jq '.data["380870"].depots | {"380871","380873"} | map_values(.manifests.public.gid)'
#
# Put the new gids below, set both hashes to
# `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, and build — Nix
# reports the real hash. There is no way to compute it without downloading,
# and DepotDownloader only runs on Linux, so this is a Linux-host operation.
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
  version = "42.19.0";

  # Anonymous Steam access, so no credentials are involved anywhere here.
  common = fetchSteam {
    name = "zomboid-server-common";
    appId = "380870";
    depotId = "380871";
    manifestId = "5185212962431614537";
    hash = "sha256-shjH/MO0oRBktDk75iQrn1Y8IEx8LofwBGTTZyz05WE=";
  };

  linux = fetchSteam {
    name = "zomboid-server-linux";
    appId = "380870";
    depotId = "380873";
    manifestId = "4894029153115054997";
    hash = "sha256-hgQcKlG8vhOTX1k49MyiA9BQZ2ypPDe2ElJrd4XWNYk=";
  };
in
stdenv.mkDerivation {
  pname = "zomboid-server-unwrapped";
  inherit version;

  # Two sources with no overlap, merged in installPhase. `srcs` rather than
  # `src` so neither is the "main" one and unpackPhase is skipped for both.
  srcs = [
    common
    linux
  ];

  # Prebuilt binaries: nothing to configure and nothing to build.
  dontConfigure = true;
  dontBuild = true;
  dontUnpack = true;

  nativeBuildInputs = [ autoPatchelfHook ];

  # What the JRE and the JNI natives resolve against once the interpreter is
  # rewritten. The Xorg entries look wrong for a headless server and are not:
  # the bundled JRE's libawt_xawt links them unconditionally, and an
  # unresolved NEEDED entry fails the patch phase whether or not anything ever
  # calls into it.
  buildInputs = [
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

    # Only where ELF actually lives. media/ is 6.9G of assets and scanning it
    # would dominate the build for no result.
    autoPatchelf -- "$root/linux64" "$root/jre64" "$root/ProjectZomboid64"

    # The launcher scripts arrive non-executable from the depot, and the JRE's
    # binaries lose the bit through the copy above.
    chmod +x "$root/ProjectZomboid64" "$root/start-server.sh" || true
    chmod +x "$root"/jre64/bin/* || true
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
    platforms = [ "x86_64-linux" ];
    mainProgram = "zomboid-server";
  };
}
