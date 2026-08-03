# Fetching Steam Workshop items, and installing them where the server looks.
#
#   zomboid-workshop --cache DIR --mods-dir DIR [--id ID[,ID...]]... [--offline]
#
# Downloads each workshop item, installs the mods it carries into the mods
# directory, and prints the mod ids it installed — one per line, on stdout, for
# the launcher to feed back into `Mods=`. DepotDownloader's own output goes to
# stderr, so stdout carries nothing but ids.
#
# ## Why the server cannot do this itself
#
# The server downloads `WorkshopItems` through Steam, and on macOS there is no
# Steam to download with: depot 1005, the macOS Steamworks redist, is not
# available to an anonymous account, so there is no `steamclient.dylib` to ship.
#
# A local Steam install lends one, and that IS enough for Steam networking —
# `--steam` with `ZOMBOID_STEAMCLIENT_DIR` reaches `*** Steam is enabled`. It is
# not enough for downloading. A borrowed `steamclient.dylib` has no Steam
# library directory to install into, so the query succeeds, the download fails
# with `Install library folder not found`, and the server dies on a
# NullPointerException in `GameServerWorkshopItems.Install` rather than starting
# without the mod.
#
# That path is only reached when `WorkshopItems=` is set. This installer is why
# `--workshop` never sets it, and therefore why `--steam` on macOS is usable at
# all.
#
# DepotDownloader has no such problem. `-app 108600 -pubfile <id>` fetches a
# published workshop file anonymously, needing no Steam client, no account and
# no Steam networking — the same anonymous access `fetchSteam` already uses for
# the game itself.
#
# ## Where mods go, and what shape they have to be in
#
# `ZomboidFileSystem.getAllModFolders` searches `workshop`, `steam` and `mods`
# in that order, and the `mods` root is `Core.getMyDocumentFolder() + "/mods"` —
# the `-cachedir` the launcher passes. So installing into `$state/mods` reaches
# the server without Steam being involved at all.
#
# Build 42 changed the layout, and `getAllModFoldersAux` SKIPS a folder that
# does not match, silently:
#
#   if (!Files.exists(path.resolve("common", "mod.info"))
#    && !Files.exists(path.resolve(versionDirName, "mod.info"))) continue;
#
# So `mod.info` lives in `<mod>/common/` or `<mod>/42/`, never at the mod root.
# A build 41 mod has it at the root and is skipped — which reads as "required
# mod not found" and is a mod that has not been updated, not a broken install.
# Nothing here rewrites that layout: the workshop item is installed exactly as
# published, and a mod that does not support this build is the author's to fix.
{
  writeShellApplication,
  depotdownloader,
  coreutils,
  findutils,
  gnugrep,
}:
writeShellApplication {
  name = "zomboid-workshop";
  runtimeInputs = [
    depotdownloader
    coreutils
    findutils
    gnugrep
  ];
  text = ''
    die() { echo "zomboid-workshop: $*" >&2; exit 2; }
    need() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

    # `--id 1,2` and `--id 1 --id 2` are the same thing, and so is `--id "1, 2"`
    # with a space after the comma, which is what a person actually types. A
    # workshop id is a decimal number and can hold neither separator, so
    # splitting on both is unambiguous.
    #
    # Splitting HERE rather than in the launcher is what makes it testable: the
    # launcher cannot be built without ~7G of Steam depots, and this can.
    parts=()
    split() { read -r -a parts <<< "''${1//,/ }"; }

    # The GAME, not the dedicated server. Workshop items are published against
    # 108600; 380870 has none and returns nothing.
    APPID=108600

    cache=""
    modsDir=""
    ids=()
    offline=0

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cache) need "$1" "$#"; cache=$2; shift 2 ;;
        --mods-dir) need "$1" "$#"; modsDir=$2; shift 2 ;;
        --id)
          need "$1" "$#"
          split "$2"
          ids+=(''${parts[@]+"''${parts[@]}"})
          shift 2
          ;;
        # Reuse whatever is already downloaded and contact Steam for nothing.
        # A restart with no network, and a check with no network, both need it.
        --offline) offline=1; shift ;;
        *) die "unknown option '$1'" ;;
      esac
    done

    [ -n "$cache" ] || die "--cache is required"
    [ -n "$modsDir" ] || die "--mods-dir is required"
    [ ''${#ids[@]} -gt 0 ] || exit 0

    mkdir -p "$cache" "$modsDir"

    for id in "''${ids[@]}"; do
      case "$id" in
        *[!0-9]* | "") die "workshop id '$id' is not a number" ;;
      esac

      item="$cache/$id"

      if [ "$offline" = 1 ]; then
        [ -d "$item" ] || die "--offline, but workshop item $id has never been downloaded"
      else
        # DepotDownloader compares the manifest against what is already in the
        # directory, so a restart re-checks rather than re-downloads. Its
        # progress goes to stderr: stdout is the mod-id channel.
        DepotDownloader -app "$APPID" -pubfile "$id" -dir "$item" >&2 \
          || die "could not download workshop item $id"
      fi

      # A workshop item is a `mods/` directory holding one or more mods. More
      # than one is normal — several mods published as a single item — so this
      # installs every one rather than assuming a single folder named after the
      # item.
      #
      # A Workshop COLLECTION has an id too, and downloads to nothing but its
      # thumbnail. That is the likeliest way to land here, so the message says
      # so rather than leaving a mod id that looks correct and fetches nothing.
      if [ ! -d "$item/mods" ]; then
        die "workshop item $id carries no mods/ directory. If that id is a Workshop COLLECTION rather than a single item, list its members instead — a collection has no mods of its own."
      fi

      for src in "$item"/mods/*; do
        [ -d "$src" ] || continue
        name=$(basename "$src")

        # Replaced rather than merged. A mod that drops a file between versions
        # would otherwise keep the old one, and a stale Lua file in a mod is a
        # runtime error deep in world load rather than a missing-file message.
        rm -rf "''${modsDir:?}/$name"
        cp -r "$src" "$modsDir/$name"
        # The store is not involved here, but a depot arrives read-only and the
        # server rewrites nothing in a mod — the write bit is for the next
        # install replacing it.
        chmod -R u+w "$modsDir/$name"

        # `Mods=` takes the `id=` field from mod.info, which need not match the
        # folder name. Reading the folder name instead works for most mods and
        # fails silently for the rest: the server reports the id it cannot find,
        # not the folder it did find.
        #
        # Searched at DEPTH 2 only, because that is where the server looks —
        # `<mod>/common/mod.info` or `<mod>/<version>/mod.info`. A build 41 mod
        # has it at the root instead, and `getAllModFoldersAux` skips such a
        # folder without a word. Reporting its id anyway would put a mod in
        # `Mods=` that the server then cannot find, and the message names the
        # id rather than the reason.
        info=$(find "$modsDir/$name" -mindepth 2 -maxdepth 2 -name mod.info -print -quit)
        if [ -z "$info" ]; then
          if [ -e "$modsDir/$name/mod.info" ]; then
            echo "zomboid-workshop: $name keeps mod.info at its root, which this build ignores — the mod has not been updated for build 42. Skipping." >&2
          else
            echo "zomboid-workshop: $name carries no mod.info, skipping" >&2
          fi
          continue
        fi

        modId=$(grep -m1 '^id=' "$info" | cut -d= -f2- | tr -d '\r')
        if [ -z "$modId" ]; then
          echo "zomboid-workshop: $name has a mod.info with no id=, skipping" >&2
          continue
        fi

        echo "$modId"
      done
    done
  '';

  meta = {
    description = "Download Project Zomboid Workshop items and install them where the server looks";
    mainProgram = "zomboid-workshop";
  };
}
