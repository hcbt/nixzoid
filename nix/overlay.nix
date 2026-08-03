# The overlay, in its own file so `nix/checks.nix` can apply it without going
# through `inputs.self` — reaching for the flake's own outputs from inside its
# checks is how an evaluation cycle starts.
final: prev: {
  # DepotDownloader cannot fetch anything from inside a Nix build on darwin,
  # and the failure is not its own.
  #
  # `AccountSettingsStore` opens an `IsolatedStorageFile` in a STATIC field, so
  # the store is constructed before `Main` reads a single flag. That resolves
  # `SpecialFolder.ApplicationData`, and on macOS .NET takes the home directory
  # from PASSWD rather than from `$HOME` — verifiably so: point `HOME` at a
  # scratch directory and the store still appears under the real one. A Nix
  # build user's passwd home is `/var/empty`, so the constructor throws
  # `UnauthorizedAccessException` and the process aborts.
  #
  # This is why `fetch-steam`'s own `HOME=$(mktemp -d)` works on Linux, where
  # .NET does read `$HOME`, and does nothing here.
  #
  # The store only caches credentials and a content-server penalty list.
  # `fetchSteam` logs in anonymously and runs once in a build directory that is
  # then discarded, so plain files in the working directory lose nothing. The
  # substitutions are `--replace-fail`, so a nixpkgs bump that moves this code
  # fails the build with the pattern it could not find rather than silently
  # reverting to a broken fetch.
  #
  # The field becomes a COMMENT rather than nothing. DepotDownloader builds
  # with IDE0055 promoted to an error, so the eight spaces an empty
  # substitution leaves behind fail the build as a formatting violation.
  depotdownloader = prev.depotdownloader.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + final.lib.optionalString final.stdenv.hostPlatform.isDarwin ''
        substituteInPlace DepotDownloader/AccountSettingsStore.cs \
          --replace-fail \
            'static readonly IsolatedStorageFile IsolatedStorage = IsolatedStorageFile.GetUserStoreForAssembly();' \
            '// IsolatedStorage: dropped by the nixzoid overlay, see the comment there.' \
          --replace-fail \
            'IsolatedStorage.FileExists(filename)' \
            'File.Exists(filename)' \
          --replace-fail \
            'IsolatedStorage.OpenFile(filename, FileMode.Open, FileAccess.Read)' \
            'File.Open(filename, FileMode.Open, FileAccess.Read)' \
          --replace-fail \
            'IsolatedStorage.OpenFile(Instance.FileName, FileMode.Create, FileAccess.Write)' \
            'File.Open(Instance.FileName, FileMode.Create, FileAccess.Write)'
      '';
  });

  # Carries no game content, so unlike the two below it builds and runs
  # anywhere — which is what lets `checks.merge-ini` actually exercise it.
  zomboid-merge-ini = final.callPackage ../pkgs/zomboid-server/merge-ini.nix { };

  # Same reasoning, and the same reason it is not part of the launcher: it
  # carries no game content, so `checks.render-config` can run it and diff its
  # output against the Nix renderer in `config-format.nix`.
  zomboid-render-config = final.callPackage ../pkgs/zomboid-server/render-config.nix { };

  # Also game-content-free, so `checks.workshop-install` runs it — the install
  # and mod-id half, with `--offline`, against a synthetic workshop item. Only
  # the download needs Steam, and nothing in `checks` may reach the network.
  zomboid-workshop = final.callPackage ../pkgs/zomboid-server/workshop.nix { };

  zomboid-server-unwrapped = final.callPackage ../pkgs/zomboid-server { };
  zomboid-server = final.callPackage ../pkgs/zomboid-server/wrapper.nix { };
}
