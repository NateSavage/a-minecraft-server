{ nix-minecraft, sops-nix }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.minecraftServer;
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression optionalAttrs concatStringsSep;
  inherit (nix-minecraft.lib) collectFilesAt;
in
{
  imports = [
    nix-minecraft.nixosModules.minecraft-servers
    sops-nix.nixosModules.sops
  ];

  options.services.minecraftServer = {
    enable = mkEnableOption "a nix-minecraft-managed Minecraft server";

    serverName = mkOption {
      type = types.str;
      default = "MBTA";
      description = ''
        Name of this server instance. Used as the `services.minecraft-servers.servers`
        key, the systemd unit suffix (`minecraft-server-<name>.service`), and its data
        directory (`/srv/minecraft/<name>`).
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.neoforgeServers."neoforge-1_21_1-21_1_244";
      defaultText = literalExpression ''pkgs.neoforgeServers."neoforge-1_21_1-21_1_244"'';
      description = ''
        The server package to run, from nix-minecraft's overlay. Defaults to NeoForge
        21.1.244 for Minecraft 1.21.1, pinned to match MBTA's modpack. See the
        nix-minecraft README for `vanillaServers`, `fabricServers`, `quiltServers`,
        `paperServers` and `purpurServers` alternatives if you ever want an unmodded or
        differently-modded server instead.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 25579;
      description = "TCP port the server listens on.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to open `port` in the firewall. The RCON port is deliberately never
        opened here, regardless of this setting — see `rcon.enable`.
      '';
    };

    memory = mkOption {
      type = types.str;
      default = "16G";
      description = ''
        Java heap size, used for both `-Xmx` and `-Xms`. 16G is sized for MBTA's modpack
        (Cobblemon + Create + ~124 mods) — this is *heap only*, not total footprint.
        Metaspace for ~124 mods' worth of classes, GC bookkeeping, and native buffers add
        meaningful overhead on top, so budget for 16G+ of *physical host RAM*, not just a
        bigger `-Xmx`. Don't forget to leave some extra RAM for the OS.
      '';
    };

    extraJvmOpts = mkOption {
      type = types.listOf types.str;
      default = [
        "-XX:+UseG1GC"
        "-XX:+ParallelRefProcEnabled"
        "-XX:MaxGCPauseMillis=200"
      ];
      description = ''
        Extra JVM flags appended after `-Xmx`/`-Xms`, set to `[ ]` to fall back to the JVM's own defaults.
      '';
    };

    motd = mkOption {
      type = types.str;
      default = "Mags Bee Transit Authority";
      description = "MOTD shown in the multiplayer server list.";
    };

    difficulty = mkOption {
      type = types.enum [ "peaceful" "easy" "normal" "hard" ];
      default = "easy";
      description = "Game difficulty.";
    };

    maxPlayers = mkOption {
      type = types.ints.positive;
      default = 20;
      description = "Maximum number of concurrent players.";
    };

    whitelist = mkOption {
      type = types.attrsOf types.str;
      default = {
        nobodywasishere = "22d4f7ac-6b1c-440d-b9be-bb65019c3417";
        Fr0stByte212 = "804d5654-3b84-493d-ac3d-bf406c8843ee";
        FrogZilla10 = "bf85cd01-b6bb-42a0-bffd-d4288f6d532c";
        zpogre = "013985cd-66f9-4022-85df-4ea8f9b418de";
        poppyPotatoe = "c3aaf795-dd67-4a92-8203-18522be727e6";
        PixeLInc = "eab1f63c-feaa-41f9-ab0e-dbe11e9d4223";
        EEPOM = "4d41ce0f-1d15-4e82-b05e-e05ae6c763ac";
        ItsJustGeek = "7c730257-5dce-45c0-8921-bf937026b6df";
        zsixtyfour = "132ff8b2-a55e-40e4-8f76-3592b724ccde";
        LunarWisteria = "93b99e23-b02c-43c5-994e-88c319d62cf2";
        _Mr_Kittyhawk_ = "9aadb77d-6b0f-4269-8c71-7ee28e266acc";
        Kmeyerson = "5fb21b36-665c-4b5c-958b-079ffa64549c";
        Meheksie_ = "ef632ac2-b15e-4b86-898a-48514a6497ea";
      };
      example = literalExpression ''
        {
          Notch = "069a79f4-44e9-4726-a5be-fca90e38aaf5";
        }
      '';
      description = ''
        Whitelisted players as `username = uuid;`. Leaving this empty leaves the server
        open to anyone; adding an entry here also flips `white-list` on in
        server.properties. Look up UUIDs at https://mcuuid.net/ or similar.
      '';
    };

    operators = mkOption {
      type = types.attrsOf types.str;
      default = {
        nobodywasishere = "22d4f7ac-6b1c-440d-b9be-bb65019c3417";
        ItsJustGeek = "7c730257-5dce-45c0-8921-bf937026b6df";
      };
      example = literalExpression ''
        {
          Notch = "069a79f4-44e9-4726-a5be-fca90e38aaf5";
        }
      '';
      description = ''
        Server operators as `username = uuid;`, all granted permission level 4. For
        per-operator levels or `bypassesPlayerLimit`, set
        `services.minecraft-servers.servers.<serverName>.operators` directly instead —
        see the nix-minecraft README.
      '';
    };

    bannedPlayers = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Banned players as `username = uuid;`. For ban metadata (reason, expiry, source),
        set `services.minecraft-servers.servers.<serverName>.bannedPlayers` directly
        instead — see the nix-minecraft README.
      '';
    };

    extraServerProperties = mkOption {
      type = with types; attrsOf (oneOf [ bool int str ]);
      default = { };
      example = literalExpression ''
        {
          view-distance = 12;
          pvp = false;
          gamemode = "survival";
        }
      '';
      description = ''
        Extra entries merged into server.properties, for anything not already covered
        by an option above. Takes precedence over this module's own defaults for the
        same key. See https://minecraft.wiki/w/Server.properties for the full list.
      '';
    };

    modpack = mkOption {
      type = types.nullOr types.package;
      default = pkgs.fetchModrinthModpack {
        src = ../modpacks/mbta;
        packHash = "sha256-gtLSeIlmYXm+uNyhzDQ81Fh3958jtY7UsYsvtBcfBvk=";
        side = "server";
      };
      defaultText = literalExpression ''
        pkgs.fetchModrinthModpack { src = ../modpacks/mbta; packHash = "..."; side = "server"; }
      '';
      description = ''
        A modpack derivation (see `pkgs.fetchModrinthModpack`), whose `mods/` directory
        is symlinked read-only into the server. `null` means no mods are Nix-managed —
        the server's own `mods/` directory is left completely unmanaged, so jars copied
        in by hand (e.g. over SFTP) persist untouched across rebuilds. Only meaningful
        when `package` is a mod-loader build (NeoForge/Fabric/Quilt/Forge) — Paper/vanilla
        don't read `mods/`.
      '';
    };

    rcon = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to enable RCON and wire its password from `sopsFile` via sops-nix.
          Requires `sopsFile` to be set. The RCON port is never opened in the firewall —
          it should only ever be reached over loopback, a VPN/tailnet, or an SSH tunnel.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 25575;
        description = "RCON port. Intentionally not opened in the firewall.";
      };
    };

    sopsFile = mkOption {
      type = types.path;
      example = literalExpression "./secrets/minecraft.yaml";
      description = ''
        Path to a sops-encrypted YAML file, in *your* server flake/repo, containing a
        `minecraft-rcon-password` key. Required when `rcon.enable` is true (the
        default). See the README for how to create one.
      '';
    };
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [ nix-minecraft.overlays.default ];

    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "neoforge" ];

    services.minecraft-servers = {
      enable = true;
      eula = true;

      environmentFile = mkIf cfg.rcon.enable
        config.sops.templates."minecraft-${cfg.serverName}-rcon.env".path;

      servers.${cfg.serverName} = {
        enable = true;
        package = cfg.package;
        jvmOpts = concatStringsSep " " ([ "-Xmx${cfg.memory}" "-Xms${cfg.memory}" ] ++ cfg.extraJvmOpts);
        whitelist = cfg.whitelist;
        operators = cfg.operators;
        bannedPlayers = cfg.bannedPlayers;

        symlinks = {
          "server-icon.png" = ../server-config/server-icon.png;
        }
        // optionalAttrs (cfg.modpack != null) {
          "mods" = "${cfg.modpack}/mods";
        };

        # MBTA's real per-mod config, one `files` entry per file (via collectFilesAt)
        # rather than one entry for the whole `config` directory — each of these specific
        # files gets reset to its committed value on every restart (correct: this is
        # curated pack config, meant to be authoritative), while any file a mod
        # generates outside this list (first-run config for a mod with no override here,
        # or extra files a covered mod creates alongside its main one) is left
        # completely alone, since nix-minecraft only ever touches paths it's told about.
        files = collectFilesAt ../server-config "config";

        serverProperties =
          {
            # MBTA's real server.properties, as exported alongside the modpack — set
            # explicitly rather than left to whatever nix-minecraft/vanilla happens to
            # default to, so behavior can't silently drift on an update.
            "accepts-transfers" = false;
            "allow-flight" = false;
            "allow-nether" = true;
            "broadcast-console-to-ops" = true;
            "broadcast-rcon-to-ops" = true;
            "enable-command-block" = false;
            "enable-jmx-monitoring" = false;
            "enable-query" = false;
            "enable-status" = true;
            "enforce-secure-profile" = true;
            "enforce-whitelist" = false;
            "entity-broadcast-range-percentage" = 100;
            "force-gamemode" = false;
            "function-permission-level" = 2;
            "gamemode" = "survival";
            "generate-structures" = true;
            "hardcore" = false;
            "hide-online-players" = false;
            "initial-enabled-packs" = "vanilla";
            "level-name" = "world";
            "level-seed" = "8451539628539922719";
            "level-type" = "minecraft:normal";
            "log-ips" = true;
            "max-chained-neighbor-updates" = 1000000;
            "max-tick-time" = 60000;
            "max-world-size" = 29999984;
            "network-compression-threshold" = 256;
            "online-mode" = true;
            "op-permission-level" = 4;
            "player-idle-timeout" = 0;
            "prevent-proxy-connections" = false;
            "pvp" = true;
            "query.port" = cfg.port;
            "rate-limit" = 0;
            "region-file-compression" = "deflate";
            "require-resource-pack" = false;
            "simulation-distance" = 10;
            "spawn-animals" = true;
            "spawn-monsters" = true;
            "spawn-npcs" = true;
            "spawn-protection" = 2;
            "sync-chunk-writes" = true;
            "use-native-transport" = true;
            "view-distance" = 16;
          }
          // {
            server-port = cfg.port;
            motd = cfg.motd;
            difficulty = cfg.difficulty;
            max-players = cfg.maxPlayers;
            white-list = cfg.whitelist != { };
            enable-rcon = cfg.rcon.enable;
          }
          // optionalAttrs cfg.rcon.enable {
            "rcon.port" = cfg.rcon.port;
            "rcon.password" = "@RCON_PASSWORD@";
          }
          // cfg.extraServerProperties;
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    sops.secrets."minecraft-rcon-password" = mkIf cfg.rcon.enable {
      sopsFile = cfg.sopsFile;
    };

    sops.templates."minecraft-${cfg.serverName}-rcon.env" = mkIf cfg.rcon.enable {
      content = ''
        RCON_PASSWORD="${config.sops.placeholder."minecraft-rcon-password"}"
      '';
      restartUnits = [ "minecraft-server-${cfg.serverName}.service" ];
    };
  };
}
