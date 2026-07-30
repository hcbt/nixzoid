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

## Running it

### On Kubernetes

The chart is coldstart's; this repository supplies only the image. See
`apps/zomboid/values.yaml` in the cluster repository for the deployed values.

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
