# The dev shell, the formatters and the git hooks. Replaces nivis'
# `mkDevShell`, `flakeModules.git-hooks` and `flakeModules.treefmt`.
#
# A module file rather than an inline block, so `perSystem` in flake.nix stays
# readable and this can be diffed against the other repos' copies. It is loaded
# through devenv's flake-parts module, so the inputs come from flake.nix and
# there is no devenv.yaml.
#
# `nix develop` is impure: it PREPENDS the shell's packages to the ambient PATH
# rather than replacing it, so any tool not named here falls through to a
# Homebrew or /usr/bin copy without saying so. That is why the everyday
# utilities are pinned alongside the repo-specific ones.
{
  pkgs,
  # The package set the HOOK TOOLS come from. flake.nix passes devenv's set,
  # so the shell and `checks.pre-commit` run the same formatter binaries even
  # though the check itself is built from this flake's nixpkgs.
  toolPkgs ? pkgs,
  ...
}:
{
  packages = [
    # Everyday utilities, so nothing resolves to a host binary.
    pkgs.git
    pkgs.gh
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    pkgs.curl

    # Repo-specific. jq reads depot metadata off Steam's API when the manifest
    # ids are bumped — see pkgs/zomboid-server/default.nix.
    pkgs.jq
    pkgs.kubernetes-helm
    pkgs.kubectl
    pkgs.yq-go
  ];

  # treefmt is gone. devenv's git-hooks is cachix/git-hooks.nix, the same
  # project nivis wrapped, and it carries nixfmt and prettier as hooks of their
  # own — so one formatter definition survives without the extra input.
  #
  # What is lost with treefmt: `nix fmt`. Formatting the whole tree is
  # `prek run --all-files` from inside the shell, and CI runs the same hooks.
  git-hooks.package = pkgs.prek;
  git-hooks.hooks = {
    # nixfmt is the RFC 166 formatter.
    nixfmt-rfc-style.enable = true;
    nixfmt-rfc-style.package = toolPkgs.nixfmt;
    prettier.enable = true;
    prettier.package = toolPkgs.prettier;

    # Correctness checks that are not formatting.
    check-merge-conflicts.enable = true;
    check-yaml.enable = true;
    check-added-large-files.enable = true;

    # No formatter knows about a .gitignore, and a missing trailing newline
    # shows up as a spurious diff line in every later change to the file.
    end-of-file-fixer.enable = true;
    trim-trailing-whitespace.enable = true;
  };

  # Lockfiles and the licence text: never worth formatting, and prettier will
  # happily mangle some of them.
  git-hooks.excludes = [
    "^LICENSE$"
    "\\.lock$"
  ];

  # No `enterTest`. devenv 2.1.2 does not pick that option up — a run logs
  # `devenv:enterTest (no command)` and then reports "Tests passed", so an
  # assertion written there passes whether or not it ran. Measured on the
  # self-hosted runner, not assumed. Anything that has to assert on the
  # environment runs through `devenv shell` instead.
}
