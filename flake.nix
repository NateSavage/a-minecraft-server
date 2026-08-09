{
  description = "NeoForge based Minecraft server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-minecraft = {
      url = "github:Infinidoge/nix-minecraft";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, nix-minecraft, sops-nix, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      minecraftServerModule = import ./modules/minecraft-server.nix { inherit nix-minecraft sops-nix; };

      # A throwaway NixOS system used only to force evaluation of the module
      evalTestSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          minecraftServerModule
          {
            services.minecraftServer.enable = true;
            services.minecraftServer.sopsFile = ./flake.nix;
          }
        ];
      };
    in
    {
      nixosModules.default = minecraftServerModule;
      nixosModules.minecraftServer = minecraftServerModule;

      packages.${system} = {
        # The modpack, lets the `packHash` bootstrap run as `nix build .#mbtaModpack` without needing a target host config
        mbtaModpack = evalTestSystem.config.services.minecraftServer.modpack;

        # The NeoForge server package, sanity-checks the pin actually builds without pulling in a full system.
        mbtaServer = evalTestSystem.config.services.minecraftServer.package;
      };

      checks.${system}.moduleEval =
        pkgs.writeText "mbta-module-eval-ok" (
          builtins.toJSON {
            inherit
              (evalTestSystem.config.services.minecraft-servers.servers.MBTA)
              serverProperties
              whitelist
              operators
              ;
            symlinkKeys = builtins.attrNames evalTestSystem.config.services.minecraft-servers.servers.MBTA.symlinks;
            fileKeys = builtins.attrNames evalTestSystem.config.services.minecraft-servers.servers.MBTA.files;
            environmentFile = evalTestSystem.config.services.minecraft-servers.environmentFile;
          }
        );
    };
}
