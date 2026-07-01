# Yeti Example for NixOS: 
#
# In your system flake.nix:
#
#   {
#     inputs.yeti.url    = "github:observer/yeti";
#     inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
#
#     outputs = { self, nixpkgs, yeti, ... }: {
#       nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#         system = "x86_64-linux";
#         modules = [
#           yeti.nixosModules.default
#           ./configuration.nix
#         ];
#       };
#     };
#   }
#
# Then in configuration.nix use something like this:

{ ... }:

{
  virtualisation.incus = {
    enable = true;
    preseed = {
      # Set up incus:
      networks = [
        {
          name = "yet1";
          type = "bridge";
          description = "NAT bridge managed by Incus";
          config = {
            "ipv4.address" = "10.1.2.1/24";
            "ipv4.nat"     = "true";
            "ipv4.dhcp"    = "true";
            "ipv6.address" = "auto";
            "ipv6.nat"     = "true";
          };
        }
      ];

      projects = [
        {
          name = "bigfoot";
          config = {
            # see incus docs for explanation on `features.X` options 
            "features.images" = "true";
            "features.profiles" = "true";  
          };
        }
      ];

      profiles = [
        {
          name    = "default";
          project = "default";
          description = "Default profile - NAT via incus0";
          devices = {
            eth0 = {
              name    = "eth0";
              network = "yet1";
              type    = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
      ];

      storage_pools = [
        {
          name   = "default";
          driver = "zfs";
          config = {
            source = "tank/incus";
          };
        }
      ];

    };
  };

  services.resolved.enable = true;

  systemd.network.networks."yet1" = {
    matchConfig.Name = "yet1";
    networkConfig = {
      DNS = "10.1.2.1";
      Domains = "~incus";
    };
  };

  networking.firewall.trustedInterfaces = [ "yet1" ];

  # Instances can now conveniently and declaratively be defined:
  yeti = {

    # Minimal: just an image source + name (from the attr key).
    web-1 = {
      image.alias = "debian/12";
      image.server = "https://images.linuxcontainers.org";
    };

    # Fuller: project, type, profiles, config, devices.
    db-1 = {
      project = "default";
      type = "container";
      image = {
        alias = "debian/12";
        server = "https://images.linuxcontainers.org";
      };
      profiles = [ "default" ];
      config = {
        "limits.cpu" = "2";
        "limits.memory" = "4GB";
        "boot.autostart" = "true";
      };
      devices = {
        eth0 = {
          type = "nic";
          network = "incusbr0";
        };
        root = {
          type = "disk";
          path = "/";
          pool = "default";
          size = "20GB";
        };
      };
    };

    # Virtual machine pinned to a specific image fingerprint.
    builder = {
      type = "virtual-machine";
      image.fingerprint = "9260d88eda062b5a3be901dfc7595f0e05a9851bc0ad83c50b874e979aab00f6";
      profiles = [ "default" ];
    };

    # Override the name (e.g. when the attr key is a friendly handle but
    # the actual instance name needs to be something else).
    cache = {
      name = "redis-cache-01";
      image.alias = "debian/12";
      image.server = "https://images.linuxcontainers.org";
    };
  };
}
