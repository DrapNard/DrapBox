#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v5 (CLI Live + AUR via paru)"
MNT=/mnt

die(){ echo "✗ $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

# ---- guards ----
[[ -f /etc/arch-release ]] || die "Run from Arch Linux ISO (archiso)."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI required (boot ISO in UEFI mode)."

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

export TERM="${TERM:-linux}"
TTY_DEV="/dev/tty"

_tty_echo(){ printf "%b\n" "$*" >"$TTY_DEV"; }
_tty_readline(){
  local prompt="$1" default="${2:-}" ans=""
  printf "%b" "$prompt" >"$TTY_DEV"
  IFS= read -r ans <"$TTY_DEV" || true
  [[ -n "$ans" ]] && printf "%s" "$ans" || printf "%s" "$default"
}

# =============================================================================
# Bootstrap: always run from a real file (fixes /dev/fd weirdness)
# =============================================================================
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/install.sh}"
SELF="${SELF:-/run/drapbox/installer.sh}"
BOOTSTRAPPED="${BOOTSTRAPPED:-0}"

if (( BOOTSTRAPPED == 0 )); then
  mkdir -p /run/drapbox
  curl -fsSL "$SCRIPT_URL" -o "$SELF"
  chmod +x "$SELF"
  export BOOTSTRAPPED=1
  exec bash "$SELF" "$@"
fi

# =============================================================================
# Logging
# =============================================================================
LOG_DIR="/run/drapbox"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== DrapBox installer log: $LOG_FILE ==="
echo "Started: $(date -Is)"
echo

# =============================================================================
# RAM-root overlay (archiso cow space workaround)
# =============================================================================
IN_RAMROOT="${IN_RAMROOT:-0}"

root_free_mb(){ df -Pm / | awk 'NR==2{print $4}'; }
ram_total_mb(){ awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo; }

is_drapbox_ramroot_active() {
  [[ "${IN_RAMROOT:-0}" == "1" ]] && return 0
  local fst; fst="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [[ "$fst" == "overlay" ]] && grep -q "/run/drapbox-ramroot" /proc/mounts 2>/dev/null
}
mark_ramroot_if_detected(){ is_drapbox_ramroot_active && export IN_RAMROOT=1 || true; }

cleanup_ramroot_state() {
  umount -R /run/drapbox-ramroot/merged >/dev/null 2>&1 || true
  umount -R /run/drapbox-ramroot/lower  >/dev/null 2>&1 || true
  umount -R /run/drapbox-ramroot/tmp    >/dev/null 2>&1 || true
  rm -rf /run/drapbox-ramroot >/dev/null 2>&1 || true
}

enter_ramroot_overlay() {
  local want_mb="$1"
  mark_ramroot_if_detected
  (( IN_RAMROOT == 1 )) && return 0

  if [[ -e /run/drapbox-ramroot ]] && ! mountpoint -q /run/drapbox-ramroot/merged 2>/dev/null; then
    cleanup_ramroot_state
  fi

  mkdir -p /run/drapbox-ramroot/{lower,merged,tmp}
  mountpoint -q /run/drapbox-ramroot/lower || mount --rbind / /run/drapbox-ramroot/lower
  mount --make-rprivate /run/drapbox-ramroot/lower || true

  mountpoint -q /run/drapbox-ramroot/tmp || mount -t tmpfs -o "size=${want_mb}M,mode=0755" tmpfs /run/drapbox-ramroot/tmp
  mkdir -p /run/drapbox-ramroot/tmp/{upper,work}

  mountpoint -q /run/drapbox-ramroot/merged || mount -t overlay overlay \
    -o "lowerdir=/run/drapbox-ramroot/lower,upperdir=/run/drapbox-ramroot/tmp/upper,workdir=/run/drapbox-ramroot/tmp/work" \
    /run/drapbox-ramroot/merged

  for d in proc sys dev run tmp; do mkdir -p "/run/drapbox-ramroot/merged/$d"; done
  mount --bind /proc /run/drapbox-ramroot/merged/proc
  mount --bind /sys  /run/drapbox-ramroot/merged/sys
  mount --bind /dev  /run/drapbox-ramroot/merged/dev
  mount --bind /run  /run/drapbox-ramroot/merged/run
  mount --bind /tmp  /run/drapbox-ramroot/merged/tmp

  install -m 0755 "$SELF" /run/drapbox-ramroot/merged/tmp/drapbox-run
  export IN_RAMROOT=1 LOG_FILE LOG_DIR SCRIPT_URL SELF TERM
  exec chroot /run/drapbox-ramroot/merged /tmp/drapbox-run
}

maybe_use_ramroot() {
  mark_ramroot_if_detected
  (( IN_RAMROOT == 1 )) && return 0
  mountpoint -q /run/drapbox-ramroot/merged 2>/dev/null && { export IN_RAMROOT=1; return 0; }

  local free_mb mem_mb threshold_mb want_mb
  free_mb="$(root_free_mb)"; mem_mb="$(ram_total_mb)"
  threshold_mb=350

  if   (( mem_mb <= 4096 )); then want_mb=1024
  elif (( mem_mb <= 6144 )); then want_mb=1536
  elif (( mem_mb <= 8192 )); then want_mb=2048
  else
    want_mb=$(( mem_mb - 2048 ))
    (( want_mb > 8192 )) && want_mb=8192
  fi

  if (( free_mb < threshold_mb )); then
    _tty_echo "⚠ airootfs low (${free_mb}MB free). FORCING RAM-root overlay (${want_mb}MB)."
    enter_ramroot_overlay "$want_mb"
  fi
}

fix_system_after_overlay() {
  [[ "${IN_RAMROOT:-0}" == "1" ]] || return 0
  echo "• [ramroot] Fixing system state after overlay…"
  mkdir -p /var/lib/pacman /var/cache/pacman/pkg /etc/pacman.d /tmp
  chmod 1777 /tmp
  [[ -e /etc/resolv.conf ]] || echo "nameserver 1.1.1.1" > /etc/resolv.conf

  install -d -m 700 /etc/pacman.d/gnupg
  : > /etc/pacman.d/gnupg/.drapbox_copyup 2>/dev/null || true
  chmod 700 /etc/pacman.d/gnupg || true
  pkill -x gpg-agent >/dev/null 2>&1 || true
  pkill -x dirmngr   >/dev/null 2>&1 || true
  rm -f /etc/pacman.d/gnupg/S.gpg-agent* /etc/pacman.d/gnupg/*.lock >/dev/null 2>&1 || true

  systemctl start haveged >/dev/null 2>&1 || true
  systemctl start rngd    >/dev/null 2>&1 || true
  pacman-key --init >/dev/null 2>&1 || true
  pacman-key --populate archlinux >/dev/null 2>&1 || true
  echo "• [ramroot] Done."
}

# =============================================================================
# gum UI (TTY) — no “press enter” pauses
# =============================================================================
has_gum(){ command -v gum >/dev/null 2>&1; }

ui_header(){
  if has_gum; then
    gum style --border normal --padding "1 2" \
      --bold "$APP" "Log: $LOG_FILE" >/dev/null || true
  else
    _tty_echo ""
    _tty_echo "== $APP =="
    _tty_echo "Log: $LOG_FILE"
    _tty_echo ""
  fi
}

ui_note(){
  if has_gum; then
    gum style --faint "$*" >/dev/null || true
  else
    _tty_echo "$*"
  fi
}

ui_step(){
  local tag="$1" msg="$2"
  if has_gum; then
    gum style --bold --foreground 212 "[$tag]" --foreground 7 " $msg" >/dev/null || true
  else
    _tty_echo "[$tag] $msg"
  fi
}

ui_ok(){
  if has_gum; then gum style --foreground 10 "✓ $*" >/dev/null || true
  else _tty_echo "✓ $*"
  fi
}

ui_warn(){
  if has_gum; then gum style --foreground 11 "⚠ $*" >/dev/null || true
  else _tty_echo "⚠ $*"
  fi
}

ui_confirm(){
  local msg="$1"
  if has_gum; then
    gum confirm "$msg"
  else
    local ans; ans="$(_tty_readline "$msg [y/N]: " "")"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  fi
}

ui_input(){
  local msg="$1" def="${2:-}"
  if has_gum; then
    gum input --prompt "$msg: " --value "$def"
  else
    _tty_readline "$msg [$def]: " "$def"
  fi
}

ui_pass(){
  local msg="$1"
  if has_gum; then
    gum input --password --prompt "$msg: "
  else
    _tty_echo "(!) Password input is visible in pure CLI mode."
    _tty_readline "$msg: " ""
  fi
}

ui_choose(){
  local msg="$1"; shift
  if has_gum; then
    gum choose --header "$msg" "$@"
  else
    _tty_echo "$msg"
    local i=0; for opt in "$@"; do i=$((i+1)); _tty_echo " $i) $opt"; done
    local c; c="$(_tty_readline "Select [1-$i]: " "")"
    [[ "$c" =~ ^[0-9]+$ ]] || return 1
    (( c>=1 && c<=i )) || return 1
    printf "%s" "${!c}" # (won't work in POSIX; fallback below)
  fi
}

# =============================================================================
# Disk picker
# =============================================================================
_unmount_disk_everything(){
  local disk="$1"
  local parts
  mapfile -t parts < <(lsblk -lnpo NAME "$disk" 2>/dev/null | tail -n +2 || true)
  for p in "${parts[@]}"; do
    local mps
    mapfile -t mps < <(lsblk -lnpo MOUNTPOINT "$p" 2>/dev/null | awk 'NF{print}')
    for mp in "${mps[@]}"; do
      umount -R "$mp" >/dev/null 2>&1 || true
    done
    swapoff "$p" >/dev/null 2>&1 || true
  done
}

pick_disk(){
  while true; do
    ui_header
    mapfile -t disks < <(
      lsblk -dn -o NAME,TYPE,SIZE,MODEL -P |
      awk '
        $0 ~ /TYPE="disk"/ {
          name=""; size=""; model=""
          for (i=1;i<=NF;i++){
            if ($i ~ /^NAME=/){ gsub(/NAME=|"/,"",$i); name=$i }
            if ($i ~ /^SIZE=/){ gsub(/SIZE=|"/,"",$i); size=$i }
            if ($i ~ /^MODEL=/){ gsub(/MODEL=|"/,"",$i); model=$i }
          }
          printf "/dev/%s  |  %s  |  %s\n", name, size, model
        }'
    )
    ((${#disks[@]})) || die "No disks found."

    local picked=""
    if has_gum; then
      picked="$(gum choose --header "Select target disk (WIPED)" "${disks[@]}")"
    else
      _tty_echo "Select target disk (WIPED):"
      local i=0; for line in "${disks[@]}"; do i=$((i+1)); _tty_echo " $i) $line"; done
      local c; c="$(_tty_readline "Select [1-$i]: " "")"
      [[ "$c" =~ ^[0-9]+$ ]] || continue
      (( c>=1 && c<=i )) || continue
      picked="${disks[$((c-1))]}"
    fi

    local dev; dev="$(awk '{print $1}' <<<"$picked")"
    [[ -b "$dev" ]] || continue

    lsblk "$dev" >"$TTY_DEV" || true
    ui_confirm "Confirm WIPE target: $dev ?" || continue
    echo "$dev"
    return 0
  done
}

# =============================================================================
# Network (minimal: iwd + NetworkManager only)
# =============================================================================
is_online(){
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W2 archlinux.org >/dev/null 2>&1
}
ensure_network(){
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl start iwd >/dev/null 2>&1 || true
  systemctl start NetworkManager >/dev/null 2>&1 || true

  while ! is_online; do
    ui_header
    ui_warn "No internet detected."
    if has_gum; then
      local action
      action="$(gum choose --header "Network" "Retry" "Wi-Fi (iwctl)" "Shell" "Abort")"
      case "$action" in
        "Retry") ;;
        "Wi-Fi (iwctl)")
          need iwctl || die "iwctl missing"
          local wlan ssid psk
          wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
          [[ -n "$wlan" ]] || { ui_warn "No Wi-Fi interface detected."; continue; }
          ssid="$(ui_input "SSID for $wlan" "")"
          [[ -n "$ssid" ]] || continue
          psk="$(ui_pass "Password for '$ssid' (empty=open)")"
          iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
          iwctl station "$wlan" scan >/dev/null 2>&1 || true
          sleep 1
          if [[ -n "$psk" ]]; then
            iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
          else
            iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
          fi
          ;;
        "Shell") bash || true ;;
        "Abort") die "Aborted" ;;
      esac
    else
      _tty_echo " 1) Retry"
      _tty_echo " 2) Wi-Fi (iwctl)"
      _tty_echo " 3) Shell"
      _tty_echo " 4) Abort"
      local c; c="$(_tty_readline "Select [1-4]: " "")"
      case "$c" in
        1) ;;
        2)
          need iwctl || die "iwctl missing"
          local wlan ssid psk
          wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
          [[ -n "$wlan" ]] || { _tty_echo "No Wi-Fi interface detected."; continue; }
          ssid="$(ui_input "SSID for $wlan" "")"
          [[ -n "$ssid" ]] || continue
          psk="$(ui_pass "Password for '$ssid' (empty=open)")"
          iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
          iwctl station "$wlan" scan >/dev/null 2>&1 || true
          sleep 1
          if [[ -n "$psk" ]]; then
            iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
          else
            iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
          fi
          ;;
        3) bash || true ;;
        4) die "Aborted" ;;
      esac
    fi
  done
}

# =============================================================================
# MAIN
# =============================================================================
maybe_use_ramroot
fix_system_after_overlay

ui_header
ui_step "0/7" "Preparing installer environment"

pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# Live deps (+ gum)
pacman -Sy --noconfirm --needed \
  iwd networkmanager \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git jq \
  gum \
  >/dev/null
ui_ok "Live deps ready (gum installed)"

ui_step "1/7" "Internet check"
ensure_network
ui_ok "Internet OK"

DISK="$(pick_disk)" || die "No disk selected"

ui_header
ui_step "Input" "System settings"
HOSTNAME="$(ui_input "Hostname (also AirPlay name)" "drapbox")"
USERNAME="$(ui_input "Admin user (sudo)" "drapnard")"
USERPASS="$(ui_pass "Password for user '$USERNAME'")"
ROOTPASS="$(ui_pass "Password for root")"

TZ="$(ui_input "Timezone (e.g. Europe/Paris)" "Europe/Paris")"
LOCALE="$(ui_input "Locale (e.g. en_US.UTF-8, fr_FR.UTF-8)" "en_US.UTF-8")"
KEYMAP="$(ui_input "Keymap (e.g. us, fr, de)" "us")"

FS="$(ui_input "Root FS (ext4/btrfs)" "ext4")"
[[ "$FS" == "ext4" || "$FS" == "btrfs" ]] || die "Invalid FS: $FS"

SWAP_G="$(ui_input "Swapfile size GiB (0=none)" "0")"
[[ "$SWAP_G" =~ ^[0-9]+$ ]] || die "Invalid swap size: $SWAP_G"

AUTO_REBOOT="yes"
ui_confirm "Auto reboot after install?" && AUTO_REBOOT="yes" || AUTO_REBOOT="no"

ui_header
ui_step "Summary" "Review configuration"
echo " Disk:      $DISK"
echo " FS:        $FS"
echo " Swap:      ${SWAP_G}GiB"
echo " TZ:        $TZ"
echo " Locale:    $LOCALE"
echo " Keymap:    $KEYMAP"
echo " Hostname:  $HOSTNAME"
echo " User:      $USERNAME"
echo " Log:       $LOG_FILE"
echo
ui_confirm "Proceed?" || die "Aborted"

# ---- Partition / format ----
ui_header
ui_step "2/7" "Partitioning + formatting"

umount -R "$MNT" >/dev/null 2>&1 || true
swapoff -a >/dev/null 2>&1 || true
_unmount_disk_everything "$DISK"

wipefs -af "$DISK" >/dev/null 2>&1 || true

sgdisk --zap-all "$DISK"
sgdisk -o "$DISK"
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0      -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK" || true
udevadm settle || true
sleep 1

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
fi

umount -R "$EFI_PART" >/dev/null 2>&1 || true
umount -R "$ROOT_PART" >/dev/null 2>&1 || true

mkfs.fat -F32 -n EFI "$EFI_PART"
if [[ "$FS" == "ext4" ]]; then
  mkfs.ext4 -F -L ROOT "$ROOT_PART"
else
  mkfs.btrfs -f -L ROOT "$ROOT_PART"
fi

mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot"
mount "$EFI_PART" "$MNT/boot"

if [[ "$FS" == "btrfs" ]]; then
  btrfs subvolume create "$MNT/@"
  btrfs subvolume create "$MNT/@home"
  umount "$MNT"
  mount -o subvol=@ "$ROOT_PART" "$MNT"
  mkdir -p "$MNT/home" "$MNT/boot"
  mount -o subvol=@home "$ROOT_PART" "$MNT/home"
  mount "$EFI_PART" "$MNT/boot"
fi
ui_ok "Disk ready"

# ---- Pacstrap base ----
ui_header
ui_step "3/7" "Installing base system (repo packages)"

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
)

pacstrap -K "$MNT" "${BASE_PKGS[@]}"
genfstab -U "$MNT" > "$MNT/etc/fstab"
ui_ok "Base installed"

# Swapfile
if [[ "$SWAP_G" != "0" ]]; then
  ui_header
  ui_step "4/7" "Creating swapfile"
  if [[ "$FS" == "ext4" ]]; then
    fallocate -l "${SWAP_G}G" "$MNT/swapfile"
    chmod 600 "$MNT/swapfile"
    mkswap "$MNT/swapfile"
    echo "/swapfile none swap defaults 0 0" >> "$MNT/etc/fstab"
  else
    mkdir -p "$MNT/swap"
    chattr +C "$MNT/swap" || true
    fallocate -l "${SWAP_G}G" "$MNT/swap/swapfile"
    chmod 600 "$MNT/swap/swapfile"
    mkswap "$MNT/swap/swapfile"
    echo "/swap/swapfile none swap defaults 0 0" >> "$MNT/etc/fstab"
  fi
  ui_ok "Swap ready"
fi

# ---- Fetch firstboot now so it's embedded ----
ui_header
ui_step "5/7" "Embedding firstboot + enabling service"
FIRSTBOOT_URL="${FIRSTBOOT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/firstboot.sh}"
mkdir -p "$MNT/usr/lib/drapbox"
curl -fsSL "$FIRSTBOOT_URL" -o "$MNT/usr/lib/drapbox/firstboot.sh"
chmod 0755 "$MNT/usr/lib/drapbox/firstboot.sh"
ui_ok "firstboot.sh installed"

cat >"$MNT/etc/systemd/system/drapbox-firstboot.service" <<'EOF'
[Unit]
Description=DrapBox First Boot Wizard
After=multi-user.target NetworkManager.service bluetooth.service
Wants=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/lib/drapbox/firstboot.sh --firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ui_ok "firstboot unit created"

# ---- Chroot config (logic unchanged) ----
ui_header
ui_step "6/7" "Configuring installed system (chroot)"

cat >"$MNT/root/drapbox-chroot.sh" <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
die(){ echo "✗ $*" >&2; exit 1; }

HOSTNAME="$1"; USERNAME="$2"; USERPASS="$3"; ROOTPASS="$4"; TZ="$5"; LOCALE="$6"; KEYMAP="$7"; FS="$8"

echo "[chroot] base config..."

ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

sed -i "s/^#\s*${LOCALE}/${LOCALE}/" /etc/locale.gen || true
sed -i 's/^#\s*en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF

echo "root:$ROOTPASS" | chpasswd
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable iwd
systemctl enable bluetooth
systemctl enable drapbox-firstboot.service

# systemd-boot
bootctl install
ROOT_UUID="$(blkid -s UUID -o value "$(findmnt -no SOURCE /)")"
CMDLINE="quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0"
if [[ "$FS" == "btrfs" ]]; then CMDLINE="$CMDLINE rootflags=subvol=@"; fi

mkdir -p /boot/loader/entries
cat >/boot/loader/loader.conf <<EOF
default drapbox.conf
timeout 0
editor no
EOF

cat >/boot/loader/entries/drapbox.conf <<EOF
title DrapBox
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$ROOT_UUID rw $CMDLINE
EOF

echo "[chroot] fixing pacman keyring (PGP)..."
timedatectl set-ntp true >/dev/null 2>&1 || true

rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
rm -f /var/cache/pacman/pkg/archlinux-keyring-*.pkg.tar.* 2>/dev/null || true

pacman -Syy --noconfirm
pacman -S --noconfirm --needed archlinux-keyring
pacman -Syu --noconfirm

if pacman -S --noconfirm --needed yay; then
  echo "[chroot] yay installed from repo."
else
  echo "[chroot] yay not in repo -> building from AUR (source) ..."
  pacman -S --noconfirm --needed git base-devel

  echo '%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/pacman-key' >/etc/sudoers.d/99-drapbox-pacman
  chmod 440 /etc/sudoers.d/99-drapbox-pacman

  BUILD_DIR="/tmp/aur-build"
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  chown -R "$USERNAME:$USERNAME" "$BUILD_DIR"

  su - "$USERNAME" -c "cd '$BUILD_DIR' && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git"
  su - "$USERNAME" -c "cd '$BUILD_DIR/yay-bin' && makepkg -si --noconfirm --needed"
fi

command -v yay >/dev/null 2>&1 || die "yay missing"

want_repo=(uxplay gnome-network-displays)
for p in "${want_repo[@]}"; do
  if pacman -S --noconfirm --needed "$p"; then
    echo "[chroot] repo ok: $p"
  else
    echo "[chroot] repo missing -> yay: $p"
    su - "$USERNAME" -c "yay -S --noconfirm --needed $p"
  fi
done

rm -f /etc/sudoers.d/99-drapbox-pacman

echo "[chroot] done."
CHROOT

chmod +x "$MNT/root/drapbox-chroot.sh"
arch-chroot "$MNT" /root/drapbox-chroot.sh \
  "$HOSTNAME" "$USERNAME" "$USERPASS" "$ROOTPASS" "$TZ" "$LOCALE" "$KEYMAP" "$FS"

ui_ok "Chroot done"

echo
echo "✅ Install complete."
echo "Log file: $LOG_FILE"
echo

umount -R "$MNT" >/dev/null 2>&1 || true

ui_header
ui_step "7/7" "Finish"
ui_note "Next boot:"
ui_note "  • DrapBox boots normally"
ui_note "  • firstboot auto-runs once via drapbox-firstboot.service"
ui_note "If missing: systemctl status drapbox-firstboot.service"
echo

if [[ "${AUTO_REBOOT:-yes}" == "yes" ]]; then
  ui_note "Rebooting now…"
  reboot
else
  ui_note "Auto-reboot disabled. Dropping to shell."
  bash
fi
