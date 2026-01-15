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

export TERM="${TERM:-linux}"

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
# Robust launcher (works with bash <(curl ...))
# =============================================================================
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/install.sh}"
SELF="${SELF:-/run/drapbox-installer.sh}"

_snapshot_self() {
  mkdir -p "$(dirname "$SELF")"
  [[ -s "$SELF" ]] && return 0
  if [[ -r "${0:-}" ]]; then cat "$0" > "$SELF" 2>/dev/null || true; fi
  [[ -s "$SELF" ]] || curl -fsSL "$SCRIPT_URL" -o "$SELF"
  chmod +x "$SELF"
}
_snapshot_self

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

  export IN_RAMROOT=1
  export LOG_FILE LOG_DIR SCRIPT_URL SELF TERM
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
# Minimal UI (plain prompts)
# =============================================================================
TTY_DEV="/dev/tty"

_tty_read() {
  local prompt="$1" default="${2:-}"
  local ans=""
  if [[ -r "$TTY_DEV" && -w "$TTY_DEV" ]]; then
    printf "%s" "$prompt" >"$TTY_DEV"
    IFS= read -r ans <"$TTY_DEV" || true
  else
    printf "%s" "$prompt"
    IFS= read -r ans || true
  fi
  [[ -n "$ans" ]] && printf "%s" "$ans" || printf "%s" "$default"
}

msg() {
  local t="$1"
  echo
  echo "== $APP =="
  echo -e "$t"
  echo "Log: $LOG_FILE"
  echo
}

yesno() {
  local q="$1"
  local a="$(_tty_read "$q [y/N]: " "")"
  [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

input() {
  local q="$1" def="${2:-}"
  _tty_read "$q [$def]: " "$def"
}

pass() {
  local q="$1"
  echo "(!) Password will be visible in this CLI mode."
  _tty_read "$q: " ""
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
    msg "No internet detected.\n1) Retry\n2) WiFi (iwctl)\n3) Shell\n4) Abort"
    local c="$(_tty_read "Select [1-4]: " "1")"
    case "$c" in
      1) ;;
      2)
        need iwctl || die "iwctl not found"
        local wlan ssid psk
        wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
        [[ -n "$wlan" ]] || { msg "No Wi-Fi interface."; continue; }
        ssid="$(input "SSID for $wlan" "")"
        [[ -n "$ssid" ]] || continue
        psk="$(pass "Password for '$ssid' (empty=open)")"
        iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
        iwctl station "$wlan" scan >/dev/null 2>&1 || true
        sleep 1
        if [[ -n "$psk" ]]; then
          iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || msg "WiFi failed."
        else
          iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || msg "WiFi failed."
        fi
        ;;
      3) msg "Shell. Type exit to return."; bash || true ;;
      4) die "Aborted" ;;
      *) ;;
    esac
  done
}

# =============================================================================
# Disk selection (robust)
# =============================================================================
list_disks() {
  lsblk -dnpo NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{printf "%-18s %-8s %s\n",$1,$2,$3}'
}

pick_disk_plain() {
  echo
  echo "=== Disks detected (target WILL be WIPED) ==="
  echo "NAME               SIZE     MODEL"
  echo "---------------------------------------------"
  local disks=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "$line"
    disks+=("$(awk '{print $1}' <<<"$line")")
  done < <(list_disks)

  ((${#disks[@]})) || return 1

  echo
  local d="$(_tty_read "Type disk path (ex: /dev/sda): " "")"
  echo "$d"
}

validate_disk() {
  local d="$1"
  [[ "$d" =~ ^/dev/ ]] || die "Invalid disk selection: '$d'"
  [[ -b "$d" ]] || die "Not a block device: '$d'"
}

# =============================================================================
# Repo filter helper
# =============================================================================
pkg_in_repos() { pacman -Si "$1" >/dev/null 2>&1; }
filter_existing_pkgs() {
  local out=()
  for p in "$@"; do
    if pkg_in_repos "$p"; then
      out+=("$p")
    else
      echo "[warn] repo-missing: $p (skip)"
    fi
  done
  printf "%s\n" "${out[@]}"
}

# =============================================================================
# MAIN
# =============================================================================
maybe_use_ramroot
fix_system_after_overlay

# baseline tools in live
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# minimal live deps (per your note)
pacman -Sy --noconfirm --needed \
  iwd networkmanager \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git \
  >/dev/null

msg "Welcome.\nThis will install DrapBox.\nStep 1: Internet check."
ensure_network

DISK="$(pick_disk_plain)" || die "No disks found."
validate_disk "$DISK"

HOSTNAME="$(input "Hostname (AirPlay name)" "drapbox")"
USERNAME="$(input "Admin user (sudo)" "drapnard")"
USERPASS="$(pass "Password for user '$USERNAME'")"
ROOTPASS="$(pass "Password for root")"

TZ="$(input "Timezone (ex: Europe/Paris)" "Europe/Paris")"
LOCALE="$(input "Locale (ex: en_US.UTF-8, fr_FR.UTF-8)" "en_US.UTF-8")"
KEYMAP="$(input "Keymap (ex: us, fr, de)" "us")"

FS="$(input "FS (ext4/btrfs)" "ext4")"
[[ "$FS" == "ext4" || "$FS" == "btrfs" ]] || die "FS must be ext4 or btrfs"

SWAP_G="$(input "Swap GiB (0,2,4,8,12,16)" "0")"
ATV_VARIANT="$(input "Waydroid variant (GAPPS/VANILLA)" "GAPPS")"
AUTOSWITCH="$(input "Auto-switch (ON/OFF)" "ON")"
HWACCEL="$(input "HW decode (ON/OFF)" "ON")"
AUTOLOGIN="no"; yesno "Appliance mode: autologin on TTY1 + auto-start Sway?" && AUTOLOGIN="yes"
AUTO_REBOOT="yes"; yesno "Auto reboot after install?" && AUTO_REBOOT="yes" || AUTO_REBOOT="no"

echo
echo "SUMMARY:"
echo "Disk:     $DISK"
echo "FS:       $FS"
echo "Swap:     ${SWAP_G}GiB"
echo "TZ:       $TZ"
echo "Locale:   $LOCALE"
echo "Keymap:   $KEYMAP"
echo "Hostname: $HOSTNAME"
echo "User:     $USERNAME"
echo "Waydroid: $ATV_VARIANT"
echo "Autosw:   $AUTOSWITCH"
echo "HWdec:    $HWACCEL"
echo "Autologin:$AUTOLOGIN"
echo "Log:      $LOG_FILE"
echo
yesno "Proceed?" || die "Aborted"

msg "Partitioning + formatting."
_tty_read "Press Enter to continue..." ""

umount -R "$MNT" >/dev/null 2>&1 || true
swapoff -a >/dev/null 2>&1 || true

# safer wipe: stop if mounted
if findmnt -rn -S "${DISK}" >/dev/null 2>&1; then
  die "Disk $DISK still has mounted partitions. Unmount first."
fi

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

msg "Installing base system + DrapBox stack (can take a while)…"
_tty_read "Press Enter to continue..." ""

BASE_PKGS=(
  base linux linux-firmware
  networkmanager iwd wpa_supplicant
  sudo git curl jq
  sway foot wl-clipboard wlr-randr xorg-xwayland
  pipewire wireplumber pipewire-audio
  xdg-desktop-portal xdg-desktop-portal-wlr
  plymouth
  python python-gobject gtk3 gtk-layer-shell gnome-themes-extra adwaita-icon-theme
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gstreamer-vaapi
  sqlite qrencode
  bluez bluez-utils
  socat psmisc procps
  base-devel
)

pacstrap -K "$MNT" "${BASE_PKGS[@]}"

# optional repo packages (skip if missing)
OPTIONAL_REPO_PKGS=( waydroid )
mapfile -t OK_OPT < <(filter_existing_pkgs "${OPTIONAL_REPO_PKGS[@]}")
((${#OK_OPT[@]})) && pacstrap -K "$MNT" "${OK_OPT[@]}"

genfstab -U "$MNT" > "$MNT/etc/fstab"

# swapfile
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

# Persist choices
mkdir -p "$MNT/var/lib/drapbox"
echo "$ATV_VARIANT" > "$MNT/var/lib/drapbox/waydroid_variant"
echo "$AUTOSWITCH"  > "$MNT/var/lib/drapbox/autoswitch"
echo "$HWACCEL"     > "$MNT/var/lib/drapbox/hwaccel"

# ---- Chroot config + AUR via paru-bin ----
cat >"$MNT/root/drapbox-chroot.sh" <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
HOSTNAME="$1"; USERNAME="$2"; USERPASS="$3"; ROOTPASS="$4"; TZ="$5"; LOCALE="$6"; KEYMAP="$7"; AUTOLOGIN="$8"; FS="$9"

# pacman.conf fixes (ILoveCandy must be global, not in repo sections)
grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '1iILoveCandy\n' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf || true

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

# sudo: allow wheel, and allow pacman NOPASSWD during install (for paru)
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo '%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/pacman-key' >/etc/sudoers.d/99-drapbox-pacman
chmod 440 /etc/sudoers.d/99-drapbox-pacman

systemctl enable NetworkManager
systemctl enable iwd
systemctl enable bluetooth

# mkinitcpio + systemd-boot
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

# GTK defaults
mkdir -p /etc/environment.d
cat >/etc/environment.d/90-drapbox.conf <<'EOF'
GTK_THEME=Adwaita:dark
GDK_BACKEND=wayland
EOF

loginctl enable-linger "$USERNAME" || true

UHOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
install -d "$UHOME/.config/gtk-3.0" "$UHOME/.config/sway"
chown -R "$USERNAME:$USERNAME" "$UHOME/.config"

cat >"$UHOME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
EOF
chown "$USERNAME:$USERNAME" "$UHOME/.config/gtk-3.0/settings.ini"

# -----------------------------------------------------------------------------
# AUR: install paru-bin + AUR packages inside chroot (non-interactive)
# -----------------------------------------------------------------------------
echo "[aur] installing paru-bin…"
pacman -Sy --noconfirm --needed git base-devel curl

# build as user (root should not run makepkg)
sudo -u "$USERNAME" bash -lc '
set -euo pipefail
cd /tmp
rm -rf paru-bin
git clone https://aur.archlinux.org/paru-bin.git
cd paru-bin
makepkg -si --noconfirm --needed
'

# AUR packages (prefer -bin)
AUR_PKGS=(
  uxplay-bin
  gnome-network-displays
)

echo "[aur] installing AUR packages: ${AUR_PKGS[*]}"
sudo -u "$USERNAME" bash -lc '
set -euo pipefail
paru -S --noconfirm --needed '"${AUR_PKGS[*]}"'
'

# (optional) tighten sudo again after install
rm -f /etc/sudoers.d/99-drapbox-pacman

echo "[aur] done."
CHROOT

chmod +x "$MNT/root/drapbox-chroot.sh"
arch-chroot "$MNT" /root/drapbox-chroot.sh \
  "$HOSTNAME" "$USERNAME" "$USERPASS" "$ROOTPASS" "$TZ" "$LOCALE" "$KEYMAP" "$AUTOLOGIN" "$FS"

echo
echo "✅ Install complete."
echo "Log file: $LOG_FILE"
echo

umount -R "$MNT" >/dev/null 2>&1 || true

if [[ "$AUTO_REBOOT" == "yes" ]]; then
  msg "Install complete ✅\nRebooting now…"
  reboot
else
  msg "Install complete ✅\nAuto-reboot disabled.\nDropping to shell."
  bash
fi
