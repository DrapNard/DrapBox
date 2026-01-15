#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v5 (Pure CLI)"
MNT=/mnt

die(){ echo "✗ $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

# ---- guards ----
[[ -f /etc/arch-release ]] || die "Run from Arch Linux ISO (archiso)."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI required (boot ISO in UEFI mode)."

export TERM="${TERM:-linux}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =============================================================================
# Bootstrap: always run from a real file (fixes /dev/fd, overlay re-exec weirdness)
# =============================================================================
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/install.sh}"
SELF="${SELF:-/run/drapbox/installer.sh}"
BOOTSTRAPPED="${BOOTSTRAPPED:-0}"

mkdir -p /run/drapbox

if (( BOOTSTRAPPED == 0 )); then
  curl -fsSL "$SCRIPT_URL" -o "$SELF"
  chmod +x "$SELF"
  exec /usr/bin/env -i \
    BOOTSTRAPPED=1 \
    SCRIPT_URL="$SCRIPT_URL" \
    SELF="$SELF" \
    TERM="$TERM" \
    PATH="$PATH" \
    bash "$SELF" "$@"
fi

# =============================================================================
# Logging: stdout/stderr -> tee log. UI input/output -> /dev/tty (FD 3)
# =============================================================================
LOG_DIR="/run/drapbox"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"

# Open /dev/tty for UI (works even when stdout is piped)
if [[ -e /dev/tty ]]; then
  exec 3<>/dev/tty
else
  # fallback: use stdin/out (not ideal)
  exec 3>&1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

ui(){ printf "%s\n" "$*" >&3; }
ui_n(){ printf "%s" "$*" >&3; }

ui "=== $APP ==="
ui "Log: $LOG_FILE"
echo "=== $APP log: $LOG_FILE ==="
echo "Started: $(date -Is)"
echo

# =============================================================================
# Args
# =============================================================================
AUTO_REBOOT="yes"
for a in "$@"; do
  case "$a" in
    --no-reboot) AUTO_REBOOT="no" ;;
  esac
done

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

  # runner inside merged root
  install -m 0755 "$SELF" /run/drapbox-ramroot/merged/tmp/drapbox-run

  export IN_RAMROOT=1
  export BOOTSTRAPPED=1 SCRIPT_URL SELF TERM PATH LOG_FILE LOG_DIR AUTO_REBOOT
  exec chroot /run/drapbox-ramroot/merged /usr/bin/env bash /tmp/drapbox-run
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
    ui "⚠ airootfs low (${free_mb}MB free). FORCING RAM-root overlay (${want_mb}MB)."
    echo "⚠ airootfs low (${free_mb}MB free). FORCING RAM-root overlay (${want_mb}MB)."
    enter_ramroot_overlay "$want_mb"
  fi
}

fix_system_after_overlay() {
  [[ "${IN_RAMROOT:-0}" == "1" ]] || return 0
  ui "• [ramroot] Fixing system state after overlay…"
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

  ui "• [ramroot] Done."
  echo "• [ramroot] Done."
}

# =============================================================================
# CLI helpers (pure tty, no ncurses)
# =============================================================================
read_tty_line() {
  local prompt="$1" default="${2:-}"
  ui_n "$prompt"
  local ans=""
  IFS= read -r ans <&3 || true
  # strip control chars
  ans="$(printf "%s" "$ans" | tr -d '\r' | tr -cd '[:print:]')"
  [[ -n "$ans" ]] && printf "%s" "$ans" || printf "%s" "$default"
}

ask_yesno() {
  local prompt="$1" def="${2:-N}"
  local ans
  ans="$(read_tty_line "$prompt [y/N]: " "")"
  if [[ -z "$ans" ]]; then
    [[ "${def^^}" == "Y" ]]
    return
  fi
  case "${ans,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

pause() {
  ui ""
  read_tty_line "Press Enter to continue..." "" >/dev/null || true
}

menu_select_num() {
  # prints selected index (1..n) to stdout
  local title="$1"; shift
  ui ""
  ui "== $title =="
  local i=0
  while (( $# )); do
    i=$((i+1))
    ui " $i) $1"
    shift
  done
  ui ""
  local ans
  ans="$(read_tty_line "Select [1-$i]: " "")"
  [[ "$ans" =~ ^[0-9]+$ ]] || return 1
  (( ans>=1 && ans<=i )) || return 1
  printf "%s" "$ans"
}

# =============================================================================
# Network
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
    ui ""
    ui "No internet detected."
    ui "1) Retry (re-test)"
    ui "2) Connect Wi-Fi with iwctl"
    ui "3) Open shell"
    ui "4) Abort"
    local c
    c="$(read_tty_line "Choice [1-4]: " "1")"
    case "$c" in
      1) ;;
      2)
        need iwctl || die "iwctl missing"
        local wlan ssid psk
        wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
        [[ -n "$wlan" ]] || { ui "No Wi-Fi interface detected."; continue; }
        ssid="$(read_tty_line "SSID for $wlan: " "")"
        [[ -n "$ssid" ]] || continue
        psk="$(read_tty_line "Password (empty for open network): " "")"
        iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
        iwctl station "$wlan" scan >/dev/null 2>&1 || true
        sleep 1
        if [[ -n "$psk" ]]; then
          iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || ui "Wi-Fi failed."
        else
          iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || ui "Wi-Fi failed."
        fi
        ;;
      3)
        ui "Shell opened. Type 'exit' to return."
        bash </dev/tty >/dev/tty 2>/dev/tty || true
        ;;
      4) die "Aborted" ;;
      *) ;;
    esac
  done
}

# =============================================================================
# Disk picker (robust, no awk column assumptions)
# =============================================================================
pick_disk() {
  while true; do
    ui ""
    ui "=== Disks detected (target will be WIPED) ==="
    ui "Idx  Device       Size"
    ui "---------------------------"

    # Get only disks: NAME TYPE SIZE (TYPE is stable in field2 here)
    mapfile -t rows < <(lsblk -dn -o NAME,TYPE,SIZE | awk '$2=="disk"{print $1" "$3}')
    if ((${#rows[@]}==0)); then
      ui "x No disks found."
      # debug for log
      echo "[debug] lsblk:"; lsblk
      die "No disks found"
    fi

    local idx=0
    local devs=()
    for r in "${rows[@]}"; do
      idx=$((idx+1))
      local name size
      name="$(awk '{print $1}' <<<"$r")"
      size="$(awk '{print $2}' <<<"$r")"
      devs+=("/dev/$name")
      ui "$(printf "%-4s %-11s %s" "$idx" "/dev/$name" "$size")"
    done

    ui ""
    local c
    c="$(read_tty_line "Select disk number [1-$idx] (r=refresh): " "")"
    [[ -z "$c" ]] && continue
    if [[ "${c,,}" == "r" ]]; then
      continue
    fi
    [[ "$c" =~ ^[0-9]+$ ]] || continue
    (( c>=1 && c<=idx )) || continue

    local disk="${devs[$((c-1))]}"
    [[ -b "$disk" ]] || { ui "Selected disk is not a block device: $disk"; continue; }

    if ask_yesno "Confirm wipe target: $disk ?" "N"; then
      echo "$disk"
      return 0
    fi
  done
}

# =============================================================================
# Timezone picker (simple search + numbered list)
# =============================================================================
pick_timezone(){
  local q
  q="$(read_tty_line "Timezone search (e.g. Paris) empty=list first 50: " "")"
  mapfile -t tzs < <(
    if [[ -n "$q" ]]; then
      timedatectl list-timezones | grep -i "$q" | head -n 50
    else
      timedatectl list-timezones | head -n 50
    fi
  )
  ((${#tzs[@]})) || die "No timezone match"
  ui ""
  ui "Timezones:"
  local i=0
  for t in "${tzs[@]}"; do i=$((i+1)); ui " $i) $t"; done
  local c
  c="$(read_tty_line "Select [1-$i]: " "1")"
  [[ "$c" =~ ^[0-9]+$ ]] || die "Bad selection"
  (( c>=1 && c<=i )) || die "Out of range"
  echo "${tzs[$((c-1))]}"
}

# =============================================================================
# MAIN
# =============================================================================
need pacman
need curl

maybe_use_ramroot
fix_system_after_overlay

# Keyring baseline
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# Minimal live deps (NETWORK = iwd + networkmanager ONLY, plus install tools)
pacman -Sy --noconfirm --needed \
  iwd networkmanager \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git \
  >/dev/null

ui ""
ui "Welcome."
ui "This will install DrapBox."
ui "Log: $LOG_FILE"
pause

ui "Step 1: Internet check."
ensure_network
ui "Internet: OK"
pause

DISK="$(pick_disk)" || die "No disk selected"
ui "Selected disk: $DISK"
# show disks for user confirmation
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DISK" || true
pause

HOSTNAME="$(read_tty_line "Hostname (AirPlay name) [drapbox]: " "drapbox")"
USERNAME="$(read_tty_line "Admin user [drapnard]: " "drapnard")"
USERPASS="$(read_tty_line "Password for user '$USERNAME': " "")"
ROOTPASS="$(read_tty_line "Password for root: " "")"

TZ="$(pick_timezone)"
LOCALE="$(read_tty_line "Locale [en_US.UTF-8]: " "en_US.UTF-8")"
KEYMAP="$(read_tty_line "Keymap [us]: " "us")"

ui ""
ui "Filesystem:"
ui "1) ext4 (simple)"
ui "2) btrfs (subvolumes)"
fs_idx="$(read_tty_line "Select [1-2] [1]: " "1")"
FS="ext4"
[[ "$fs_idx" == "2" ]] && FS="btrfs"

ui ""
ui "Swapfile size (GiB): 0/2/4/8/12/16"
SWAP_G="$(read_tty_line "Swap GiB [0]: " "0")"
[[ "$SWAP_G" =~ ^(0|2|4|8|12|16)$ ]] || SWAP_G="0"

ATV_VARIANT="$(read_tty_line "Waydroid variant [GAPPS/VANILLA] [GAPPS]: " "GAPPS")"
ATV_VARIANT="${ATV_VARIANT^^}"
[[ "$ATV_VARIANT" != "GAPPS" && "$ATV_VARIANT" != "VANILLA" ]] && ATV_VARIANT="GAPPS"

AUTOSWITCH="$(read_tty_line "Auto-switch [ON/OFF] [ON]: " "ON")"
AUTOSWITCH="${AUTOSWITCH^^}"
[[ "$AUTOSWITCH" != "ON" && "$AUTOSWITCH" != "OFF" ]] && AUTOSWITCH="ON"

HWACCEL="$(read_tty_line "HW decode [ON/OFF] [ON]: " "ON")"
HWACCEL="${HWACCEL^^}"
[[ "$HWACCEL" != "ON" && "$HWACCEL" != "OFF" ]] && HWACCEL="ON"

AUTOLOGIN="no"
ask_yesno "Appliance mode: autologin + auto-start sway?" "N" && AUTOLOGIN="yes" || true

if [[ "$AUTO_REBOOT" != "no" ]]; then
  ask_yesno "Auto reboot after install?" "Y" && AUTO_REBOOT="yes" || AUTO_REBOOT="no"
fi

ui ""
ui "========== SUMMARY =========="
ui "Disk:       $DISK"
ui "FS:         $FS"
ui "Swap:       ${SWAP_G}GiB"
ui "TZ:         $TZ"
ui "Locale:     $LOCALE"
ui "Keymap:     $KEYMAP"
ui "Hostname:   $HOSTNAME"
ui "User:       $USERNAME"
ui "Waydroid:   $ATV_VARIANT"
ui "Autoswitch: $AUTOSWITCH"
ui "HW decode:  $HWACCEL"
ui "Autologin:  $AUTOLOGIN"
ui "Log:        $LOG_FILE"
ui "============================="
ask_yesno "Proceed? THIS WILL WIPE $DISK" "N" || die "Aborted"

# ---- Partition / format ----
ui ""
ui "Partitioning + formatting..."
echo "[info] Wiping and partitioning $DISK"

umount -R "$MNT" >/dev/null 2>&1 || true
swapoff -a >/dev/null 2>&1 || true

sgdisk --zap-all "$DISK"
sgdisk -o "$DISK"
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0      -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK" || true
sleep 1

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
fi

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

# ---- Install system ----
ui ""
ui "Installing base system + DrapBox stack (can take a while)..."

pacstrap -K "$MNT" \
  base linux linux-firmware \
  networkmanager iwd wpa_supplicant \
  sudo git curl jq \
  sway foot wl-clipboard wlr-randr xorg-xwayland \
  pipewire wireplumber pipewire-audio \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  waydroid uxplay \
  plymouth \
  python python-gobject gtk3 gtk-layer-shell gnome-themes-extra adwaita-icon-theme \
  gnome-network-displays \
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gstreamer-vaapi \
  sqlite qrencode \
  bluez bluez-utils \
  socat psmisc procps

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
    if btrfs filesystem mkswapfile -h >/dev/null 2>&1; then
      btrfs filesystem mkswapfile --size "${SWAP_G}G" "$MNT/swap/swapfile"
    else
      chattr +C "$MNT/swap" || true
      fallocate -l "${SWAP_G}G" "$MNT/swap/swapfile"
      chmod 600 "$MNT/swap/swapfile"
      mkswap "$MNT/swap/swapfile"
    fi
    echo "/swap/swapfile none swap defaults 0 0" >> "$MNT/etc/fstab"
  fi
fi

mkdir -p "$MNT/var/lib/drapbox"
echo "$ATV_VARIANT" > "$MNT/var/lib/drapbox/waydroid_variant"
echo "$AUTOSWITCH"  > "$MNT/var/lib/drapbox/autoswitch"
echo "$HWACCEL"     > "$MNT/var/lib/drapbox/hwaccel"

# ---- Chroot config ----
cat >"$MNT/root/drapbox-chroot.sh" <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
HOSTNAME="$1"; USERNAME="$2"; USERPASS="$3"; ROOTPASS="$4"; TZ="$5"; LOCALE="$6"; KEYMAP="$7"; AUTOLOGIN="$8"; FS="$9"

sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf || true
grep -q '^ILoveCandy' /etc/pacman.conf || echo 'ILoveCandy' >> /etc/pacman.conf

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
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable iwd
systemctl enable bluetooth

if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
  sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 plymouth)/' /etc/mkinitcpio.conf
fi
mkdir -p /etc/plymouth
cat >/etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=spinner
ShowDelay=0
EOF
mkinitcpio -P

bootctl install
ROOT_UUID="$(blkid -s UUID -o value "$(findmnt -no SOURCE /)")"
CMDLINE="quiet splash loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0"
if [[ "$FS" == "btrfs" ]]; then CMDLINE="$CMDLINE rootflags=subvol=@"; fi

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

cat >/boot/loader/entries/drapbox-rescue.conf <<EOF
title DrapBox (rescue terminal)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$ROOT_UUID rw systemd.unit=multi-user.target loglevel=4
EOF

mkdir -p /etc/environment.d
cat >/etc/environment.d/90-drapbox.conf <<'EOF'
GTK_THEME=Adwaita:dark
GDK_BACKEND=wayland
EOF

loginctl enable-linger "$USERNAME" || true
CHROOT

chmod +x "$MNT/root/drapbox-chroot.sh"
arch-chroot "$MNT" /root/drapbox-chroot.sh \
  "$HOSTNAME" "$USERNAME" "$USERPASS" "$ROOTPASS" "$TZ" "$LOCALE" "$KEYMAP" "$AUTOLOGIN" "$FS"

ui ""
ui "✅ Install complete."
ui "Log: $LOG_FILE"
echo "✅ Install complete. Log: $LOG_FILE"

umount -R "$MNT" >/dev/null 2>&1 || true

if [[ "$AUTO_REBOOT" == "yes" ]]; then
  ui "Rebooting..."
  reboot
else
  ui "Auto-reboot disabled."
  ui "Log: $LOG_FILE"
  ui "Dropping to shell."
  bash </dev/tty >/dev/tty 2>/dev/tty || true
fi
