#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v5 (Zenity Live)"
MNT=/mnt

die(){ echo "✗ $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

# ---- ArchISO + UEFI guards ----
[[ -f /etc/arch-release ]] || die "Run from Arch Linux ISO (archiso)."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI required (boot the ISO in UEFI mode)."

need pacman
need curl

# =============================================================================
# Robust launcher
# - Snapshot to real file (works with: bash <(curl ...))
# - RAM-root overlay when airootfs is low (skip if already active)
# - Fix pacman keyring in overlay WITHOUT rm -rf (busy on archiso)
# - Start X11 once (no bash -c, no -l, no lost functions)
# =============================================================================

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/install.sh}"
SELF="${SELF:-/run/drapbox-installer.sh}"

_snapshot_self() {
  mkdir -p "$(dirname "$SELF")"
  [[ -s "$SELF" ]] && return 0

  # Try to read current script (even if /dev/fd/*)
  if [[ -r "${0:-}" ]]; then
    cat "$0" > "$SELF" 2>/dev/null || true
  fi

  # Still empty? Re-download
  if [[ ! -s "$SELF" ]]; then
    curl -fsSL "$SCRIPT_URL" -o "$SELF"
  fi

  chmod +x "$SELF"
}
_snapshot_self

# Stages: tty -> x11
DRAPBOX_STAGE="${DRAPBOX_STAGE:-tty}"

# Overlay flags
IN_RAMROOT="${IN_RAMROOT:-0}"
IN_X11="${IN_X11:-0}"

root_free_mb() { df -Pm / | awk 'NR==2{print $4}'; }
ram_total_mb() { awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo; }

is_drapbox_ramroot_active() {
  [[ "${IN_RAMROOT:-0}" == "1" ]] && return 0
  local fst
  fst="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [[ "$fst" == "overlay" ]] && grep -q "/run/drapbox-ramroot" /proc/mounts 2>/dev/null
}

mark_ramroot_if_detected() {
  if is_drapbox_ramroot_active; then
    export IN_RAMROOT=1
  fi
}

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

  # Clean half states from previous attempts
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

  for d in proc sys dev run tmp; do
    mkdir -p "/run/drapbox-ramroot/merged/$d"
  done
  mount --bind /proc /run/drapbox-ramroot/merged/proc
  mount --bind /sys  /run/drapbox-ramroot/merged/sys
  mount --bind /dev  /run/drapbox-ramroot/merged/dev
  mount --bind /run  /run/drapbox-ramroot/merged/run
  mount --bind /tmp  /run/drapbox-ramroot/merged/tmp

  # Copy stable script into merged root
  install -m 0755 "$SELF" /run/drapbox-ramroot/merged/tmp/drapbox-run

  # Re-exec FROM THE TOP inside overlay (functions are preserved because script restarts)
  export IN_RAMROOT=1
  exec chroot /run/drapbox-ramroot/merged /tmp/drapbox-run
}

maybe_use_ramroot() {
  mark_ramroot_if_detected
  (( IN_RAMROOT == 1 )) && return 0

  # If already mounted (rerun), just mark and continue
  if mountpoint -q /run/drapbox-ramroot/merged 2>/dev/null; then
    export IN_RAMROOT=1
    return 0
  fi

  local free_mb mem_mb
  free_mb="$(root_free_mb)"
  mem_mb="$(ram_total_mb)"

  local threshold_mb=350

  local want_mb
  if   (( mem_mb <= 4096 )); then
    want_mb=1024
  elif (( mem_mb <= 6144 )); then
    want_mb=1536
  elif (( mem_mb <= 8192 )); then
    want_mb=2048
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

  # GNUPG: do NOT rm -rf (can be busy on archiso)
  install -d -m 700 /etc/pacman.d/gnupg
  : > /etc/pacman.d/gnupg/.drapbox_copyup 2>/dev/null || true
  chmod 700 /etc/pacman.d/gnupg || true

  pkill -x gpg-agent >/dev/null 2>&1 || true
  pkill -x dirmngr   >/dev/null 2>&1 || true
  rm -f /etc/pacman.d/gnupg/S.gpg-agent* \
        /etc/pacman.d/gnupg/.#* \
        /etc/pacman.d/gnupg/*.lock \
        /etc/pacman.d/gnupg/crls.d/*.lock \
        >/dev/null 2>&1 || true

  systemctl start haveged >/dev/null 2>&1 || true
  systemctl start rngd    >/dev/null 2>&1 || true

  pacman-key --init >/dev/null 2>&1 || true
  pacman-key --populate archlinux >/dev/null 2>&1 || true

  echo "• [ramroot] Done."
}

# Start network early (safe)
systemctl start iwd >/dev/null 2>&1 || true
systemctl start NetworkManager >/dev/null 2>&1 || true

# Overlay if needed
maybe_use_ramroot
fix_system_after_overlay

# Ensure keyring package (idempotent)
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# -------------------------------
# ArchISO: reduce airootfs pressure (pacman cache + sync db in tmpfs)
# -------------------------------
mem_gb=$(awk '/MemTotal/ {printf "%.0f\n", $2/1024/1024}' /proc/meminfo)
if (( mem_gb <= 4 )); then
  PACMAN_PKG_CACHE_SIZE=768M
  PACMAN_SYNC_SIZE=128M
elif (( mem_gb <= 8 )); then
  PACMAN_PKG_CACHE_SIZE=1536M
  PACMAN_SYNC_SIZE=256M
else
  PACMAN_PKG_CACHE_SIZE=2048M
  PACMAN_SYNC_SIZE=512M
fi

_mktmpfs() {
  local mp="$1" size="$2"
  mkdir -p "$mp"
  mountpoint -q "$mp" || mount -t tmpfs -o "size=${size},mode=0755" tmpfs "$mp"
}

_mktmpfs /run/drapbox-pacman-pkg "$PACMAN_PKG_CACHE_SIZE"
mkdir -p /var/cache/pacman
mountpoint -q /var/cache/pacman/pkg || mount --bind /run/drapbox-pacman-pkg /var/cache/pacman/pkg

_mktmpfs /run/drapbox-pacman-sync "$PACMAN_SYNC_SIZE"
mkdir -p /var/lib/pacman/sync
mountpoint -q /var/lib/pacman/sync || mount --bind /run/drapbox-pacman-sync /var/lib/pacman/sync

# ---- Live deps ----
pacman -Sy --noconfirm --needed \
  zenity \
  xorg-server xorg-xinit xterm openbox \
  networkmanager iwd iwctl nmtui \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git \
  >/dev/null

# Optional OSK (best effort)
if ! command -v matchbox-keyboard >/dev/null 2>&1; then
  pacman -S --noconfirm --needed matchbox-keyboard >/dev/null 2>&1 || true
fi
if ! command -v matchbox-keyboard >/dev/null 2>&1; then
  pacman -S --noconfirm --needed onboard >/dev/null 2>&1 || true
fi
if ! command -v matchbox-keyboard >/dev/null 2>&1 && ! command -v onboard >/dev/null 2>&1; then
  pacman -S --noconfirm --needed florence >/dev/null 2>&1 || true
fi

need zenity
need startx
need xterm
need openbox-session
need iwctl
need nmtui
need sgdisk
need lsblk
need mkfs.fat
need pacstrap
need arch-chroot
need genfstab

# ---- Start X11 once (no bash wrapper, no -l, no -c) ----
if [[ -z "${DISPLAY:-}" && "$DRAPBOX_STAGE" == "tty" ]]; then
  export DRAPBOX_STAGE="x11"

  # Stable runner for X relaunch
  if [[ -s "$SELF" ]]; then
    cp "$SELF" /tmp/drapbox-run
  else
    curl -fsSL "$SCRIPT_URL" -o /tmp/drapbox-run
  fi
  chmod +x /tmp/drapbox-run

  cat >/tmp/drapbox-xinitrc <<'EOF'
xsetroot -solid "#0b0b0b"
openbox-session &
exec xterm -fa "Monospace" -fs 12 -e /tmp/drapbox-run
EOF

  exec startx /tmp/drapbox-xinitrc -- :0
fi

# ---- Zenity helpers ----
zinfo(){ zenity --info --title "$APP" --width=680 --text="$1"; }
zerr(){ zenity --error --title "$APP" --width=680 --text="$1"; }
zask(){ zenity --question --title "$APP" --width=680 --text="$1"; }
zentry(){ zenity --entry --title "$APP" --width=680 --text="$1" --entry-text="${2:-}"; }
zpass(){ zenity --password --title "$APP" --width=680 --text="$1"; }
zlist(){ zenity --list --title "$1" --width=980 --height=560 --column="$2" --column="$3" "${@:4}"; }

start_osk(){
  pkill -f matchbox-keyboard >/dev/null 2>&1 || true
  pkill -f onboard >/dev/null 2>&1 || true
  pkill -f florence >/dev/null 2>&1 || true

  if command -v matchbox-keyboard >/dev/null 2>&1; then
    (matchbox-keyboard >/dev/null 2>&1 &) || true
  elif command -v onboard >/dev/null 2>&1; then
    (onboard >/dev/null 2>&1 &) || true
  elif command -v florence >/dev/null 2>&1; then
    (florence >/dev/null 2>&1 &) || true
  else
    zerr "No on-screen keyboard available (matchbox-keyboard/onboard/florence not installed)."
  fi
}

is_online(){
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W2 archlinux.org >/dev/null 2>&1
}

ensure_network(){
  timedatectl set-ntp true >/dev/null 2>&1 || true

  while ! is_online; do
    local choice
    choice="$(zenity --list --title "$APP" --width=980 --height=560 \
      --text="No internet connection detected.\nChoose a method:" \
      --column="Action" --column="Description" \
      "ETH"   "Retry Ethernet / DHCP (just re-test)" \
      "WIFI"  "Connect Wi-Fi (iwctl)" \
      "NMTUI" "Network manager UI (nmtui)" \
      "OSK"   "Show on-screen keyboard" \
      "SHELL" "Open terminal (manual)" \
      "ABORT" "Abort" \
    )" || true

    case "${choice:-}" in
      ETH) ;;
      WIFI)
        local wlan ssid psk
        wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
        [[ -n "$wlan" ]] || { zerr "No Wi-Fi interface detected."; continue; }

        ssid="$(zentry "SSID for $wlan:" "")" || true
        [[ -n "${ssid:-}" ]] || continue

        zask "Show on-screen keyboard for password input?" && start_osk
        psk="$(zpass "Password for '$ssid' (leave empty if open network):")" || true

        iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
        iwctl station "$wlan" scan >/dev/null 2>&1 || true
        sleep 1

        if [[ -n "${psk:-}" ]]; then
          iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || zerr "Wi-Fi connection failed."
        else
          iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || zerr "Wi-Fi connection failed."
        fi
        ;;
      NMTUI)
        zinfo "Opening nmtui in a terminal.\nClose it to return."
        xterm -e nmtui || true
        ;;
      OSK) start_osk ;;
      SHELL)
        zinfo "Opening terminal.\nType 'exit' to return."
        xterm || true
        ;;
      ABORT|*) die "Aborted" ;;
    esac
  done
}

pick_timezone(){
  local filt tz
  filt="$(zentry "Timezone search (Paris / New_York / Tokyo). Empty = list:" "")" || true
  if [[ -n "${filt:-}" ]]; then
    mapfile -t tzs < <(timedatectl list-timezones | grep -i "$filt" | head -n 200)
  else
    mapfile -t tzs < <(timedatectl list-timezones | head -n 200)
  fi
  [[ ${#tzs[@]} -gt 0 ]] || { zerr "No timezone found."; return 1; }
  local data=()
  for t in "${tzs[@]}"; do data+=("$t" ""); done
  tz="$(zlist "Select timezone" "Timezone" " " "${data[@]}")" || return 1
  echo "$tz"
}

pick_disk(){
  mapfile -t lines < <(lsblk -dnpo NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{print $1 "|" $2 " " $3}')
  [[ ${#lines[@]} -gt 0 ]] || die "No disks found"
  local data=()
  for l in "${lines[@]}"; do data+=("${l%%|*}" "${l#*|}"); done
  zlist "Select target disk" "Disk" "Info" "${data[@]}"
}

# ---- Wizard start ----
zinfo "Welcome.\n\nThis will install DrapBox (Apple TV × Google TV vibe).\n\nStep 1: Internet check."
ensure_network

DISK="$(pick_disk)" || die "No disk selected"

HOSTNAME="$(zentry "Hostname (also used as AirPlay name):" "drapbox")" || die "No hostname"
USERNAME="$(zentry "Admin user (sudo):" "drapnard")" || die "No username"

zask "Show on-screen keyboard for passwords?" && start_osk
USERPASS="$(zpass "Password for user '$USERNAME':")" || die "No user password"
ROOTPASS="$(zpass "Password for root:")" || die "No root password"

TZ="$(pick_timezone)" || die "No timezone"
LOCALE="$(zentry "Locale (e.g. en_US.UTF-8, fr_FR.UTF-8):" "en_US.UTF-8")" || die "No locale"
KEYMAP="$(zentry "Keymap (e.g. us, fr, de):" "us")" || die "No keymap"

FS="$(zenity --list --radiolist --title "$APP" --width=760 --height=260 \
  --text="Root filesystem:" \
  --column="Pick" --column="FS" --column="Notes" \
  TRUE "ext4" "Simple and robust" \
  FALSE "btrfs" "Subvolumes (@, @home)" \
)" || die "No filesystem"

SWAP_G="$(zenity --list --radiolist --title "$APP" --width=760 --height=340 \
  --text="Swapfile size (GiB):" \
  --column="Pick" --column="GiB" --column="Notes" \
  TRUE "0" "No swapfile" \
  FALSE "2" "Light" \
  FALSE "4" "Common" \
  FALSE "8" "Recommended for 8GB RAM" \
  FALSE "12" "Extra headroom" \
  FALSE "16" "Large" \
)" || die "No swap choice"

ATV_VARIANT="$(zenity --list --radiolist --title "$APP" --width=980 --height=260 \
  --text="Waydroid AndroidTV build:" \
  --column="Pick" --column="Variant" --column="Notes" \
  TRUE "GAPPS" "Google apps included" \
  FALSE "VANILLA" "No Google apps (auto-setup)" \
)" || die "No ATV choice"

AUTOSWITCH="$(zenity --list --radiolist --title "$APP" --width=980 --height=240 \
  --text="Auto-switch (Casting ⇄ AndroidTV):" \
  --column="Pick" --column="Value" --column="Notes" \
  TRUE  "ON"  "Casting → WS1, return → WS2" \
  FALSE "OFF" "No automatic switching" \
)" || die "No autoswitch choice"

HWACCEL="$(zenity --list --radiolist --title "$APP" --width=980 --height=260 \
  --text="Waydroid video HW decode (VA-API):" \
  --column="Pick" --column="Value" --column="Notes" \
  TRUE  "ON"  "media.sf.hwaccel=1" \
  FALSE "OFF" "media.sf.hwaccel=0 (use if video issues)" \
)" || die "No hwaccel choice"

AUTOLOGIN="no"
zask "Appliance mode: autologin on TTY1 + auto-start Sway?" && AUTOLOGIN="yes"

CONFIRM_TEXT="SUMMARY (THIS WILL WIPE THE DISK)\n\nDisk: $DISK\nFS: $FS\nSwap: ${SWAP_G} GiB\nTimezone: $TZ\nLocale: $LOCALE\nKeymap: $KEYMAP\nHostname: $HOSTNAME\nUser: $USERNAME\nWaydroid: $ATV_VARIANT\nAuto-switch: $AUTOSWITCH\nHW decode: $HWACCEL\nAutologin: $AUTOLOGIN\n\nProceed?"
zask "$CONFIRM_TEXT" || die "Aborted"

# ---- Progress ----
PROG_FIFO="/tmp/drapbox-prog.$$"
mkfifo "$PROG_FIFO"
zenity --progress --title="$APP" --width=820 --text="Installing…" --percentage=0 < "$PROG_FIFO" &
PROG_PID=$!
p(){ echo "$1" > "$PROG_FIFO"; echo "# $2" > "$PROG_FIFO"; }
cleanup_prog(){ kill "$PROG_PID" >/dev/null 2>&1 || true; rm -f "$PROG_FIFO" || true; }
trap cleanup_prog EXIT

# ---- Partition / format ----
p 5 "Partitioning disk…"
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

p 12 "Formatting EFI…"
mkfs.fat -F32 -n EFI "$EFI_PART"

p 18 "Formatting ROOT ($FS)…"
if [[ "$FS" == "ext4" ]]; then
  mkfs.ext4 -F -L ROOT "$ROOT_PART"
else
  mkfs.btrfs -f -L ROOT "$ROOT_PART"
fi

p 25 "Mounting target…"
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot"
mount "$EFI_PART" "$MNT/boot"

if [[ "$FS" == "btrfs" ]]; then
  p 28 "Creating BTRFS subvolumes…"
  btrfs subvolume create "$MNT/@"
  btrfs subvolume create "$MNT/@home"
  umount "$MNT"
  mount -o subvol=@ "$ROOT_PART" "$MNT"
  mkdir -p "$MNT/home" "$MNT/boot"
  mount -o subvol=@home "$ROOT_PART" "$MNT/home"
  mount "$EFI_PART" "$MNT/boot"
fi

# ---- Install system (ALL heavy packages go here) ----
p 35 "Installing base system + DrapBox stack…"
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

p 55 "Generating fstab…"
genfstab -U "$MNT" > "$MNT/etc/fstab"

p 60 "Configuring swapfile…"
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

# Persist installer choices for first boot
mkdir -p "$MNT/var/lib/drapbox"
echo "$ATV_VARIANT" > "$MNT/var/lib/drapbox/waydroid_variant"
echo "$AUTOSWITCH"  > "$MNT/var/lib/drapbox/autoswitch"
echo "$HWACCEL"     > "$MNT/var/lib/drapbox/hwaccel"

# ---- Chroot config ----
p 72 "Configuring installed system…"
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

p 95 "Finalizing…"
umount -R "$MNT" || true
p 100 "Done."
sleep 1

zinfo "Install complete ✅

Rebooting now…"
reboot
