# `nix develop` / direnv. nivis' mkDevShell brings prek, the treefmt wrapper,
# the pinned shell utilities and the pre-commit devShell fragment.
{ ... }:
{
  perSystem =
    { pkgs, mkDevShell, ... }:
    {
      devShells.default = mkDevShell {
        packages = [
          # For reading depot metadata off Steam's API when bumping the
          # manifest ids — see pkgs/zomboid-server/default.nix.
          pkgs.jq
          pkgs.kubernetes-helm
          pkgs.kubectl
          pkgs.yq-go
        ];
      };
    };
}
