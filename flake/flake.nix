{
  description = "finix cloud image: BIOS boot, virtio disks, key-only SSH";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    finix.url = "github:finix-community/finix";
  };

  outputs =
    { nixpkgs, finix, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      nixosConfigurations.finixos = finix.lib.finixSystem {
        inherit (pkgs) lib;

        # finix does not auto-import modules the way NixOS does. This list is
        # the complete set.
        modules = with finix.nixosModules; [
          { nixpkgs.pkgs = nixpkgs.lib.mkDefault pkgs; }
          ./finix/configuration.nix
          nix-daemon
          openssh
          sysklogd
          limine
          sudo
          polkit
          getty
          bash
          dhcpcd
        ];

        specialArgs = {
          modulesPath = toString nixpkgs + "/nixos/modules";
        };
      };
    };
}
