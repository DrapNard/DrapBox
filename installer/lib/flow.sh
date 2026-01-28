#!/usr/bin/env bash
set -euo pipefail

drapbox_main(){
  require_arch_iso
  require_live_tools

  setup_logging
  setup_error_trap
  ui_init

  ui_title "Bootstrap"
  maybe_use_ramroot
  fix_system_after_overlay

  ui_spin "Refreshing keyring (live)..." pacman -Sy --noconfirm --needed archlinux-keyring
  pacman-key --populate archlinux >/dev/null 2>&1 || true

  ui_spin "Installing live dependencies (incl. gum)..." pacman -Sy --noconfirm --needed \
    iwd networkmanager \
    gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
    arch-install-scripts \
    curl git jq \
    gum

  ui_init

  ui_title "Welcome"
  ui_info "This will install DrapBox on a selected disk."
  ui_info "Logs: $LOG_FILE"

  ensure_network
  ui_ok "Internet OK."

  DISK="$(pick_disk)" || die "No disk selected"

  ui_title "Configuration"
  HOSTNAME="$(ui_input "Hostname (AirPlay name):" "drapbox")"
  USERNAME="$(ui_input "Admin user (sudo):" "drapnard")"
  USERPASS="$(ui_pass "Password for user '$USERNAME':")"
  ROOTPASS="$(ui_pass "Password for root:")"

  TZ="$(pick_timezone "Europe/Paris")"
  LOCALE="$(pick_locale "en_US.UTF-8")"
  KEYMAP="$(pick_keymap "us")"

  FS="$(ui_input "Root FS (ext4/btrfs):" "ext4")"
  [[ "$FS" == "ext4" || "$FS" == "btrfs" ]] || die "Invalid FS: $FS"

  SWAP_G="$(ui_input "Swapfile size GiB (0=none):" "0")"
  [[ "$SWAP_G" =~ ^[0-9]+$ ]] || die "Invalid swap size: $SWAP_G"

  AUTO_REBOOT="yes"
  ui_yesno "Auto reboot after install?" || AUTO_REBOOT="no"

  ui_title "Summary"
  if (( GUM )); then
    gum_ui style --border normal --padding "1 2" --margin "1 2" \
"Disk:      $DISK
FS:        $FS
Swap:      ${SWAP_G}GiB
TZ:        $TZ
Locale:    $LOCALE
Keymap:    $KEYMAP
Hostname:  $HOSTNAME
User:      $USERNAME
Log:       $LOG_FILE"
  else
    _tty_echo "Disk: $DISK"
  fi

  ui_yesno "Proceed with WIPE + install?" || die "Aborted"

  ui_title "Partitioning"
  ui_spin "Umount disk" _unmount_disk_everything "$DISK"
  ui_spin "Wiping signatures..." wipefs -af "$DISK"

  ui_spin "Creating GPT..." sgdisk --zap-all "$DISK"
  sgdisk -o "$DISK"
  sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI" "$DISK"
  sgdisk -n 2:0:0      -t 2:8300 -c 2:"ROOT" "$DISK"
  partprobe "$DISK" || true
  udevadm settle || true

  for i in {1..20}; do
    [[ -b "${DISK}1" || -b "${DISK}p1" ]] && break
    sleep 0.2
  done

  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
  if [[ "$DISK" =~ nvme|mmcblk ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
  fi

  umount -R "$EFI_PART" >/dev/null 2>&1 || true
  umount -R "$ROOT_PART" >/dev/null 2>&1 || true

  ui_spin "Formatting EFI..." mkfs.fat -F32 -n EFI "$EFI_PART"
  if [[ "$FS" == "ext4" ]]; then
    ui_spin "Formatting ROOT ext4..." mkfs.ext4 -F -L ROOT "$ROOT_PART"
  else
    ui_spin "Formatting ROOT btrfs..." mkfs.btrfs -f -L ROOT "$ROOT_PART"
  fi

  ui_spin "Mounting..." mount "$ROOT_PART" "$MNT"
  mkdir -p "$MNT/boot"
  mount "$EFI_PART" "$MNT/boot"

  if [[ "$FS" == "btrfs" ]]; then
    ui_spin "Creating btrfs subvolumes..." btrfs subvolume create "$MNT/@"
    btrfs subvolume create "$MNT/@home"
    umount "$MNT"
    mount -o subvol=@ "$ROOT_PART" "$MNT"
    mkdir -p "$MNT/home" "$MNT/boot"
    mount -o subvol=@home "$ROOT_PART" "$MNT/home"
    mount "$EFI_PART" "$MNT/boot"
  fi

  ui_title "Installing base system"
  BASE_PKGS=(
    base linux linux-firmware
    sudo git curl jq
    networkmanager iwd wpa_supplicant
    bluez bluez-utils
    pipewire wireplumber pipewire-audio
    sway foot xorg-xwayland
    xdg-desktop-portal xdg-desktop-portal-wlr
    gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly
    base-devel
    gum
    ttf-jetbrains-mono-nerd
    fontconfig
  )

  ui_spin "pacstrap (repo packages)..." pacstrap -K "$MNT" "${BASE_PKGS[@]}"
  ui_spin "genfstab..." genfstab -U "$MNT" > "$MNT/etc/fstab"

  if [[ "$SWAP_G" != "0" ]]; then
    if [[ "$FS" == "ext4" ]]; then
      ui_spin "Creating swapfile..." fallocate -l "${SWAP_G}G" "$MNT/swapfile"
      chmod 600 "$MNT/swapfile"
      mkswap "$MNT/swapfile"
      echo "/swapfile none swap defaults 0 0" >> "$MNT/etc/fstab"
    else
      ui_spin "Creating swapfile (btrfs)..." mkdir -p "$MNT/swap"
      chattr +C "$MNT/swap" || true
      fallocate -l "${SWAP_G}G" "$MNT/swap/swapfile"
      chmod 600 "$MNT/swap/swapfile"
      mkswap "$MNT/swap/swapfile"
      echo "/swap/swapfile none swap defaults 0 0" >> "$MNT/etc/fstab"
    fi
  fi

  ui_title "Firstboot"
  install -d "$MNT/usr/lib/drapbox"
  cp -a "$DRAPBOX_SRC/firstboot" "$MNT/usr/lib/drapbox/"
  cp -a "$DRAPBOX_SRC/installer/chroot" "$MNT/usr/lib/drapbox/"
  install -m 0755 "$DRAPBOX_SRC/scripts/drapbox-update" "$MNT/usr/bin/drapbox-update"

  cat >"$MNT/etc/systemd/system/drapbox-firstboot.service" <<'EOF_SERVICE'
[Unit]
Description=DrapBox First Boot Wizard
After=multi-user.target NetworkManager.service bluetooth.service
Wants=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/lib/drapbox/firstboot/entry.sh --firstboot
RemainAfterExit=yes
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  ui_title "Chroot configuration"
  chmod +x "$MNT/usr/lib/drapbox/chroot/entry.sh"
  ui_spin "Running arch-chroot config..." arch-chroot "$MNT" /usr/lib/drapbox/chroot/entry.sh \
    "$HOSTNAME" "$USERNAME" "$USERPASS" "$ROOTPASS" "$TZ" "$LOCALE" "$KEYMAP" "$FS"

  ui_title "Finish"
  ui_ok "Install complete."
  ui_info "Log file: $LOG_FILE"

  umount -R "$MNT" >/dev/null 2>&1 || true

  if [[ "${AUTO_REBOOT:-yes}" == "yes" ]]; then
    ui_ok "Rebooting now..."
    reboot
  else
    ui_warn "Auto-reboot disabled."
    ui_info "You can reboot manually. Log: $LOG_FILE"
    bash
  fi
}
