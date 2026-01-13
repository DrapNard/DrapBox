#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v5 (CLI Live)"
MNT=/mnt

die(){ echo "✗ $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

# ---- guards ----
[[ -f /etc/arch-release ]] || die "Run from Arch Linux ISO (archiso)."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI required (boot ISO in UEFI mode)."

need pacman
need curl

# Force TERM for ncurses tools
export TERM="${TERM:-linux}"

# =============================================================================
# Logging (tee) + keep real TTY for UI
# =============================================================================
LOG_DIR="/run/drapbox"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"

TTY_DEV="${TTY_DEV:-/dev/tty}"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== DrapBox installer log: $LOG_FILE ==="
echo "Started: $(date -Is)"
echo "TERM=$TERM"
echo

on_error() {
  local ec=$?
  echo
  echo "✗ Installer crashed (exit=$ec)."
  echo "Log: $LOG_FILE"
  echo
  # Drop to shell for debug if possible
  if [[ -r "$TTY_DEV" && -w "$TTY_DEV" ]]; then
    echo "Dropping to shell for debug. Type 'exit' to quit." >"$TTY_DEV"
    bash </dev/tty >/dev/tty 2>/dev/tty || true
  fi
  exit $ec
}
trap on_error ERR

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

  # Clean half state
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

  # Copy stable runner
  install -m 0755 "$SELF" /run/drapbox-ramroot/merged/tmp/drapbox-run

  # Keep env (no env -i) + keep UI TTY
  export IN_RAMROOT=1
  export LOG_FILE LOG_DIR SCRIPT_URL SELF TERM TTY_DEV
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
# UI backend: TTY-safe whiptail or plain
# =============================================================================
UI_BACKEND="plain"

ensure_cli_ui() {
  if command -v whiptail >/dev/null 2>&1 && [[ -r "$TTY_DEV" && -w "$TTY_DEV" ]]; then
    UI_BACKEND="whiptail"
    return 0
  fi

  # Install minimal ncurses UI (best effort)
  pacman -Sy --noconfirm --needed libnewt >/dev/null 2>&1 || true

  if command -v whiptail >/dev/null 2>&1 && [[ -r "$TTY_DEV" && -w "$TTY_DEV" ]]; then
    UI_BACKEND="whiptail"
  else
    UI_BACKEND="plain"
  fi
}

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

ui_msg() {
  local msg="$1"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    whiptail --title "$APP" --msgbox "$msg\n\nLog: $LOG_FILE" 14 78 \
      </dev/tty >/dev/tty 2>/dev/tty || true
  else
    echo
    echo "== $APP ==" >"$TTY_DEV" 2>/dev/null || true
    echo -e "$msg" >"$TTY_DEV" 2>/dev/null || echo -e "$msg"
    echo "Log: $LOG_FILE" >"$TTY_DEV" 2>/dev/null || true
    _tty_read "Press Enter to continue..." ""
    echo
  fi
}

ui_yesno() {
  local msg="$1"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    whiptail --title "$APP" --yesno "$msg" 12 78 \
      </dev/tty >/dev/tty 2>/dev/tty
  else
    local ans
    ans="$(_tty_read "$msg [y/N]: " "")"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  fi
}

ui_input() {
  local msg="$1" def="${2:-}"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    whiptail --title "$APP" --inputbox "$msg" 12 78 "$def" --output-fd 1 \
      </dev/tty 2>/dev/tty
  else
    _tty_read "$msg [$def]: " "$def"
  fi
}

ui_pass() {
  local msg="$1"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    whiptail --title "$APP" --passwordbox "$msg" 12 78 --output-fd 1 \
      </dev/tty 2>/dev/tty
  else
    echo "(!) Password will be visible in plain mode." >"$TTY_DEV" 2>/dev/null || true
    _tty_read "$msg: " ""
  fi
}

ui_menu() {
  local title="$1"; shift
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    whiptail --title "$APP" --menu "$title" 18 78 10 "$@" --output-fd 1 \
      </dev/tty 2>/dev/tty
    return $?
  fi

  echo >"$TTY_DEV" 2>/dev/null || true
  echo "== $title ==" >"$TTY_DEV" 2>/dev/null || echo "== $title =="
  local i=0
  local tags=()
  while (( $# )); do
    local tag="$1"; local desc="$2"; shift 2 || true
    i=$((i+1))
    tags+=("$tag")
    printf " %2d) %-12s %s\n" "$i" "$tag" "$desc" >"$TTY_DEV" 2>/dev/null || \
      printf " %2d) %-12s %s\n" "$i" "$tag" "$desc"
  done
  local choice
  choice="$(_tty_read "Select [1-$i]: " "")"
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= i )) || return 1
  echo "${tags[$((choice-1))]}"
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
    local choice
    choice="$(ui_menu "No internet detected. Choose:" \
      "ETH"   "Retry Ethernet/DHCP (re-test)" \
      "WIFI"  "Connect Wi-Fi (iwctl)" \
      "SHELL" "Open shell (manual)" \
      "ABORT" "Abort install"
    )" || true

    case "${choice:-}" in
      ETH) ;;
      WIFI)
        need iwctl || die "iwctl not found (should come with iwd)"
        local wlan ssid psk
        wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
        [[ -n "$wlan" ]] || { ui_msg "No Wi-Fi interface detected."; continue; }

        ssid="$(ui_input "SSID for $wlan:" "")" || true
        [[ -n "${ssid:-}" ]] || continue
        psk="$(ui_pass "Password for '$ssid' (empty if open network):")" || true

        iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
        iwctl station "$wlan" scan >/dev/null 2>&1 || true
        sleep 1
        if [[ -n "${psk:-}" ]]; then
          iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || ui_msg "Wi-Fi connection failed."
        else
          iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || ui_msg "Wi-Fi connection failed."
        fi
        ;;
      SHELL)
        ui_msg "Shell opened. Type 'exit' to return."
        bash </dev/tty >/dev/tty 2>/dev/tty || true
        ;;
      ABORT|*) die "Aborted" ;;
    esac
  done
}

pick_disk(){
  mapfile -t lines < <(lsblk -dnpo NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{print $1 "|" $2 " " $3}')
  [[ ${#lines[@]} -gt 0 ]] || die "No disks found"
  local args=()
  for l in "${lines[@]}"; do args+=("${l%%|*}" "${l#*|}"); done
  ui_menu "Select target disk (WILL BE WIPED):" "${args[@]}"
}

pick_timezone(){
  local filt tz
  filt="$(ui_input "Timezone search (Paris/New_York/Tokyo). Empty=list first 200:" "")" || true
  if [[ -n "${filt:-}" ]]; then
    mapfile -t tzs < <(timedatectl list-timezones | grep -i "$filt" | head -n 200)
  else
    mapfile -t tzs < <(timedatectl list-timezones | head -n 200)
  fi
  [[ ${#tzs[@]} -gt 0 ]] || die "No timezone found"
  local args=()
  for t in "${tzs[@]}"; do args+=("$t" ""); done
  tz="$(ui_menu "Select timezone:" "${args[@]}")" || die "No timezone"
  echo "$tz"
}

validate_disk() {
  local d="$1"
  [[ "$d" =~ ^/dev/ ]] || die "Invalid disk selection: '$d' (UI failed). Log: $LOG_FILE"
  [[ -b "$d" ]] || die "Disk is not a block device: '$d'"
}

# =============================================================================
# MAIN
# =============================================================================
maybe_use_ramroot
fix_system_after_overlay
ensure_cli_ui

# Keyring baseline
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# Minimal live deps (NETWORK = iwd + networkmanager ONLY)
pacman -Sy --noconfirm --needed \
  iwd networkmanager \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git \
  >/dev/null

ui_msg "Welcome.\n\nThis will install DrapBox.\n\nStep 1: Internet check."
ensure_network

DISK="$(pick_disk)" || die "No disk selected"
validate_disk "$DISK"

HOSTNAME="$(ui_input "Hostname (also AirPlay name):" "drapbox")" || die "No hostname"
USERNAME="$(ui_input "Admin user (sudo):" "drapnard")" || die "No username"
USERPASS="$(ui_pass "Password for user '$USERNAME':")" || die "No user password"
ROOTPASS="$(ui_pass "Password for root:")" || die "No root password"

TZ="$(pick_timezone)"
LOCALE="$(ui_input "Locale (e.g. en_US.UTF-8, fr_FR.UTF-8):" "en_US.UTF-8")" || die "No locale"
KEYMAP="$(ui_input "Keymap (e.g. us, fr, de):" "us")" || die "No keymap"

FS="$(ui_menu "Root filesystem:" \
  "ext4"  "Simple and robust" \
  "btrfs" "Subvolumes (@, @home)"
)" || die "No filesystem"

SWAP_G="$(ui_menu "Swapfile size (GiB):" \
  "0"  "No swapfile" \
  "2"  "Light" \
  "4"  "Common" \
  "8"  "Recommended for 8GB RAM" \
  "12" "Extra headroom" \
  "16" "Large"
)" || die "No swap choice"

ATV_VARIANT="$(ui_menu "Waydroid AndroidTV build:" \
  "GAPPS"   "Google apps included" \
  "VANILLA" "No Google apps (auto-setup)"
)" || die "No ATV choice"

AUTOSWITCH="$(ui_menu "Auto-switch (Casting ⇄ AndroidTV):" \
  "ON"  "Casting → WS1, return → WS2" \
  "OFF" "No automatic switching"
)" || die "No autoswitch choice"

HWACCEL="$(ui_menu "Waydroid video HW decode (VA-API):" \
  "ON"  "media.sf.hwaccel=1" \
  "OFF" "media.sf.hwaccel=0 (use if issues)"
)" || die "No hwaccel choice"

AUTOLOGIN="no"
ui_yesno "Appliance mode: autologin on TTY1 + auto-start Sway?" && AUTOLOGIN="yes" || true

AUTO_REBOOT="yes"
ui_yesno "Auto reboot after install?\n\nYes = reboot automatically\nNo = stop with shell + log path" && AUTO_REBOOT="yes" || AUTO_REBOOT="no"

CONFIRM=$(
cat <<EOF
SUMMARY (THIS WILL WIPE THE DISK)

Disk: $DISK
FS: $FS
Swap: ${SWAP_G} GiB
Timezone: $TZ
Locale: $LOCALE
Keymap: $KEYMAP
Hostname: $HOSTNAME
User: $USERNAME
Waydroid: $ATV_VARIANT
Auto-switch: $AUTOSWITCH
HW decode: $HWACCEL
Autologin: $AUTOLOGIN

Log file: $LOG_FILE

Proceed?
EOF
)

ui_yesno "$CONFIRM" || die "Aborted"

# ---- Partition / format ----
ui_msg "Partitioning + formatting…"
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
ui_msg "Installing base system + DrapBox stack (this can take a while)…"
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

UHOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
install -d "$UHOME/.config/gtk-3.0" "$UHOME/.config/sway" "$UHOME/.config/systemd/user/default.target.wants"
chown -R "$USERNAME:$USERNAME" "$UHOME/.config"

cat >"$UHOME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
EOF
chown "$USERNAME:$USERNAME" "$UHOME/.config/gtk-3.0/settings.ini"
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
  ui_msg "Install complete ✅\n\nRebooting now…"
  reboot
else
  ui_msg "Install complete ✅\n\nAuto-reboot disabled.\n\nLog: $LOG_FILE\n\nDropping to shell."
  echo "Auto-reboot disabled. Log: $LOG_FILE"
  bash </dev/tty >/dev/tty 2>/dev/tty
fi
