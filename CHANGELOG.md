# Changelog

## [0.4.2](https://github.com/hcbt/nixzoid/compare/v0.4.1...v0.4.2) (2026-08-06)


### Fixed

* bump the common depot to the manifest Steam still serves ([#22](https://github.com/hcbt/nixzoid/issues/22)) ([bfbe94d](https://github.com/hcbt/nixzoid/commit/bfbe94d92deeaddb0c3620be63b263e5cb62bf1e))

## [0.4.1](https://github.com/hcbt/nixzoid/compare/v0.4.0...v0.4.1) (2026-08-06)


### Fixed

* label the package with the build it actually contains, and create mods/ ([#17](https://github.com/hcbt/nixzoid/issues/17)) ([e5c6555](https://github.com/hcbt/nixzoid/commit/e5c655519bd293f82e424190ab57a0b1becb7ddd))
* **steam:** follow the local steamclient, and say what non-Steam costs players ([#20](https://github.com/hcbt/nixzoid/issues/20)) ([2e1c698](https://github.com/hcbt/nixzoid/commit/2e1c69890ac1cb9e636e9b50d97db28a7b254403))

## [0.4.0](https://github.com/hcbt/nixzoid/compare/v0.3.2...v0.4.0) (2026-08-03)


### ⚠ BREAKING CHANGES

* `services.zomboid.workshopItems` no longer renders `WorkshopItems=`. It sets `ZOMBOID_WORKSHOP_ITEMS`, and the launcher downloads those items with DepotDownloader instead of the server fetching them through Steam — one downloader for one job, and the only one that works on macOS. It is also enough on its own now, so `mods` is only needed for a hand-placed mod or to fix load order. A host that relied on the Steam path can restore it with `settings.WorkshopItems`, and the module warns when both are set.

### Added

* run the server on macOS, and configure it from the command line ([#15](https://github.com/hcbt/nixzoid/issues/15)) ([e409470](https://github.com/hcbt/nixzoid/commit/e4094700be22814110b04d75ce8f2de34ac729c4))

## [0.3.2](https://github.com/hcbt/nixzoid/compare/v0.3.1...v0.3.2) (2026-08-01)


### Fixed

* **shell:** define the dev shell in flake.nix instead of nix/shells.nix ([#13](https://github.com/hcbt/nixzoid/issues/13)) ([d2081b3](https://github.com/hcbt/nixzoid/commit/d2081b31ceeb152ddb7b47fbe957cca3ac983af0))

## [0.3.1](https://github.com/hcbt/nixzoid/compare/v0.3.0...v0.3.1) (2026-08-01)


### Fixed

* **deps:** bump nivis to v0.8.2 and coldstart to v0.3.1 ([#11](https://github.com/hcbt/nixzoid/issues/11)) ([6c569d1](https://github.com/hcbt/nixzoid/commit/6c569d10c34e279bc83aeedbe5599087d89f2e75))

## [0.3.0](https://github.com/hcbt/nixzoid/compare/v0.2.1...v0.3.0) (2026-07-31)


### Added

* expose mods and server configuration ([#8](https://github.com/hcbt/nixzoid/issues/8)) ([4c0f6a2](https://github.com/hcbt/nixzoid/commit/4c0f6a2bc2b41d08ea5f5eea0c0d2b57557c5f35))

## [0.2.1](https://github.com/hcbt/nixzoid/compare/v0.2.0...v0.2.1) (2026-07-31)


### Fixed

* **wrapper:** make the game data reachable from the working directory ([#4](https://github.com/hcbt/nixzoid/issues/4)) ([47066ad](https://github.com/hcbt/nixzoid/commit/47066ad0148b2dd96f3f4736c1b41c83e7e818f6))
* **wrapper:** run from the install root, not the state directory ([#7](https://github.com/hcbt/nixzoid/issues/7)) ([0b5ae38](https://github.com/hcbt/nixzoid/commit/0b5ae382b0e0ef516348c7ea422a670deb37300c))

## [0.2.0](https://github.com/hcbt/nixzoid/compare/v0.1.0...v0.2.0) (2026-07-30)


### Added

* package the Project Zomboid dedicated server ([bc5d010](https://github.com/hcbt/nixzoid/commit/bc5d010fe00eb7f2ec65dbdee806d3f7208137be))
