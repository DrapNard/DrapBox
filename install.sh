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
    echo "⚠ airootfs low (${free_mb}MB free). FORCING RAM-root overlay (${want_mb}MB)."
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
# Simple CLI UI (TTY-safe)
# =============================================================================
ui_msg(){
  _tty_echo ""
  _tty_echo "== $APP =="
  _tty_echo "$1"
  _tty_echo "Log: $LOG_FILE"
  _tty_readline "Press Enter to continue..." "" >/dev/null
}
ui_yesno(){
  local ans
  ans="$(_tty_readline "$1 [y/N]: " "")"
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}
ui_input(){
  local msg="$1" def="${2:-}"
  _tty_readline "$msg [$def]: " "$def"
}
ui_pass(){
  local msg="$1"
  _tty_echo "(!) Password input is visible in pure CLI mode."
  _tty_readline "$msg: " ""
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
    _tty_echo ""
    _tty_echo "=== Disks detected (target will be WIPED) ==="
    _tty_echo "NAME        SIZE   MODEL"
    _tty_echo "-------------------------------------------"

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
          printf "/dev/%s\t%s\t%s\n", name, size, model
        }'
    )

    ((${#disks[@]})) || die "No disks found."

    local i=0 paths=()
    for line in "${disks[@]}"; do
      i=$((i+1))
      local dev size model
      dev="$(awk '{print $1}' <<<"$line")"
      size="$(awk '{print $2}' <<<"$line")"
      model="$(cut -f3- <<<"$line" | sed 's/[[:space:]]\+/ /g')"
      paths+=("$dev")
      printf "%2d) %-10s %-6s %s\n" "$i" "$dev" "$size" "$model" >"$TTY_DEV"
    done

    _tty_echo ""
    local choice
    choice="$(_tty_readline "Select disk number [1-$i] (or 'r' refresh): " "")"
    [[ -z "$choice" ]] && continue
    [[ "${choice,,}" == "r" ]] && continue
    [[ "$choice" =~ ^[0-9]+$ ]] || continue
    (( choice>=1 && choice<=i )) || continue

    local d="${paths[$((choice-1))]}"
    [[ -b "$d" ]] || { _tty_echo "x Selected: $d is not a block device."; continue; }

    _tty_echo ""
    lsblk "$d" >"$TTY_DEV" || true
    ui_yesno "Confirm WIPE target: $d ?" || continue
    echo "$d"
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
    _tty_echo ""
    _tty_echo "No internet detected."
    _tty_echo " 1) Retry"
    _tty_echo " 2) Wi-Fi (iwctl)"
    _tty_echo " 3) Shell"
    _tty_echo " 4) Abort"
    local c
    c="$(_tty_readline "Select [1-4]: " "")"
    case "$c" in
      1) ;;
      2)
        need iwctl || die "iwctl missing"
        local wlan ssid psk
        wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
        [[ -n "$wlan" ]] || { ui_msg "No Wi-Fi interface detected."; continue; }
        ssid="$(ui_input "SSID for $wlan:" "")"
        [[ -n "$ssid" ]] || continue
        psk="$(ui_pass "Password for '$ssid' (empty=open)")"
        iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
        iwctl station "$wlan" scan >/dev/null 2>&1 || true
        sleep 1
        if [[ -n "$psk" ]]; then
          iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || ui_msg "Wi-Fi failed."
        else
          iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || ui_msg "Wi-Fi failed."
        fi
        ;;
      3)
        ui_msg "Shell opened. Type 'exit' to return."
        bash || true
        ;;
      4) die "Aborted" ;;
      *) ;;
    esac
  done
}

# =============================================================================
# MAIN
# =============================================================================
maybe_use_ramroot
fix_system_after_overlay

pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# Live deps
pacman -Sy --noconfirm --needed \
  iwd networkmanager \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git jq \
  >/dev/null

ui_msg "Welcome.\n\nThis will install DrapBox.\n\nStep 1: Internet check."
ensure_network

DISK="$(pick_disk)" || die "No disk selected"

HOSTNAME="$(ui_input "Hostname (also AirPlay name):" "drapbox")"
USERNAME="$(ui_input "Admin user (sudo):" "drapnard")"
USERPASS="$(ui_pass "Password for user '$USERNAME'")"
ROOTPASS="$(ui_pass "Password for root")"

TZ="$(ui_input "Timezone (e.g. Europe/Paris):" "Europe/Paris")"
LOCALE="$(ui_input "Locale (e.g. en_US.UTF-8, fr_FR.UTF-8):" "en_US.UTF-8")"
KEYMAP="$(ui_input "Keymap (e.g. us, fr, de):" "us")"

FS="$(ui_input "Root FS (ext4/btrfs):" "ext4")"
[[ "$FS" == "ext4" || "$FS" == "btrfs" ]] || die "Invalid FS: $FS"

SWAP_G="$(ui_input "Swapfile size GiB (0=none):" "0")"
[[ "$SWAP_G" =~ ^[0-9]+$ ]] || die "Invalid swap size: $SWAP_G"

AUTO_REBOOT="yes"
ui_yesno "Auto reboot after install?" && AUTO_REBOOT="yes" || AUTO_REBOOT="no"

_tty_echo ""
_tty_echo "SUMMARY:"
_tty_echo " Disk:      $DISK"
_tty_echo " FS:        $FS"
_tty_echo " Swap:      ${SWAP_G}GiB"
_tty_echo " TZ:        $TZ"
_tty_echo " Locale:    $LOCALE"
_tty_echo " Keymap:    $KEYMAP"
_tty_echo " Hostname:  $HOSTNAME"
_tty_echo " User:      $USERNAME"
_tty_echo " Log:       $LOG_FILE"
_tty_echo ""
ui_yesno "Proceed?" || die "Aborted"

# ---- Partition / format ----
ui_msg "Partitioning + formatting…"

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

# ---- Pacstrap base ----
ui_msg "Installing base system (repo packages)…"

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
)

pacstrap -K "$MNT" "${BASE_PKGS[@]}"
genfstab -U "$MNT" > "$MNT/etc/fstab"

# Swapfile
if [[ "$SWAP_G" != "0" ]]; then
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
fi

# ---- Fetch firstboot now so it's embedded ----
FIRSTBOOT_URL="${FIRSTBOOT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/firstboot.sh}"
mkdir -p "$MNT/usr/lib/drapbox"
curl -fsSL "$FIRSTBOOT_URL" -o "$MNT/usr/lib/drapbox/firstboot.sh"
chmod 0755 "$MNT/usr/lib/drapbox/firstboot.sh"

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

# ---- Chroot config (incl. repo paru, fallback aur paru) ----
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

# --- IMPORTANT: full sync so pacman/libalpm consistent ---
pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm

# Try install paru from repo first (best, no libalpm mismatch)
if pacman -S --noconfirm --needed paru; then
  echo "[chroot] paru installed from repo."
else
  echo "[chroot] paru not in repo -> building from AUR (source) ..."
  pacman -S --noconfirm --needed git base-devel

  # allow pacman without password only during build
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/pacman-key' >/etc/sudoers.d/99-drapbox-pacman
  chmod 440 /etc/sudoers.d/99-drapbox-pacman

  BUILD_DIR="/tmp/aur-build"
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  chown -R "$USERNAME:$USERNAME" "$BUILD_DIR"

  su - "$USERNAME" -c "cd '$BUILD_DIR' && rm -rf paru && git clone https://aur.archlinux.org/paru-bin.git"
  su - "$USERNAME" -c "cd '$BUILD_DIR/paru-bin' && makepkg -si --noconfirm --needed"
  PKG="$(ls -1 "$BUILD_DIR/paru"/paru-[0-9]*-x86_64.pkg.tar.* 2>/dev/null | tail -n1)"
  [[ -f "$PKG" ]] || die "paru package not built"
  pacman -U --noconfirm --needed "$PKG"

  rm -f /etc/sudoers.d/99-drapbox-pacman
fi

command -v paru >/dev/null 2>&1 || die "paru missing"

# Install repo packages first, fallback to paru if missing
want_repo=(uxplay gnome-network-displays)
for p in "${want_repo[@]}"; do
  if pacman -S --noconfirm --needed "$p"; then
    echo "[chroot] repo ok: $p"
  else
    echo "[chroot] repo missing -> paru: $p"
    su - "$USERNAME" -c "paru -S --noconfirm --needed --skipreview $p"
  fi
done

echo "[chroot] done."
CHROOT

chmod +x "$MNT/root/drapbox-chroot.sh"
arch-chroot "$MNT" /root/drapbox-chroot.sh \
  "$HOSTNAME" "$USERNAME" "$USERPASS" "$ROOTPASS" "$TZ" "$LOCALE" "$KEYMAP" "$FS"

echo
echo "✅ Install complete."
echo "Log file: $LOG_FILE"
echo

umount -R "$MNT" >/dev/null 2>&1 || true

if [[ "${AUTO_REBOOT:-yes}" == "yes" ]]; then
  ui_msg "Install complete ✅\n\nRebooting now…"
  reboot
else
  ui_msg "Install complete ✅\n\nAuto-reboot disabled.\n\nLog: $LOG_FILE\n\nDropping to shell."
  bash
fi
