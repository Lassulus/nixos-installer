{ config, lib, pkgs, ... }:
with import <stockholm/lib>;
{
  environment.systemPackages = [
    (pkgs.callPackage ./default.nix {})
  ];

  networking.wireless.enable = false;
  networking.networkmanager.enable = true;

  services.mingetty.autologinUser = lib.mkForce "root";
}
