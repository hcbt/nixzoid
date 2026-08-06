# CLAUDE.md

nixzoid packages the Project Zomboid dedicated server and deploys it as a
container. The generic container machinery is
[coldstart](https://github.com/hcbt/coldstart); everything here is the
Zomboid-shaped remainder.

## Layout

- `pkgs/zomboid-server/default.nix` — the shared Steam depot plus the platform
  one, merged, and autoPatchelf'd on Linux. This is the ~7G half.
- `pkgs/zomboid-server/wrapper.nix` — the launcher. Replaces upstream's
  `start-server.sh` + `ProjectZomboid64.json` on Linux and
  `StartServer.command` on macOS, none of which work from a read-only store.
  Also the whole runtime interface: every `ZOMBOID_*` variable and every flag
  is documented at the top of it.
- `pkgs/zomboid-server/workshop.nix` — downloads a Workshop item with
  DepotDownloader and installs it into the state dir. The server cannot do this
  on macOS, and its `id=` output is what `--workshop` feeds into `Mods=`.
- `pkgs/zomboid-server/render-config.nix` — the same two files as
  `config-format.nix`, rendered from FLAGS at runtime instead of from Nix at
  evaluation time. `nix run … -- --mod x` has no evaluation left when the flag
  is read. `checks.render-config` diffs the two renderers.
- `pkgs/zomboid-server/config-format.nix` — renders `<name>.ini` and
  `<name>_SandboxVars.lua`. A pure function of `lib`, exported as
  `flake.lib`, so the NixOS module and the cluster repository's Helm values go
  through the same renderer.
- `pkgs/zomboid-server/merge-ini.nix` — applies a declared ini fragment over
  the one the server maintains. Decides whether a restart keeps or discards
  what the server wrote for itself.
- `nix/overlay.nix` — the overlay, in its own file so checks can apply it
  without going through `inputs.self`.
- `nix/nixos-module.nix` — `services.zomboid`, on top of coldstart's container.
- `nix/pkgs.nix` — the `pkgs` everything is built against: the two overlays and
  the unfree predicate.

## The game is not redistributable

- **This repository must never contain game content** — only manifest ids and
  hashes.
- **`ghcr.io/hcbt/nixzoid` must stay a PRIVATE package**, even though the repo
  is public. The image embeds the game; publishing it would be republishing
  Project Zomboid.

## Invariants

- **Nothing in `checks` may build the server.** The depots are ~7G. Every check
  here asserts on evaluation or on `passthru`, and
  `nix build .#zomboid-image` is what proves the heavy half works.
- **Configuration is never baked into the package.** Mods, server settings and
  the server name all arrive through the environment at runtime. A value built
  into the wrapper sits inside a ~7G image, so changing it costs a rebuild and
  a re-push — the reasoning that already made `heapSize` an environment
  variable, applied to everything a deployment sets.
- **`writeShellApplication` runs shellcheck at BUILD time, which never happens
  here.** The launcher cannot be built without the depots, so its lint is
  unreachable on a laptop and in CI. `checks.launcher-shellcheck` lints the
  `passthru` text instead; without it a shell mistake surfaces an hour into the
  image workflow.
- **`extraContainerConfig` is merged with `//`.** Declaring `bindMounts` there
  REPLACES coldstart's own rather than adding to it, so the state mount has to
  be restated alongside any secret mount. Dropping it puts the saves in the
  container's ephemeral root, where a restart discards them silently.
- **Discard the string context when a check reads a store-path-bearing
  string.** `zomboid-server.launcher` and the module's `execStart` both
  interpolate the unwrapped server's path; handing either to a derivation makes
  the depots an INPUT, and Nix downloads 7G to run a check that only greps
  text. `builtins.unsafeDiscardStringContext` is the fix, and forgetting it
  looks like a hang rather than an error.
- **Never make a `perSystem` module's definition set depend on `pkgs`.**
  `perSystem = { pkgs, ... }: lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux { … }`
  is an infinite recursion — the module system cannot know _which options are
  declared_ without `pkgs`, and `pkgs` is itself a module argument. Guard each
  attribute's **value** instead. The error names `_module.args` in
  `lib/modules.nix` and points nowhere near the cause.
- **Never set `nixpkgs.overlays` in a module that also reads `pkgs`.** The
  `services.zomboid.package` default reads `pkgs`, so the overlays live in a
  separate, argument-free module inside `imports`. Same recursion, same
  unhelpful error.
- **`fetchSteam` needs `manifestId`, not a version.** A Steam fetch can only be
  a fixed-output derivation against an exact build; there is no "latest" that
  has a hash.
- **A hash can only be obtained on the platform whose depot it is**, by
  building with a wrong hash and reading the reported one. `nix flake check`
  never exercises this path on either host.
- **DepotDownloader cannot run inside a Nix build on darwin unpatched.**
  `AccountSettingsStore` opens an `IsolatedStorageFile` in a STATIC field, and
  on macOS .NET resolves the home directory from PASSWD rather than from
  `$HOME` — a build user's is `/var/empty`, so it throws before `Main` reads a
  flag. `nix/overlay.nix` patches it, darwin-only. The binary itself runs fine
  interactively, which makes this easy to misdiagnose: the failure is the
  sandbox's home directory, not the tool.
- **The two Steam modes DO NOT INTEROPERATE, and the server's choice binds
  every player.** The game's own strings, in
  `media/lua/shared/Translate/EN/UI_EN.json`: "This Steam client can only
  connect to Steam servers" / "This non-Steam client can only connect to
  non-Steam servers". With Steam off, every client needs the `-nosteam` launch
  option — direct IP does not get around it. Never describe non-Steam mode as
  merely "not in the browser, direct connect only".
- **macOS FINDS a steamclient rather than shipping one.** Depot 1005, the macOS
  Steamworks redist, is not available to an anonymous account. A Mac with Steam
  installed already has the library at the path upstream's
  `StartServer.command` names, so the launcher tests for it and defaults Steam
  ON when it is there. Only a Mac without Steam falls back to 0, and the
  launcher prints the `-nosteam` instruction on stderr when it does.
- **A borrowed dylib still cannot DOWNLOAD workshop items** — that fails with
  `Install library folder not found` and kills the server — but only when
  `WorkshopItems=` is set, which `--workshop` never does.
- **The answer to a question about the GAME is usually in the depot.** The
  client-connection rule sat in a shipped translation file for the whole of the
  macOS work while it was repeatedly called "unverifiable without a second
  machine". Grep `media/lua/` and `media/lua/shared/Translate/EN/` before
  claiming something needs hardware to answer.
- **The only platform differences left in the launcher are two defaults.**
  `--state` (`/data` vs `$HOME/Zomboid`) and `--steam` (1 vs 0). Every flag
  parses and behaves identically otherwise; diff the two `passthru` launchers
  with store paths normalised before claiming a third.
- **List flags split on commas, and the splitting lives in the small
  packages.** `--workshop a,b` and `--mod a,b` are handled by
  `zomboid-workshop` and `zomboid-render-config`, not by the launcher — the
  launcher cannot be built without ~7G of depots, so logic put there gets no
  test. `--set` and `--sandbox` must never split: their values are free text.
- **One downloader for mods, everywhere: DepotDownloader.** `--workshop` and
  `services.zomboid.workshopItems` both go through `zomboid-workshop`
  (`-app 108600 -pubfile <id>`, anonymous) into `$state/mods`. NOTHING here
  writes `WorkshopItems=` any more — that asks the SERVER to fetch through
  Steam, and running both downloads each item twice at possibly different
  versions with `modFoldersOrder = workshop,steam,mods` picking the server's.
  `--set WorkshopItems=` stays reachable on purpose; it is not the mechanism.
- **`--workshop` is the launcher's flag and nothing else's.** It used to exist
  on `zomboid-render-config` meaning the OPPOSITE — write `WorkshopItems=`.
  That flag now dies with a message naming `zomboid-workshop`, because two
  flags of one name doing opposite things is worse than an unknown option.
- **The image carries DepotDownloader and .NET, ~128M.** That is the price of
  the line above: without it `ZOMBOID_WORKSHOP_ITEMS` is an option the Helm
  values can set and the container cannot honour. Do not "optimise" it out
  without removing the option too.
- **Build 42 wants `mod.info` in `<mod>/common/` or `<mod>/42/`, never at the
  mod root.** `getAllModFoldersAux` skips a non-matching folder with NO
  message, which surfaces as `required mod "x" not found` for a mod that is on
  disk. Never rewrite a published mod's layout to work around it.
- **Never read a subcommand through `< <(cmd)` in the launcher.** A process
  substitution's exit status is invisible to `set -o errexit`. Reading the
  workshop installer that way made a failed download start the server with the
  mods missing and nothing logged — and the world it then generated had no
  trace of them. `checks.launcher-arguments` guards this.
- **Do not patch a Mach-O, and do not let anything strip one.** Every binary in
  the macOS depot is signed — ad-hoc on the PZ natives, an Azul certificate
  with the hardened runtime on the JRE. `strip` invalidates the signature and
  macOS then kills the process without naming a file. `dontStrip` is set on
  darwin for that reason, and nothing there needs patching anyway.

## Shared scaffolding

The dev shell, treefmt, the git hooks and the GitHub-side files come from
[nivis](https://github.com/hcbt/nivis), pinned in `flake.nix`.

- **`.envrc`, `.github/dependabot.yml`, `release-please-config.json` and the
  `Check`, `Update flake.lock` and release-please workflows are generated.**
  Edit them in nivis, then run `nix run .#sync-repo` here.
  `checks.repo-files-current` fails on drift.
- `.github/workflows/image.yml` is this repo's own and is not generated.
- Releases come from release-please. Do not tag by hand.

## Working on this repo

- New files must be `git add`ed before any `nix` command sees them.
- `nix flake check` on darwin omits every Linux-only output. Verify an image or
  packaging change on x86_64-linux before claiming it works.
- **The launcher checks cover both platforms from either host.** They read a
  `passthru` string with its context discarded, so a Linux runner asserts on
  the macOS script and a laptop asserts on the Linux one. Adding a
  platform-specific argument means adding it to the per-platform block in
  `checks.launcher-arguments`, not just to `wrapper.nix`.
