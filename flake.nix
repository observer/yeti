{
  description = "Yeti — NixOS module and standalone CLI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Systems supported by the standalone package. The NixOS module
      # itself is system-agnostic.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkYeti = pkgs:
        let
          pythonEnv = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
        in
        pkgs.writeShellApplication {
          name = "yeti";
          # `incus` is required for the subprocess calls inside the script,
          # whether we're talking to a local socket or a remote.
          runtimeInputs = [ pkgs.incus ];
          text = ''
            exec ${pythonEnv}/bin/python3 ${./yeti} "$@"
          '';
        };
    in
    {
      # NixOS integration:
      nixosModules.default = import ./module.nix;
      nixosModules.yeti = self.nixosModules.default;

      # Standalone CLI
      #
      # Run with the local admin socket:
      #   nix run github:observer/yeti -- spec.yaml
      # User socket:
      #   nix run github:observer/yeti -- --user spec.yaml
      # Custom socket path:
      #   nix run github:observer/yeti -- --socket /run/foo/incus.sock spec.yaml
      # Configured incus remote:
      #   nix run github:observer/yeti -- --remote myhost spec.yaml
      packages = forAllSystems (system: {
        default = mkYeti nixpkgs.legacyPackages.${system};
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/yeti";
        };
      });
    };
}
