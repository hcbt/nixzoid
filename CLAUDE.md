# CLAUDE.md

nixzoid packages the Project Zomboid dedicated server and deploys it as a
container. The generic container machinery is
[coldstart](https://github.com/hcbt/coldstart); everything here is the
Zomboid-shaped remainder.

## Layout

- `pkgs/zomboid-server/default.nix` — the two Steam depots, merged and
  autoPatchelf'd. This is the ~7G half.
- `pkgs/zomboid-server/wrapper.nix` — the launcher. Replaces upstream's
  `start-server.sh` + `ProjectZomboid64.json`, which cannot work from a
  read-only store. Also the whole runtime interface: every `ZOMBOID_*` variable
  is documented at the top of it.
- `pkgs/zomboid-server/config-format.nix` — renders `<name>.ini` and
  `<name>_SandboxVars.lua`. A pure function of `lib`, exported as
  `flake.lib`, so the NixOS module and the cluster repository's Helm values go
  through the same renderer.
- `pkgs/zomboid-server/merge-ini.nix` — applies a declared ini fragment over
  the one the server maintains. The only real behaviour here, and the only
  check that runs rather than evaluates.
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
- **Hashes can only be obtained on Linux**, by building with a wrong hash and
  reading the reported one. DepotDownloader does not run on darwin in this
  configuration, and `nix flake check` on a laptop never exercises this path.

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
