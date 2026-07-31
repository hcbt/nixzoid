# The overlay, in its own file so `nix/checks.nix` can apply it without going
# through `inputs.self` — reaching for the flake's own outputs from inside its
# checks is how an evaluation cycle starts.
final: _prev: {
  # Carries no game content, so unlike the two below it builds and runs
  # anywhere — which is what lets `checks.merge-ini` actually exercise it.
  zomboid-merge-ini = final.callPackage ../pkgs/zomboid-server/merge-ini.nix { };

  zomboid-server-unwrapped = final.callPackage ../pkgs/zomboid-server { };
  zomboid-server = final.callPackage ../pkgs/zomboid-server/wrapper.nix { };
}
