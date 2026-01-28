#!/usr/bin/env bash
set -euo pipefail

require_arch_iso(){
  [[ -f /etc/arch-release ]] || die "Run from Arch Linux ISO (archiso)."
  [[ -d /sys/firmware/efi/efivars ]] || die "UEFI required (boot ISO in UEFI mode)."
}

require_live_tools(){
  need pacman
  need curl
  need lsblk
  need awk
  need sed
  need mount
  need umount
  need sgdisk
  need mkfs.fat
  need mkfs.ext4
  need genfstab
  need arch-chroot
  need pacstrap
  need wipefs
  need partprobe
  need udevadm
}
