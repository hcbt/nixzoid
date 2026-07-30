# The overlay, in its own file so `nix/checks.nix` can apply it without going
# through `inputs.self` — reaching for the flake's own outputs from inside its
# checks is how an evaluation cycle starts.
final: _prev: {
  zomboid-server-unwrapped = final.callPackage ../pkgs/zomboid-server { };
  zomboid-server = final.callPackage ../pkgs/zomboid-server/wrapper.nix { };
}
