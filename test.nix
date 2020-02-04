{ config, lib, pkgs, ... }:
{
  imports = [
    ./config.nix
  ];
  virtualisation.emptyDiskImages = [
    8000
  ];
  virtualisation.memorySize = 1500;
  boot.tmpOnTmpfs = true;

  programs.bash.promptInit = ''
    if ! test -e /tmp/install_started; then

      echo -n '
        welcome to the computer wizard
        first we will check for internet connectivity
      '

      read -p '(press enter to continue...)' key
      # touch /tmp/install_started
      nixos-installer
    fi
  '';

}
