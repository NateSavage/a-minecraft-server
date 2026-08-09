# a-minecraft-server

A NixOS flake that runs **MBTA** — a modded [NeoForge](https://neoforged.net/) Minecraft
server (Cobblemon + Create + a ~124-mod QoL/utility stack) — built on top of two upstream
projects:

- [`nix-minecraft`](https://github.com/Infinidoge/nix-minecraft) — packages every Minecraft
  server flavor/version and provides the `services.minecraft-servers` module that actually
  runs it under systemd.
- [`sops-nix`](https://github.com/Mic92/sops-nix) — decrypts the RCON password at activation
  time so it never sits in plaintext in the Nix store or in this git history.

This repo doesn't stand on its own — it's meant to be added as an **input to your existing
server flake**, which then imports the module it exports.

Everything below — the NeoForge pin, the mod list, MBTA's actual server.properties,
whitelist, and ops — has been built and verified end-to-end with real Nix (`nix flake check`
plus actually building the modpack and the NeoForge server package), not just written and
hoped for.

## What you get

`services.minecraftServer`, a single opinionated option tree that:

- Is MBTA, out of the box: NeoForge `21.1.244` for Minecraft `1.21.1`, its real
  server.properties, whitelist, and ops — not a generic engine you configure into shape.
- Fetches and hash-verifies all ~124 mods from Modrinth during the Nix build (not at server
  runtime) and symlinks them in read-only, alongside MBTA's real per-mod config.
- Applies the nix-minecraft overlay, a scoped unfree-package allowance (NeoForge's server
  package is licensed `unfreeRedistributable`), and firewall rules for you.
- Enables RCON with its password sourced from a sops-nix secret — set once, never touches
  the Nix store, never gets committed in plaintext.
- Opens only the game port. The RCON port is **never** added to the firewall — see
  [Security notes](#security-notes).

Everything this module doesn't expose is still reachable through nix-minecraft's own
`services.minecraft-servers.servers.<name>.*` options — this module just fills in MBTA's
defaults and the secrets plumbing on top.

## Quick start

### 0. Prerequisites

Your server needs flakes enabled:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

### 1. Add this flake as an input

In your server's own `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    a-minecraft-server = {
      url = "github:NateSavage/a-minecraft-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, a-minecraft-server, ... }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        a-minecraft-server.nixosModules.default  # same module as .mbta / .minecraftServer
      ];
    };
  };
}
```

> If your server flake already has its own `sops-nix` input, also add
> `a-minecraft-server.inputs.sops-nix.follows = "sops-nix";` so both resolve to the same
> module — see [Sharing inputs with an existing flake](#sharing-inputs-with-an-existing-flake).

### 2. Set up the secret

The module needs one secret: an RCON password, in a sops-encrypted file that lives **in your
own server repo** (this repo intentionally ships none). If you don't already have sops-nix's
age key set up on this host, the simplest option is to reuse its SSH host key — no extra key
file to generate or back up.

```bash
# On the server — reads the public half of the host key, which is world-readable:
nix shell nixpkgs#ssh-to-age -c ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub
# -> age1.......................................  (this is the recipient's public key)
```

In your server repo, add a `.sops.yaml`:

```yaml
keys:
  - &myserver age1......................................... # output from above
creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *myserver
```

Generate a password and create the encrypted secrets file (this opens `$EDITOR`):

```bash
openssl rand -hex 32   # copy this
nix shell nixpkgs#sops -c sops secrets/minecraft.yaml
```

In the editor, add:

```yaml
minecraft-rcon-password: "<paste the hex string from openssl>"
```

Save and quit — `secrets/minecraft.yaml` on disk is now ciphertext and safe to commit.

> A hex password is deliberate: nix-minecraft's `@VAR@` substitution runs the file through
> `awk`, where `&` and `\` in the replacement text are special. Hex avoids both.

Then, on the server's system config, point sops-nix at the same host key (skip this if you
already have `sops.age.sshKeyPaths` or `sops.age.keyFile` configured for other secrets):

```nix
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

### 3. Configure

MBTA's identity (mods, config, NeoForge version, memory, JVM tuning) is already set. What's
left is deployment-specific and deliberately *not* baked into this public repo —
`whitelist`/`operators`/`motd` default empty/generic on purpose (see
[Security notes](#security-notes)):

```nix
{
  services.minecraftServer = {
    enable = true;
    sopsFile = ./secrets/minecraft.yaml;

    motd = "however you want it to show up in the server list";
    whitelist = {
      Notch = "069a79f4-44e9-4726-a5be-fca90e38aaf5";
    };
    operators = {
      Notch = "069a79f4-44e9-4726-a5be-fca90e38aaf5";
    };
  };
}
```

See [Options reference](#options-reference) for everything else you can override.

### 4. Deploy

```bash
sudo nixos-rebuild switch --flake .#myserver
```

The server starts under `minecraft-server-MBTA.service`, with its world at
`/srv/minecraft/MBTA`. Expect **first boot to take several minutes**, not seconds — every mod
generates its default config/registries on first launch, and Cobblemon in particular does a
fair amount of data processing before the server reports ready. The Nix build itself (fetching
and verifying ~124 mods) also takes a while the first time; subsequent rebuilds reuse the
cached result unless the modpack changes.

## Options reference

All under `services.minecraftServer.*`:

| Option                   | Default                          | Description                                              |
| ------------------------ | --------------------------------- | ---------------------------------------------------------- |
| `enable`                 | `false`                           | Turn the server on.                                        |
| `serverName`              | `"MBTA"`                          | Instance name — unit suffix and data directory.            |
| `package`                | NeoForge `21.1.244` / MC `1.21.1` | Server flavor/version. See [Running something other than MBTA](#running-something-other-than-mbta). |
| `port`                   | `25579`                           | Game port; opened in the firewall if `openFirewall`. Also used for `query.port` (query itself is off). |
| `openFirewall`           | `true`                            | Open `port`. Never affects the RCON port.                  |
| `memory`                 | `"16G"`                           | JVM `-Xmx`/`-Xms`. Heap only — see the option's own doc comment for host RAM sizing. |
| `extraJvmOpts`           | G1GC tuning flags                 | Extra flags appended after `-Xmx`/`-Xms`.                   |
| `motd`                   | `"A NeoForge Minecraft Server"`   | Server list MOTD. Generic on purpose — see [Security notes](#security-notes). |
| `difficulty`             | `"easy"`                          | `peaceful` / `easy` / `normal` / `hard`.                    |
| `maxPlayers`             | `20`                              | Concurrent player cap.                                     |
| `whitelist`              | `{}`                              | `{ username = "uuid"; }`. Empty on purpose — see [Security notes](#security-notes). Non-empty also sets `white-list = true`. |
| `operators`              | `{}`                              | `{ username = "uuid"; }`, all at permission level 4. Empty on purpose — see [Security notes](#security-notes). |
| `bannedPlayers`          | `{}` (currently empty for real)   | `{ username = "uuid"; }`. For ban metadata, set nix-minecraft's own option directly. |
| `extraServerProperties`  | `{}`                              | Anything else for `server.properties`, merged in last, highest precedence. |
| `modpack`                | MBTA's real modpack (built from `modpacks/mbta/`) | A `pkgs.fetchModrinthModpack` derivation; its `mods/` gets symlinked in. `null` = unmanaged `mods/` (hand-drop jars). See [The modpack](#the-modpack). |
| `rcon.enable`            | `true`                            | Requires `sopsFile`.                                        |
| `rcon.port`              | `25575`                           | Never opened in the firewall.                                |
| `sopsFile`               | *(required if `rcon.enable`)*     | Path to your sops-encrypted YAML with `minecraft-rcon-password`. |

MBTA's full real `server.properties` (everything not in the table above — `pvp`, `level-seed`,
`view-distance`, `spawn-protection`, etc.) is baked into the module directly rather than left
to whatever nix-minecraft/vanilla happens to default to. Override any of it via
`extraServerProperties`.

## NeoForge

MBTA is pinned to an *exact* NeoForge build — `pkgs.neoforgeServers."neoforge-1_21_1-21_1_244"`
— rather than the floating "latest for this Minecraft version" alias, so it always matches
what the modpack was actually built and tested against. A few things worth knowing:

- **Unfree license**: NeoForge's server package is marked `unfreeRedistributable` in
  nixpkgs — building it fails outright ("Refusing to evaluate package ... unfree license")
  without an allowance. This module sets
  `nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "neoforge" ];`
  for you, scoped to just that package name rather than a blanket `allowUnfree = true`. If
  your own system config already sets its own `allowUnfreePredicate`, make sure it also
  covers `"neoforge"` — see the option's own comment in
  [modules/minecraft-server.nix](modules/minecraft-server.nix).
- Unlike Fabric/Quilt, NeoForge packages in nix-minecraft don't support
  `.override { loaderVersion = ...; }` — only builds already baked into nix-minecraft's own
  lockfiles are selectable. Bumping the NeoForge version means bumping the `nix-minecraft`
  flake input to a revision that has it.
- `flake.lock` already pins `nix-minecraft` to a fixed revision, so this pin can't break on
  its own — only a deliberate `nix flake update`/`--update-input nix-minecraft` re-exposes any
  risk. If a future revision's lockfiles ever drop this exact build, the failure is a loud,
  immediate `error: attribute 'neoforge-1_21_1-21_1_244' missing` at evaluation time — before
  anything touches the running server, not a silent breakage. Test a `nix-minecraft` bump with
  `nix build .#mbtaServer` before switching to it.

## The modpack

MBTA's ~124 mods (all hosted on Modrinth) are delivered as a single pinned
[Modrinth modpack](https://docs.modrinth.com/modpacks/format_definition) via
`pkgs.fetchModrinthModpack`, not as ~124 individually-pinned mods. Its per-mod *config*,
though, comes from a separate source — here's the full picture:

- **`modpacks/mbta/modrinth.index.json`** — the pack manifest (mod list, versions, download
  URLs, hashes). Drives `services.minecraftServer.modpack`, which Nix fetches and
  sha512-verifies during the build (not at server runtime — the running server never needs
  internet access for this) and symlinks into `mods/` read-only. 4 of the 128 listed files are
  client-only and correctly excluded (`side = "server"`); 19 more are present but
  `.disabled`-suffixed (as exported) and simply never loaded, since NeoForge's mod scanner
  only picks up files actually ending in `.jar`.
- **`server-config/config/`** — MBTA's real per-mod config (214 files), copied in via
  nix-minecraft's `collectFilesAt` helper as one `files` entry *per file*, not one entry for
  the whole directory. That granularity matters: each of these specific files gets reset to
  its committed value on every restart (correct — this is curated pack config, meant to be
  authoritative), while anything a mod generates *outside* this list — first-run config for a
  mod with no override here, or extra files a covered mod creates alongside its main one — is
  left completely alone, since nix-minecraft only ever touches paths it's told about.

  This is sourced from a direct copy of the real server's own config, not from the modpack's
  own bundled `overrides/` — the modpack export was captured from a *client* instance and
  includes client-only mod config a server would never generate, while `server-config/config`
  is what the server itself actually produced. Also cleaned of things that don't belong: two
  `.DS_Store`/`__MACOSX` artifacts from macOS zipping, JEI's per-world bookmark/search history
  (tied to specific worlds/server instances that no longer apply here), a Chunky
  pre-generation task-progress file (operational state, not config — resetting it every
  restart would fight Chunky's own resume tracking), and a couple of Spark profiler temp/log
  files.
- **`server-config/server-icon.png`** — symlinked in as `server-icon.png`, read-only like the
  mods themselves.

### Updating the modpack

1. Re-export the pack (e.g. from the Modrinth App or similar) and replace
   `modpacks/mbta/modrinth.index.json` (and `overrides/` if your workflow produces one — it's
   not currently used here, since config comes from `server-config/` instead; see above).
2. Double check the new `modrinth.index.json`'s `dependencies.minecraft`/`dependencies.neoforge`
   fields still say `1.21.1`/`21.1.244` (or update the `package` pin to match if you're
   intentionally moving versions) — a mismatch would still build fine, since Nix just fetches
   whatever the manifest says, and would only surface as mod-loading failures in the server
   log.
3. **Re-bootstrap `packHash`** in `modules/minecraft-server.nix`: set it to `pkgs.lib.fakeHash`
   temporarily, run `nix build .#mbtaModpack`, and copy the *real* hash Nix reports in the
   resulting mismatch error back into the option. This is a fixed-output derivation (fetching
   ~124 files during the build is inherently impure), so there's no separate prefetch tool for
   the aggregate hash the way there is for a single mod via nix-minecraft's own
   `nix-modrinth-prefetch`. A build this size can fail partway through on one bad URL before
   ever reporting a hash — expect a possible retry or two, on a stable connection. The
   resulting hash is portable across machines (it's a content hash, not tied to the build
   machine).
4. If `server-config/config/` also needs updating for the new mod set, copy in the new files
   the same way — real per-mod config from an actual running server, not the client-side
   `overrides/` from the pack export (see above for why).

**Adding one extra mod without a full re-export**: `fetchModrinthModpack`'s result has an
`.addFiles` helper for exactly this —
`(pkgs.fetchModrinthModpack { ... }).addFiles { "mods/extra.jar" = pkgs.fetchurl { ... }; }` —
rather than hand-editing the manifest. You'd override `services.minecraftServer.modpack`
entirely with a call shaped like this from your own config.

**Verifying without touching a real server**: `nix build .#mbtaModpack` builds and verifies
just the modpack; `nix build .#mbtaServer` builds the NeoForge server package alone;
`nix flake check` runs a lighter evaluation-only check (`checks.moduleEval`) that forces the
module's config without a full system build. All three exist as flake outputs for exactly
this — CI runs the same commands.

## Running something other than MBTA

Every default above is just a default. Note that if you override `package` to something
unmodded, MBTA's baked-in server.properties (`level-seed`, `spawn-protection`, etc.) and
`modpack` still apply unless you also override those — probably not what you want for e.g.
plain vanilla:

```nix
services.minecraftServer = {
  package = pkgs.paperServers.paper;   # latest Paper, unmodded
  modpack = null;                       # don't try to symlink NeoForge mods into it
  extraServerProperties = { }; # or override individual MBTA-specific keys as needed
};
```

See the [nix-minecraft README](https://github.com/Infinidoge/nix-minecraft#packages) for
`vanillaServers`, `fabricServers`, `quiltServers`, `purpurServers`, and other `neoforgeServers`
builds.

## Common tweaks

### Extra server.properties

```nix
services.minecraftServer.extraServerProperties = {
  view-distance = 12;
  pvp = false;
};
```

### Running a second server alongside MBTA

`services.minecraftServer` is a singleton. For a second server, define it directly via
nix-minecraft's own `services.minecraft-servers.servers.<name2>`. Note that
`services.minecraft-servers.environmentFile` is global to *all* servers under that module —
if the second server also needs a secret, either extend this module's sops template with a
differently-named variable, or give the second server its own `sops.templates` entry and
reconcile the two into one `environmentFile`.

## Security notes

- Enabling this module means you're agreeing to
  [Mojang's EULA](https://account.mojang.com/documents/minecraft_eula) — the module sets
  `eula = true` for you, since the server won't start otherwise.
- RCON's port is intentionally excluded from `networking.firewall.allowedTCPPorts`
  regardless of `openFirewall`. Reach it over loopback, a VPN/tailnet, or an SSH tunnel:
  ```bash
  ssh -L 25575:127.0.0.1:25575 myserver
  nix shell nixpkgs#mcrcon -c mcrcon -H 127.0.0.1 -P 25575 -p "$(sudo cat /run/secrets/minecraft-rcon-password)"
  ```
  (`sudo` because the decrypted secret is root-only-readable by default.)
- If your router forwards `port` to this host for public play, that forwarding is configured
  on the router, not here — don't forward the RCON port.
- `whitelist`/`operators`/`motd` default empty/generic on purpose, even though Minecraft
  usernames and UUIDs aren't secret (anyone can resolve one from the other via Mojang's own
  API) — this repo is public, and there's no reason to tie a specific friend group to it by
  default. Set the real values from your own deployment-specific config instead — see
  [Sharing inputs with an existing flake](#sharing-inputs-with-an-existing-flake) for the
  general pattern; concretely, that's `common/services/minecraft.nix` in this server's own
  infra repo.

## Sharing inputs with an existing flake

If your server flake already declares its own `nixpkgs` and/or `sops-nix` inputs, pin this
flake's copies to the same ones with `follows`. Otherwise you end up with two separately
locked copies of each — at best extra evaluation work, at worst two non-identical copies of
the `sops-nix` module fighting over the same `sops.*` options if their versions drift:

```nix
a-minecraft-server = {
  url = "github:NateSavage/a-minecraft-server";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.sops-nix.follows = "sops-nix"; # only if you already have this input
};
```

## Troubleshooting

- **Logs**: `journalctl -u minecraft-server-MBTA -e`
- **Live console** (default tmux management): `tmux -S /run/minecraft/MBTA.sock attach`,
  detach with `Ctrl+b` `d`. (nix-minecraft also supports a systemd-socket-based management
  mode with `journalctl`-visible console output — see its README.)
- **"Refusing to evaluate package ... unfree license"**: something is overriding this
  module's `nixpkgs.config.allowUnfreePredicate` — see [NeoForge](#neoforge) above.
- **First boot is slow**: several minutes is normal for this mod count, not a hang — see
  [Quick start](#4-deploy).
- **Server dies with no Java stack trace**: check `journalctl` for `SIGSYS`/seccomp denials
  before assuming it's a mod bug. nix-minecraft's syscall-filter hardening is tuned mainly
  against vanilla/Paper/Fabric workloads, and a ~124-mod stack is less-audited territory — if
  a mod does anything syscall-unusual, the kill looks like a mysterious crash rather than a
  normal exception. If it happens, loosening
  `systemd.services.minecraft-server-MBTA.serviceConfig.SystemCallFilter` with `lib.mkForce`
  from your own config is the fix path.
- **`Permission denied` in the logs**: check for filesystem hardening (`ProtectHome`, etc.)
  conflicting with a mod trying to write somewhere unexpected — same troubleshooting shape as
  above, and inherent to running any large modpack under systemd sandboxing (mod authors
  don't generally test against it).
- **Modpack built fine but mods won't load**: a green `nix build` only proves the manifest's
  URLs resolved and hashes matched — it says nothing about NeoForge's own mod-loading
  compatibility (missing dependency, version clash, a client-only mod Modrinth mis-tagged as
  server-safe). Treat a successful build as necessary, not sufficient; the real check is the
  server log on first boot.
- **Changed the RCON password**: `nixos-rebuild switch` restarts the server automatically
  (via sops-nix's `restartUnits`). If it somehow doesn't,
  `systemctl restart minecraft-server-MBTA`.
- **Whitelist/ops edited in-game aren't sticking**: this config is the source of truth and
  gets rewritten on every restart — make changes here, not with in-game commands.
