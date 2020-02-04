{ config, lib, pkgs, ... }:

let

  fzfmenu = pkgs.writers.writeDash "fzfmenu" ''
    ${pkgs.fzf}/bin/fzf --reverse "$@"
  '';

  dmenu-fzf = pkgs.writers.writeDashBin "dmenu" ''
    PROMPT=">"
    for i in "$@"
    do
    case $i in
      -p)
      PROMPT="$2"
      shift
      shift
      break
      ;;
    esac

    ${fzfmenu} --print-query --prompt="$PROMPT" "$@"
  '';

  nm-dmenu = pkgs.writers.writeDashBin "nm-dmenu" ''
    export PATH=$PATH:${dmenu-fzf}/bin:${pkgs.networkmanagerapplet}/bin
    exec ${pkgs.networkmanager_dmenu}/bin/networkmanager_dmenu "$@"
  '';

in pkgs.writers.writeDashBin "nixos-installer" ''
  set -efu

  export PATH=$PATH:${lib.makeBinPath (with pkgs; [
    findutils
    utillinux
    fzf
    libxfs.bin
    zfs
    mount
    nm-dmenu
    gptfdisk
    cryptsetup
  ])}

  until ping -c1 8.8.8.8; do
    nm-dmenu
    sleep 10
  done

  if [ -z "''${keyboard_layout+x}" ]; then
    keyboard_layout=$(
      find -L /run/current-system/etc/kbd/keymaps/ -type f \
        | sed 's,.*/\([^\.]*\)\..*,\1,' \
        | ${fzfmenu} --prompt='choose your keyboard layout'
    )
  fi
  loadkeys "$keyboard_layout"

  if [ -z "''${dev+x}" ]; then
    dev=$(
      lsblk -a -d \
        | grep -Ev 'loop|ram' \
        | tail +2 \
        | ${fzfmenu} --prompt='choose block device to install to: '
    )
    dev="/dev/$(set -- $dev ; echo "$1")"
  fi

  if [ -z "''${bootloader+x}" ]; then
    bootloader=$(echo -n '${''
      1. GRUB with EFI Support
      2. systemd-boot
      3. GRUB without EFI support
    ''}' | ${fzfmenu} --prompt 'choose bootloader: ')
    case "$bootloader" in
      1*)
        bootloader="grub"
        ;;
      2*)
        bootloader="systemd"
        ;;
      3*)
        bootloader="grub_no-efi"
        ;;
    esac
  fi

  if [ -z "''${disk_layout+x}" ]; then
    disk_layout=$(echo -n '${''
      1. full disk encryption with one big partition
      2. full disk encryption with LVM
      3. ZFS with native Encryption
      4. No Encryption
    ''}' | ${fzfmenu} --prompt 'choose disk layout: ')
    case "$disk_layout" in
      1*)
        disk_layout="FDE"
        ;;
      2*)
        disk_layout="FDE_LVM"
        ;;
      3*)
        disk_layout="ZFS"
        ;;
      4*)
        disk_layout="PLAIN"
        ;;
    esac
  fi

  if [ "$disk_layout" != "ZFS" ]; then
    rootFS=$(echo -n '${''
      xfs
      ext4
      ZFS
    ''}' | ${fzfmenu} --prompt 'choose root filesystem: ')
  else
    rootFS="ZFS"
  fi
  if [ "$disk_layout" = "FDE_LVM" ] || [ "$disk_layout" = "FDE" ] || [ "$disk_layout" = "ZFS" ]; then
    sgdisk -og "$dev"
    sgdisk -n 1:2048:4095 -c 1:"BIOS Boot Partition" -t 1:ef02 "$dev"
    sgdisk -n 2:4096:+1G -c 2:"EFI System Partition" -t 2:ef00 "$dev"
    if [ "$disk_layout" = "ZFS" ]; then
      sgdisk -n 3:0:0 -c 3:"ZFS Data Pool" -t 3:8300 "$dev" # TODO find out correct parttype
      echo TODO do some zfs native encryption magic
    else
      sgdisk -n 3:0:0 -c 3:"LUKS container" -t 3:8300 "$dev"
      read -p "LUKS Password: " lukspw
      echo -n "$lukspw" | cryptsetup luksFormat "$dev"3 - \
        -h sha512
       echo "$lukspw" | cryptsetup luksOpen "$dev"3 "crypted" -
      if [ "$disk_layout" = "FDE_LVM" ]; then
        pvcreate /dev/mapper/crypted
        vgcreate pool /dev/mapper/crypted
        lvcreate -n nixos-root -L 15G pool
        echo TODO nixos-generate-config does not detect LUKS in this scenario

        if [ "$rootFS" = "ZFS" ]; then
          echo TODO zfs lvm fu
        else
          mkdir -p /mnt
          mkfs."$rootFS" /dev/pool/nixos-root
          mount /dev/pool/nixos-root /mnt
        fi
      else
        mkdir -p /mnt
        mkfs."$rootFS" /dev/mapper/crypted
        mount /dev/mapper/crypted /mnt
      fi
    fi
    if [ "$bootloader" = "grub" ] || [ "$bootloader" = "systemd" ]; then
      mkdir -p /mnt/boot
      mkfs.vfat "$dev"2
      mount "$dev"2 /mnt/boot
    elif [ "$bootloader" = "grub_no-efi" ]; then
      mkdir -p /mnt/boot
      mkfs.ext4 "$dev"2 # TODO maybe $rootFS here
      mount "$dev"2 /mnt/boot
    fi
  elif [ "$disk_layout" = "PLAIN" ]; then
    if [ "$bootloader" = "grub" ]; then
      sgdisk -n 1:2048:4095 -c 1:"BIOS Boot Partition" -t 1:ef02 "$dev"
      sgdisk -n 2:4096:+1G -c 2:"EFI System Partition" -t 2:ef00 "$dev"
      sgdisk -n 3:0:0 -c 3:"root" -t 3:8300 "$dev"
      mkdir -p /mnt
      mount "$dev"3 /mnt
      mkdir -p /mnt/boot
      mount "$dev"2 /mnt/boot
    elif [ "$bootloader" = "systemd" ]; then
      sgdisk -n 1:0:+1G -c 1:"EFI System Partition" -t 1:ef00 "$dev"
      sgdisk -n 2:0:0 -c 2:"root" -t 3:8300 "$dev"
      mkdir -p /mnt
      mount "$dev"2 /mnt
      mkdir -p /mnt/boot
      mount "$dev"1 /mnt/boot
    elif [ "$bootloader" = "grub_no-efi" ]; then
      sgdisk -n 1:0:+1G -c 1:"root" -t 1:8300 "$dev"
      mkdir -p /mnt
      mount "$dev"1 /mnt
    fi
  fi

  nixos-generate-config --force --root /mnt

  if [ "$bootloader" = "grub" ]; then
    cat ${pkgs.writeText "bootloader.nix" ''
      {
        boot.loader.grub.enable = true;
        boot.loader.grub.version = 2;
        boot.loader.grub.efiSupport = true;
        boot.loader.grub.efiInstallAsRemovable = true;
        boot.loader.grub.device = "ROOTDEV";
      }
    ''} | sed "s@ROOTDEV@$dev@" > /mnt/etc/nixos/bootloader.nix
  elif [ "$bootloader" = "systemd" ]; then
    cp ${pkgs.writeText "bootloader.nix" ''
      {
        boot.loader.grub.enable = true;
        boot.loader.grub.version = 2;
        boot.loader.grub.efiSupport = true;
        boot.loader.grub.efiInstallAsRemovable = true;
        boot.loader.grub.device = "ROOTDEV";
      }
    ''} /mnt/etc/nixos/bootloader.nix
  elif [ "$bootloader" = "grub_no-efi" ]; then
    cat ${pkgs.writeText "bootloader.nix" ''
      {
        boot.loader.grub.enable = true;
        boot.loader.grub.version = 2;
        boot.loader.grub.device = "ROOTDEV";
      }
    ''} | sed "s@ROOTDEV@$dev@" > /mnt/etc/nixos/bootloader.nix
  fi

  sed '/hardware-configuration.nix/ a \ \ \ \ \ \ .\/bootloader.nix' -i /mnt/etc/nixos/configuration.nix

  echo 'you can check everything and run nixos-install afterwards, have fun!'
''
