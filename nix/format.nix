# The repo-specific half of formatting and hooks. nivis brings nixfmt, prettier
# and the language-agnostic hook set; the module system merges what is here on
# top, so nothing nivis already set has to be restated.
{ ... }:
{
  perSystem = {
    treefmt.settings.global.excludes = [
      "LICENSE"
    ];
  };
}
