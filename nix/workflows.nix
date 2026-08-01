# The workflows this repo owns, as text for `repo.extraFiles`.
#
# nivis generates `.envrc`, dependabot, release-please, the flake.lock workflow
# and nix-check; this is the one only this repo has. Routing it through
# `extraFiles` means every workflow has one writer and one drift check rather
# than five of six, so nothing in `.github/` can be edited and quietly diverge.
#
# Kept as verbatim YAML under `nix/ci/` rather than as a Nix string: the file
# contains `'${{ … }}'`, and a quote directly before an interpolation cannot be
# written unambiguously in a Nix indented string. `nix/ci/` is excluded from
# treefmt, or prettier reformats the source while the generated copy stays
# excluded and the two can never match.
{ }:
{
  ".github/workflows/image.yml" = builtins.readFile ./ci/image.yml;
}
