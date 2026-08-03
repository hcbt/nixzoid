# nixzoid

A [Project Zomboid](https://projectzomboid.com/) dedicated server, packaged with
Nix and deployed as a container.

The generic half — the OCI image builder, the Helm chart and the
systemd-nspawn NixOS container — lives in
[coldstart](https://github.com/hcbt/coldstart). What is here is the
Zomboid-shaped remainder: fetching the game off Steam, making its prebuilt
binaries run under Nix, and launching the JVM the way upstream's scripts would
have.

> **The game is not redistributable.** This repository contains no game content
> — only the manifest ids and hashes needed to fetch it. The image built from it
> **does** embed the game, so it must only ever be pushed to a **private**
> registry. `ghcr.io/hcbt/nixzoid` is private for this reason.

## What it does

```
nix run   github:hcbt/nixzoid   # start a server here, on this machine
nix build .#zomboid-server      # the launcher
nix build .#zomboid-image       # the OCI image the cluster runs
```

The server runs on **`x86_64-linux`** and **`aarch64-darwin`**. The image is
Linux only, and honestly absent elsewhere rather than evaluating everywhere and
building in one place: `dockerTools` cannot build a Linux image from Darwin.

### Running one without a deployment

Everything the server needs can be given on the command line, which is what
makes a one-off server a single command:

```bash
nix run github:hcbt/nixzoid -- --name knox --workshop 3773911887,3774826484 --set MaxPlayers=16 --sandbox Zombies=3
```

That downloads both Workshop items, installs them, enables them, and starts the
server. There is no second step and no Steam account involved.

| Flag                          | What                                               |
| ----------------------------- | -------------------------------------------------- |
| `--name` `--state` `--heap`   | Server name, where saves live, JVM heap            |
| `--set K=V`                   | One `<name>.ini` key, repeatable                   |
| `--workshop ID[,ID...]`       | Download Workshop items, install them, enable them |
| `--mod ID[,ID...]`            | Enable already-installed mods. Rarely needed       |
| `--sandbox K=V`               | One `SandboxVars` key. A dotted key nests          |
| `--config` / `--sandbox-file` | Whole files, for anything the flags do not cover   |
| `--print-config`              | Render the config, print it, and do not start      |

Every flag has an environment variable as well, and `--help` names both. The
flag wins. State defaults to `~/Zomboid` on macOS and `/data` on Linux.

`--set` and friends go through `zomboid-render-config`, which produces the same
two files `nixzoid.lib.mkServerIni` and `mkSandboxVars` produce for the NixOS
module and the Helm values. `checks.render-config` diffs the two renderers byte
for byte, so a flag and a declared option cannot drift into different spellings
of one setting.

## Getting the game

App **380870** splits the dedicated server across a shared depot and one per
platform. Two of the three are always required:

| Depot    | What                                                                                               | Size           |
| -------- | -------------------------------------------------------------------------------------------------- | -------------- |
| `380871` | Platform-independent content — `java/projectzomboid.jar`, `media/`, the Lua stdlib                 | ~6.9G unpacked |
| `380873` | The Linux half — the bundled Azul Zulu JRE, the JNI natives in `linux64/`, the pzexe launcher      | ~218M          |
| `380872` | The macOS half — an arm64 Azul Zulu JRE under `jre/Contents/Home`, universal natives in `natives/` | ~205M          |

Neither half is useful alone: the jar is the server, and the natives are what it
`dlopen()`s on startup. Access is anonymous, so no Steam credentials are
involved anywhere.

There is no `x86_64-darwin`. The macOS depot's `java` is a thin arm64 Mach-O, so
an Intel Mac has no JVM to run — even though the PZ natives beside it are
universal.

### Updating to a new build

`manifestId` pins an exact build, which is the only way a Steam fetch can be a
fixed-output derivation — "whatever is current" has no hash. All three move
together, because all three come out of one app build. Steam's own metadata API
lists them:

```bash
curl -s https://api.steamcmd.net/v1/info/380870 | jq '.data["380870"].depots | {"380871","380872","380873"} | map_values(.manifests.public.gid)'
```

Put the new gids in [`pkgs/zomboid-server/default.nix`](pkgs/zomboid-server/default.nix),
set the hashes to `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, and
build — Nix reports the real hash. There is no way to compute one without
downloading, and a host can only fetch the depot it has a `fetchSteam` call for,
so bumping all three takes one build on Linux and one on macOS.

### Why DepotDownloader is patched

`nix/overlay.nix` carries a darwin-only patch to `depotdownloader`, and without
it no depot can be fetched on a Mac at all.

`AccountSettingsStore` opens an `IsolatedStorageFile` in a **static field**, so
it is constructed before `Main` reads a flag. That resolves
`SpecialFolder.ApplicationData`, and on macOS .NET takes the home directory from
**passwd**, not from `$HOME` — point `HOME` at a scratch directory and the store
still appears under the real one. A Nix build user's passwd home is
`/var/empty`, so the constructor throws and the process aborts. This is why
`fetch-steam`'s own `HOME=$(mktemp -d)` works on Linux and does nothing here.

The store only caches credentials and a content-server penalty list, and
`fetchSteam` logs in anonymously into a build directory that is then discarded.
The patch points those three calls at plain files instead.

## Making it run

Upstream ships `start-server.sh`, which `cd`s into the install directory and
runs a launcher that reads `ProjectZomboid64.json` and execs the bundled JRE.
None of that survives the Nix store: the install directory is read-only, and
every path in that json — the classpath, `-Djava.library.path`, even the heap
size — is relative to a working directory the server may no longer write to.

macOS ships `StartServer.command` instead, which does the same thing with
different paths and a different set of JVM flags.

So the wrapper skips all of it and invokes the JVM directly with absolute paths,
carrying exactly the arguments upstream specified for the platform. Three of
them are worth knowing about, because getting any wrong produces a server that
_starts_:

- **`-Djava.library.path`** — without it the server runs for several seconds and
  then dies on the first `dlopen` with an `UnsatisfiedLinkError` naming a class
  rather than the flag.
- **`steamclient.so`** — `libsteam_api.so` `dlopen()`s it by bare name and it
  ships in neither depot; it comes from the Steamworks redist (app 1007). Absent,
  the server starts, never reaches the Steam master server, and never appears in
  the in-game browser, with nothing in the log naming the missing library.
- **`-cachedir=` _and_ `HOME`** — the server resolves some paths from each. Set
  only one and state scatters across two directories, one of them in the store.

What differs by platform:

|              | Linux             | macOS                        |
| ------------ | ----------------- | ---------------------------- |
| JVM          | `jre64/bin/java`  | `jre/Contents/Home/bin/java` |
| Natives      | `linux64/`        | `natives/`                   |
| Library path | `LD_LIBRARY_PATH` | `DYLD_LIBRARY_PATH`          |
| Collector    | `-XX:+UseZGC`     | whatever the JVM defaults to |
| Extra flag   | —                 | `-XstartOnFirstThread`       |
| Steam        | on                | off — see below              |

`checks.launcher-arguments` asserts on all of it, for **both** scripts, because
every one of those failures costs a full server start to discover.

### macOS has no Steam networking

The Steamworks redist has a macOS depot, `1005`, and Steam will not give it to
an anonymous account:

```
Depot 1005 is not available from this account.
```

So there is no `steamclient.dylib` to ship, and macOS defaults to
`-Dzomboid.steam=0`. The server then runs on `libZNetNoSteam.dylib`: it works,
it keeps saves, and mods load — but it does not register with the Steam master
server, so it never appears in the in-game browser and players reach it by
direct connection only.

A Mac that has Steam installed already has the library. Point
`ZOMBOID_STEAMCLIENT_DIR` at the directory holding it and pass `--steam`; no
rebuild is involved.

## Configuring it

Mods and server settings arrive at **runtime**, through a flag or through the
environment. None of it is baked into the package — that derivation carries ~7G
of Steam depots, so a mod list built into it would make adding one mod a full
image rebuild and re-push. Same reason the heap is an environment variable.

Every variable below has a flag; see [Running one without a
deployment](#running-one-without-a-deployment). The flag wins.

| Variable                      | What                                                     |
| ----------------------------- | -------------------------------------------------------- |
| `ZOMBOID_STATE_DIR`           | Saves, config and logs (`/data`, `~/Zomboid` on macOS)   |
| `ZOMBOID_HEAP`                | JVM heap (`8g`)                                          |
| `ZOMBOID_STEAM`               | `1` or `0`, the Steam networking stack                   |
| `ZOMBOID_STEAMCLIENT_DIR`     | A directory holding `steamclient.so` / `.dylib`          |
| `ZOMBOID_WORKSHOP_ITEMS`      | Workshop ids to install, comma or space separated        |
| `ZOMBOID_WORKSHOP_OFFLINE`    | Reuse what is downloaded, contact Steam for nothing      |
| `ZOMBOID_SERVER_NAME`         | Names the config files, and `-servername` (`servertest`) |
| `ZOMBOID_CONFIG_FILE`         | `<name>.ini` fragment, merged key by key                 |
| `ZOMBOID_CONFIG_SECRET_FILE`  | The same, applied after — `Password`, `RCONPassword`     |
| `ZOMBOID_SANDBOX_FILE`        | `<name>_SandboxVars.lua`, copied whole                   |
| `ZOMBOID_SPAWNREGIONS_FILE`   | `<name>_spawnregions.lua`, copied whole                  |
| `ZOMBOID_ADMIN_USERNAME`      | Admin account name (`admin`)                             |
| `ZOMBOID_ADMIN_PASSWORD_FILE` | Without it a **first** boot hangs — see below            |

Three things about this are worth knowing before the first start:

- **The ini is merged, not replaced.** The server maintains ~150 options in that
  file and rewrites it as it runs. Only the keys you declare are re-applied on
  each start; the rest stay as the server left them. The flip side: an in-game
  change to a key you declared is gone at the next restart.
- **`SandboxVars.lua` _is_ replaced**, whole, every start. Merging it would mean
  parsing Lua, and a line-oriented approximation corrupts a nested group instead
  of failing. Keys you leave out take the server's defaults, so a short file is a
  complete one.
- **A first boot without an admin password hangs.** With no administrator in the
  state directory the server asks for one on stdin and waits. Nothing in a
  container answers, so the start stops part-way with nothing in the log naming
  the prompt.

### Mods

There are two ways to get a mod onto the server, and they do not mix.

#### `--workshop <id>` — the launcher downloads it

```bash
nix run github:hcbt/nixzoid -- --workshop 3773911887,3774826484
```

That is the whole thing. The launcher downloads each item, installs every mod it
carries into `$state/mods`, reads the `id=` out of each `mod.info`, and puts
those into `Mods=` for you. No `--mod`, no Steam, no account, no second step.

The list takes commas or spaces, and the flag still repeats — `--workshop a,b`,
`--workshop "a, b"` and `--workshop a --workshop b` are the same thing. `--mod`
takes a list the same way. `--set` and `--sandbox` do **not** split: their values
are free text, and a comma in a server message is a comma.

It works because `depotdownloader -app 108600 -pubfile <id>` fetches a published
workshop file **anonymously** — the same anonymous access `fetchSteam` already
uses for the game. Which matters most on macOS, where the server cannot download
anything itself: there is no `steamclient.dylib` to do it with.

Nothing is pinned. Adding a mod costs a restart instead of a rebuild, and a mod
author's update lands on the next restart unannounced. A restart re-checks the
manifest rather than re-downloading, and `--offline` skips even that.

`--workshop` deliberately does **not** write `WorkshopItems=`. If it did, a Linux
server with Steam on would fetch each item a second time through Steam, and
`modFoldersOrder` is `workshop,steam,mods` — so the Steam copy would win, at
whatever version Steam has.

#### `WorkshopItems=` — the server downloads it

The original path, still there, still Linux-only in practice because it needs
Steam. `WorkshopItems=` and `Mods=` are then **two separate keys and both are
required** — one says what to fetch, the other what to load. Only the first, and
the server downloads mods it never enables; only the second, and it enables mods
it never downloaded. Neither failure says anything useful in the log, so the
module warns when one is set without the other.

#### Build 42 changed the mod layout

`ZomboidFileSystem.getAllModFoldersAux` skips a mod folder that does not match,
**silently**:

```java
if (!Files.exists(path.resolve("common", "mod.info"))
 && !Files.exists(path.resolve(versionDirName, "mod.info"))) continue;
```

So `mod.info` lives in `<mod>/common/` or `<mod>/42/`, never at the mod root. A
build 41 mod has it at the root and is skipped, which surfaces as
`required mod "x" not found` for a mod that is plainly on disk. Nothing here
rewrites that layout — the item is installed exactly as published — but the
installer does say so rather than putting an id in `Mods=` that the server will
ignore.

### On Kubernetes

The chart is coldstart's and knows nothing about Zomboid, so the cluster
repository renders the two config files itself with `nixzoid.lib` — the same
renderer the NixOS module uses, so the two deployments cannot drift into
different spellings of the same setting — and mounts the result as a ConfigMap:

```nix
# in the cluster repository
zomboidIni = inputs.nixzoid.lib.mkServerIni {
  PublicName = "Knox County";
  MaxPlayers = 16;
  Mods = [ "tsarslib" "Brita_2" ];
  WorkshopItems = [ "2392709985" "2857548524" ];
};
```

with `ZOMBOID_CONFIG_FILE` pointed at the mount path, and the passwords coming
through `env[].valueFrom.secretKeyRef` into a file the chart mounts for
`ZOMBOID_CONFIG_SECRET_FILE`. See `apps/zomboid/values.yaml` in the cluster
repository for the deployed values.

The server is a single stateful Java process, so it is a one-replica Deployment
with `strategy: Recreate` on a ReadWriteOnce volume — not a StatefulSet, which
would buy nothing. Ports are bound with `hostPort` rather than published through
a Service: a NodePort Service rewrites the client's source address, and Project
Zomboid's ban list works on IP.

### On an existing NixOS host

```nix
{
  inputs.nixzoid.url = "github:hcbt/nixzoid";

  # …

  imports = [ inputs.nixzoid.nixosModules.default ];

  services.zomboid = {
    enable = true;
    serverName = "apocalypse";
    stateDir = "/srv/zomboid";
    openFirewall = true;
    directConnectPorts = 16;

    workshopItems = [ "2392709985" "2857548524" ];
    mods = [ "tsarslib" "Brita_2" ];

    settings = {
      PublicName = "Knox County";
      MaxPlayers = 16;
      PVP = false;
    };
    sandbox = {
      Zombies = 3;
      ZombieLore.Speed = 2;
    };

    # Host paths, bind-mounted read-only. Never `settings` — that goes to the
    # world-readable store.
    adminPasswordFile = "/run/secrets/zomboid-admin";
    secretConfigFile = "/run/secrets/zomboid-config";
  };
}
```

Runs the server as an unprivileged systemd service inside a systemd-nspawn
container, with the saves bind-mounted from the host.

- **`serverName` names the config files** under `Server/` in the state
  directory. Changing it after first start makes the server write a fresh
  config and appear to have lost its settings — pick one before first boot.
- **`directConnectPorts`** is how many UDP ports above `port` to open; the
  server uses one per connected player. The default of 1 suits a small private
  server. Too few is invisible until the Nth player cannot connect.
- Networking shares the host namespace by default. `privateNetwork = true`
  forwards the ports instead, at the cost of rewriting the source address.

## Development

```
nix develop
nix flake check
nix fmt
```

`nix flake check` deliberately **never builds the server**. The depots are ~7G
and a check that downloaded them would make every commit an hour-long
operation; what is checked is everything that can go wrong without the game
content — that the derivations instantiate, that the launcher carries the right
arguments, and that the NixOS module wires the container correctly.
`nix build .#zomboid-image` is what proves the heavy half works.

Both platforms are checked **from either one**. The launcher checks read a
`passthru` string with its context discarded, so the macOS assertions run on the
Linux CI runner and the Linux ones run on a laptop, and neither downloads a
byte. Only an actual `nix build` of the server needs the matching host.

New files must be `git add`ed before any `nix` command sees them.
