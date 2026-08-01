# The repo-specific half of formatting and hooks. nivis brings nixfmt, prettier
# and the language-agnostic hook set; the module system merges what is here on
# top, so nothing nivis already set has to be restated.
{ ... }:
{
  perSystem = {
    treefmt.settings.global.excludes = [
      # Source for `repo.extraFiles`. The generated copies under
      # `.github/workflows/` are already excluded; formatting the source
      # would leave the two permanently unequal.
      "nix/ci/**"
      "LICENSE"
    ];
  };
}
