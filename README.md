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
nix build .#zomboid-server    # the launcher, runnable on any x86_64 Linux host
nix build .#zomboid-image     # the OCI image the cluster runs
```

Linux only, and honestly absent elsewhere rather than evaluating everywhere and
building in one place: DepotDownloader and `dockerTools` both need it.

## Getting the game

App **380870** splits the dedicated server across two depots, and both are
required:

| Depot    | What                                                                                          | Size           |
| -------- | --------------------------------------------------------------------------------------------- | -------------- |
| `380871` | Platform-independent content — `java/projectzomboid.jar`, `media/`, the Lua stdlib            | ~6.9G unpacked |
| `380873` | The Linux half — the bundled Azul Zulu JRE, the JNI natives in `linux64/`, the pzexe launcher | ~218M          |

Neither is useful alone: the jar is the server, and the natives are what it
`dlopen()`s on startup. Access is anonymous, so no Steam credentials are
involved anywhere.

### Updating to a new build

`manifestId` pins an exact build, which is the only way a Steam fetch can be a
fixed-output derivation — "whatever is current" has no hash. Steam's own
metadata API lists them:

```bash
curl -s https://api.steamcmd.net/v1/info/380870 | jq '.data["380870"].depots | {"380871","380873"} | map_values(.manifests.public.gid)'
```

Put the new gids in [`pkgs/zomboid-server/default.nix`](pkgs/zomboid-server/default.nix),
set both hashes to `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, and
build — Nix reports the real hash. There is no way to compute one without
downloading, and DepotDownloader only runs on Linux, so this is a Linux-host
operation.

## Making it run

Upstream ships `start-server.sh`, which `cd`s into the install directory and
runs a launcher that reads `ProjectZomboid64.json` and execs the bundled JRE.
None of that survives the Nix store: the install directory is read-only, and
every path in that json — the classpath, `-Djava.library.path`, even the heap
size — is relative to a working directory the server may no longer write to.

So the wrapper skips both and invokes the JVM directly with absolute paths,
carrying exactly the arguments upstream specified. Three of them are worth
knowing about, because getting any wrong produces a server that _starts_:

- **`-Djava.library.path`** — without it the server runs for several seconds and
  then dies on the first `dlopen` with an `UnsatisfiedLinkError` naming a class
  rather than the flag.
- **`steamclient.so`** — `libsteam_api.so` `dlopen()`s it by bare name and it
  ships in neither depot; it comes from the Steamworks redist (app 1007). Absent,
  the server starts, never reaches the Steam master server, and never appears in
  the in-game browser, with nothing in the log naming the missing library.
- **`-cachedir=` _and_ `HOME`** — the server resolves some paths from each. Set
  only one and state scatters across two directories, one of them in the store.

`checks.launcher-arguments` asserts on all of them, because every one of those
failures costs a full server start to discover.

## Configuring it

Mods and server settings arrive at **runtime, through the environment**. None of
it is baked into the package — that derivation carries ~7G of Steam depots, so a
mod list built into it would make adding one mod a full image rebuild and
re-push. Same reason the heap is an environment variable.

| Variable                      | What                                                     |
| ----------------------------- | -------------------------------------------------------- |
| `ZOMBOID_STATE_DIR`           | Saves, config and logs (`/data`)                         |
| `ZOMBOID_HEAP`                | JVM heap (`8g`)                                          |
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

`WorkshopItems=` and `Mods=` are **two separate keys and both are required** —
one says what to fetch, the other what to load. Only the first, and the server
downloads mods it never enables; only the second, and it enables mods it never
downloaded. Neither failure says anything useful in the log, so the module warns
when one is set without the other.

The server downloads the Workshop items itself on start, into the state volume.
Nothing is pinned, which is the trade: adding a mod costs a restart instead of a
rebuild, and a mod author's update lands on the next restart unannounced.

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

New files must be `git add`ed before any `nix` command sees them.
