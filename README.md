# a-minecraft-server

A NixOS flake that runs a NeoForge Minecraft server with a bunch of mods.

## Quick start

**1. Add as an input** (needs `nix.settings.experimental-features = [ "nix-command" "flakes" ];`):

```nix
a-minecraft-server = {
  url = "github:NateSavage/a-minecraft-server";
  inputs.nixpkgs.follows = "nixpkgs";     # recommended
  inputs.sops-nix.follows = "sops-nix";   # only if you already have this input
};
```

Then `imports = [ a-minecraft-server.nixosModules.default ];` on your host.

**2. Create the RCON secret** (this repo ships none — needs a file in *your* repo):

```bash
nix shell nixpkgs#ssh-to-age -c ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub   # -> age1...
```

Add that as a recipient in your `.sops.yaml`, then:

```bash
openssl rand -hex 32   # use as the password below — avoid & and \
nix shell nixpkgs#sops -c sops secrets/minecraft.yaml
```
```yaml
minecraft-rcon-password: "<the hex string>"
```

Point sops-nix at the host key if you haven't already:
`sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];`

**3. Configure:**

```nix
services.minecraftServer = {
  enable = true;
  sopsFile = ./secrets/minecraft.yaml;
  whitelist.Notch = "069a79f4-44e9-4726-a5be-fca90e38aaf5";
  operators.Notch = "069a79f4-44e9-4726-a5be-fca90e38aaf5";
};
```

**4. Deploy:** `sudo nixos-rebuild switch --flake .#myhost`. Runs as
`minecraft-server-MBTA.service`; first boot takes several minutes (mod init + Cobblemon data
processing).

## Options

All under `services.minecraftServer.*`:

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `serverName` | `"MBTA"` | unit suffix + data dir |
| `package` | NeoForge `21.1.244` / Java 21 | pinned to match the modpack |
| `port` | `25579` | TCP only |
| `openFirewall` | `true` | never opens the RCON port |
| `memory` | `"16G"` | heap only, see host RAM note in the option doc |
| `extraJvmOpts` | G1GC flags | |
| `motd` / `difficulty` / `maxPlayers` | generic / `"easy"` / `20` | |
| `whitelist` / `operators` / `bannedPlayers` | `{}` | `{ username = "uuid"; }`; empty on purpose, see [Gotchas](#gotchas) |
| `extraServerProperties` | `{}` | highest-precedence override for anything else |
| `modpack` | MBTA's real pack | `fetchModrinthModpack` derivation; `null` = unmanaged `mods/` |
| `rcon.enable` / `rcon.port` | `true` / `25575` | needs `sopsFile`; never firewalled |
| `sopsFile` | *(required)* | your sops-encrypted YAML with `minecraft-rcon-password` |

## Gotchas

- **Unfree license**: NeoForge's package is `unfreeRedistributable`; the module already sets
  a scoped `allowUnfreePredicate` for just `"neoforge"`, so this shouldn't bite you — but if
  your own config sets its own predicate, make sure it also covers `"neoforge"`.
- **`whitelist`/`operators`/`motd` default empty/generic on purpose** — this repo is public,
  no reason to bake a friend group's usernames into it. Set real values from your own
  deployment-specific config.
- **Updating the modpack**: replace `modpacks/mbta/modrinth.index.json`, then re-bootstrap
  `packHash` in `modules/minecraft-server.nix` — set it to `pkgs.lib.fakeHash`, run
  `nix build .#mbtaModpack`, copy the real hash from the mismatch error. Also re-copy
  `server-config/config/` if the new pack needs different per-mod config (that's sourced from
  a real server's own config, not the pack's own `overrides/`, which is client-captured).
- **RCON** is never firewalled — reach it over a tunnel:
  `ssh -L 25575:127.0.0.1:25575 myhost`, then
  `mcrcon -H 127.0.0.1 -P 25575 -p "$(sudo cat /run/secrets/minecraft-rcon-password)"`.
- **Test without touching a real server**: `nix build .#mbtaModpack` / `.#mbtaServer` /
  `nix flake check` (the last one evaluates the module's config without a full system build).
- Enabling the module means agreeing to
  [Mojang's EULA](https://account.mojang.com/documents/minecraft_eula) — it sets `eula = true`
  for you.

## Troubleshooting

- Logs: `journalctl -u minecraft-server-MBTA -e`
- Console: `tmux -S /run/minecraft/MBTA.sock attach` (`Ctrl+b` `d` to detach)
- Clean exit, no crash, mods won't load → check `logs/latest.log` for `ModLoadingException`,
  *not* journalctl — the console isn't journald-captured under the default tmux management
- No stack trace at all → check for `SIGSYS`/seccomp denials before assuming it's a mod bug
- Changed the RCON password → restarts automatically on switch; `systemctl restart
  minecraft-server-MBTA` if it somehow doesn't
