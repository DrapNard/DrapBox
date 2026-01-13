#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v5"
MNT=/mnt

die(){ echo "✗ $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

# ---- ArchISO + UEFI guards ----
[[ -f /etc/arch-release ]] || die "Run from Arch Linux ISO (archiso)."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI required (boot the ISO in UEFI mode)."

need pacman
need curl

# ---- Live (RAM) deps: only what the installer needs ----
# (No Waydroid/Miracast/UxPlay here; those go into the installed system via pacstrap)
pacman -Sy --noconfirm --needed \
  sway foot xorg-xwayland \
  zenity \
  networkmanager iwd \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  gtk3 gtk-layer-shell python-gobject \
  gnome-themes-extra adwaita-icon-theme \
  >/dev/null

need zenity
need sway
need iwctl
need nmtui
need sgdisk
need lsblk
need mkfs.fat
need pacstrap
need arch-chroot
need genfstab

# ---- GTK theme for the installer (Wayland) ----
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
mkdir -p "$XDG_RUNTIME_DIR" || true

export GTK_THEME="Adwaita:dark"
export XDG_CURRENT_DESKTOP="sway"
export GDK_BACKEND="wayland"
export QT_QPA_PLATFORM="wayland"

mkdir -p /root/.config/gtk-3.0
cat >/root/.config/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
EOF

# ---- Relaunch inside Sway if not already ----
if [[ -z "${SWAYSOCK:-}" ]]; then
  cat > /tmp/drapbox-sway.config <<'EOF'
output * bg #0b0b0b solid_color
exec_always --no-startup-id foot -e bash -lc "/tmp/drapbox-run"
EOF
  cp "$0" /tmp/drapbox-run
  chmod +x /tmp/drapbox-run
  exec sway -c /tmp/drapbox-sway.config
fi

# ---- Zenity helpers ----
zinfo(){ zenity --info --title "$APP" --width=680 --text="$1"; }
zerr(){ zenity --error --title "$APP" --width=680 --text="$1"; }
zask(){ zenity --question --title "$APP" --width=680 --text="$1"; }
zentry(){ zenity --entry --title "$APP" --width=680 --text="$1" --entry-text="${2:-}"; }
zpass(){ zenity --password --title "$APP" --width=680 --text="$1"; }
zlist(){ zenity --list --title "$1" --width=980 --height=560 --column="$2" --column="$3" "${@:4}"; }

start_osk(){
  pkill -f wvkbd >/dev/null 2>&1 || true
  (GTK_THEME="Adwaita:dark" wvkbd -L 380 -H 240 >/dev/null 2>&1 &) || true
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
      "OSK"   "Show on-screen keyboard (wvkbd)" \
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
        foot -e nmtui || true
        ;;
      OSK) start_osk ;;
      SHELL)
        zinfo "Opening terminal.\nType 'exit' to return."
        foot -e bash || true
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

# ---- Install system ----
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

# --- Faster pacman defaults in the installed system ---
# (Avoids “update twice”; pacstrap already installs latest from repos, but this speeds later installs.)
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf || true
grep -q '^ILoveCandy' /etc/pacman.conf || echo 'ILoveCandy' >> /etc/pacman.conf

# Time/locale
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc
sed -i "s/^#\s*${LOCALE}/${LOCALE}/" /etc/locale.gen || true
sed -i 's/^#\s*en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF

# Users
echo "root:$ROOTPASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager
systemctl enable iwd
systemctl enable bluetooth

# Plymouth in initramfs
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

# systemd-boot
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

# GTK theme (system-wide)
mkdir -p /etc/environment.d
cat >/etc/environment.d/90-drapbox.conf <<'EOF'
GTK_THEME=Adwaita:dark
GDK_BACKEND=wayland
EOF

# Allow user services
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

# --- AirPlay PIN overlay (AppleTV-like) ---
cat >/usr/local/bin/drapbox-airplay-pin-overlay <<'EOF'
#!/usr/bin/env python3
import sys, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import GtkLayerShell

CSS = b"""
* { font-family: "Inter", "Cantarell", "SF Pro Display", sans-serif; }
.window { background: rgba(0,0,0,0.45); }
.title { color: #fff; font-size: 46px; font-weight: 800; letter-spacing: 0.3px; }
.subtitle { color: rgba(255,255,255,0.82); font-size: 22px; font-weight: 600; margin-top: 6px; }
.digit { min-width: 118px; min-height: 148px; background: rgba(255,255,255,0.14);
  border-radius: 18px; border: 1px solid rgba(255,255,255,0.10); }
.digit-label { color: #fff; font-size: 66px; font-weight: 800; }
.hint { color: rgba(255,255,255,0.70); font-size: 16px; margin-top: 26px; }
"""

def die(msg):
  print(msg, file=sys.stderr); sys.exit(1)

def main():
  if len(sys.argv) < 3:
    die("Usage: drapbox-airplay-pin-overlay <hostname> <PIN4> [timeout_sec]")
  hostname = sys.argv[1]
  pin = sys.argv[2].strip()
  timeout_s = int(sys.argv[3]) if len(sys.argv) >= 4 else 25
  if len(pin) != 4 or not pin.isdigit():
    die("PIN must be 4 digits")

  win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
  win.set_decorated(False)
  win.set_app_paintable(True)
  win.get_style_context().add_class("window")

  GtkLayerShell.init_for_window(win)
  GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
  GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.NONE)
  for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM, GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
    GtkLayerShell.set_anchor(win, edge, True)
  GtkLayerShell.set_exclusive_zone(win, -1)

  provider = Gtk.CssProvider()
  provider.load_from_data(CSS)
  Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

  root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
  root.set_halign(Gtk.Align.CENTER)
  root.set_valign(Gtk.Align.CENTER)

  title = Gtk.Label(label="AirPlay Code"); title.get_style_context().add_class("title")
  subtitle = Gtk.Label(label=hostname); subtitle.get_style_context().add_class("subtitle")

  row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
  row.set_halign(Gtk.Align.CENTER); row.set_valign(Gtk.Align.CENTER); row.set_margin_top(34)

  for ch in pin:
    frame = Gtk.EventBox(); frame.get_style_context().add_class("digit")
    lbl = Gtk.Label(label=ch); lbl.get_style_context().add_class("digit-label")
    inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    inner.set_halign(Gtk.Align.CENTER); inner.set_valign(Gtk.Align.CENTER)
    inner.pack_start(lbl, True, True, 0)
    frame.add(inner); row.pack_start(frame, False, False, 0)

  hint = Gtk.Label(label="Enter this code on your device to connect.")
  hint.get_style_context().add_class("hint")

  root.pack_start(title, False, False, 0)
  root.pack_start(subtitle, False, False, 0)
  root.pack_start(row, False, False, 0)
  root.pack_start(hint, False, False, 0)

  win.add(root); win.show_all()
  GLib.timeout_add_seconds(timeout_s, lambda: (Gtk.main_quit(), False)[1])
  Gtk.main()

if __name__ == "__main__":
  main()
EOF
chmod +x /usr/local/bin/drapbox-airplay-pin-overlay

# --- UxPlay always-on daemon (PIN overlay + autoswitch) ---
cat >/usr/local/bin/drapbox-uxplayd <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
NAME="$(cat /etc/hostname)"
AUTOSWITCH="$(cat /var/lib/drapbox/autoswitch 2>/dev/null || echo ON)"

sw() {
  [[ "$AUTOSWITCH" == "ON" ]] || return 0
  [[ -S "${SWAYSOCK:-}" ]] || return 0
  command -v swaymsg >/dev/null 2>&1 || return 0
  swaymsg workspace number "$1" >/dev/null 2>&1 || true
}

show_pin() {
  local pin="$1"
  sw 1
  /usr/local/bin/drapbox-airplay-pin-overlay "$NAME" "$pin" 25 >/dev/null 2>&1 &
}

uxplay -n "$NAME" -nh -pin -reg -vsync 2>&1 | while IFS= read -r line; do
  echo "$line"
  if [[ "$line" =~ ([Pp][Ii][Nn][^0-9]*)([0-9]{4}) ]]; then
    show_pin "${BASH_REMATCH[2]}" &
  fi
  if [[ "$AUTOSWITCH" == "ON" ]] && echo "$line" | grep -qiE "stop mirroring|stopped|disconnect|closed"; then
    sw 2
  fi
done
EOF
chmod +x /usr/local/bin/drapbox-uxplayd

# --- Miracast always-on daemon (gnome-network-displays) ---
cat >/usr/local/bin/drapbox-miracastd <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
AUTOSWITCH="$(cat /var/lib/drapbox/autoswitch 2>/dev/null || echo ON)"

sw() {
  [[ "$AUTOSWITCH" == "ON" ]] || return 0
  [[ -S "${SWAYSOCK:-}" ]] || return 0
  command -v swaymsg >/dev/null 2>&1 || return 0
  swaymsg workspace number "$1" >/dev/null 2>&1 || true
}

gnome-network-displays 2>&1 | while IFS= read -r line; do
  echo "$line"
  if echo "$line" | grep -qiE "session.*start|connected|stream.*start|starting.*stream"; then sw 1; fi
  if echo "$line" | grep -qiE "session.*end|disconnected|stream.*stop|stopped"; then sw 2; fi
done
EOF
chmod +x /usr/local/bin/drapbox-miracastd

# --- User services (always-on) ---
install -d "$UHOME/.config/systemd/user" "$UHOME/.config/systemd/user/default.target.wants"

cat >"$UHOME/.config/systemd/user/drapbox-uxplay.service" <<'EOF'
[Unit]
Description=DrapBox UxPlay (always-on AirPlay)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/drapbox-uxplayd
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOF

cat >"$UHOME/.config/systemd/user/drapbox-miracast.service" <<'EOF'
[Unit]
Description=DrapBox Miracast (always-on)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/drapbox-miracastd
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOF

ln -sf ../drapbox-uxplay.service "$UHOME/.config/systemd/user/default.target.wants/drapbox-uxplay.service"
ln -sf ../drapbox-miracast.service "$UHOME/.config/systemd/user/default.target.wants/drapbox-miracast.service"
chown -R "$USERNAME:$USERNAME" "$UHOME/.config/systemd"

# --- Sway config (WS1 casting, WS2 AndroidTV) ---
cat >"$UHOME/.config/sway/config" <<'EOF'
default_border none
default_floating_border none

assign [app_id="uxplay"] workspace number 1
assign [app_id="gnome-network-displays"] workspace number 1
assign [app_id="waydroid.*"] workspace number 2

for_window [app_id="uxplay"] fullscreen enable
for_window [app_id="gnome-network-displays"] fullscreen enable

exec_always --no-startup-id waydroid session start
exec_always --no-startup-id waydroid show-full-ui

exec_always --no-startup-id systemctl --user start drapbox-uxplay.service
exec_always --no-startup-id systemctl --user start drapbox-miracast.service

workspace number 2
EOF
chown "$USERNAME:$USERNAME" "$UHOME/.config/sway/config"

# --- Host Actions dashboard ---
cat >/usr/local/bin/drapbox-host-actions.py <<'EOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess

PORT = 9876
def sh(cmd): subprocess.Popen(cmd, shell=True)

PAGE = """<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DrapBox</title>
<style>
body{font-family:system-ui, sans-serif;background:#000;color:#fff;margin:0;padding:24px}
h1{font-size:28px;margin:0 0 16px}
.btn{display:block;width:100%;padding:18px;margin:12px 0;background:#1f1f1f;color:#fff;border-radius:14px;text-decoration:none;font-size:20px;text-align:center}
.small{opacity:.7;font-size:14px;margin-top:18px}
</style></head><body>
<h1>DrapBox</h1>
<a class="btn" href="/do/airplay">AirPlay (restart)</a>
<a class="btn" href="/do/miracast">Miracast (restart)</a>
<a class="btn" href="/do/android_settings">Android Settings</a>
<a class="btn" href="/do/restart_waydroid">Restart Waydroid</a>
<a class="btn" href="/do/reboot">Reboot Host</a>
<div class="small">Local UI: /tv</div>
</body></html>"""

class H(BaseHTTPRequestHandler):
  def do_GET(self):
    if self.path in ("/", "/tv"):
      self.send_response(200); self.send_header("Content-Type","text/html"); self.end_headers()
      self.wfile.write(PAGE.encode()); return
    if self.path == "/do/airplay": sh("systemctl --user restart drapbox-uxplay.service"); return self._redir()
    if self.path == "/do/miracast": sh("systemctl --user restart drapbox-miracast.service"); return self._redir()
    if self.path == "/do/android_settings": sh("waydroid shell am start -a android.settings.SETTINGS"); return self._redir()
    if self.path == "/do/restart_waydroid": sh("systemctl restart waydroid-container.service"); return self._redir()
    if self.path == "/do/reboot": sh("systemctl reboot"); return self._redir()
    self.send_response(404); self.end_headers()

  def _redir(self):
    self.send_response(302); self.send_header("Location","/tv"); self.end_headers()

HTTPServer(("0.0.0.0", PORT), H).serve_forever()
EOF
chmod +x /usr/local/bin/drapbox-host-actions.py

cat >/etc/systemd/system/drapbox-host-actions.service <<'EOF'
[Unit]
Description=DrapBox Host Actions Dashboard
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/drapbox-host-actions.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
systemctl enable drapbox-host-actions.service

# --- First boot: network recovery + Waydroid ATV + HW decode + Play helper ---
cat >/usr/local/bin/drapbox-firstboot <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/lib/drapbox
STAMP="/var/lib/drapbox/firstboot.done"
[[ -f "$STAMP" ]] && exit 0

# Network recovery: configs might not carry over from live
if command -v nmcli >/dev/null 2>&1; then
  state="$(nmcli -t -f STATE g 2>/dev/null || true)"
  if [[ "$state" != "connected" ]]; then
    echo "[DrapBox] Network not connected. Opening nmtui on tty1…"
    command -v openvt >/dev/null 2>&1 && openvt -c 1 -- nmtui || true
  fi
fi

VARIANT="GAPPS"
[[ -f /var/lib/drapbox/waydroid_variant ]] && VARIANT="$(cat /var/lib/drapbox/waydroid_variant)"

echo "[DrapBox] Waydroid ATV init ($VARIANT)…"
waydroid init -f \
  -c https://ota.supechicken666.dev/system \
  -v https://ota.supechicken666.dev/vendor \
  -r lineage \
  -s "$VARIANT" || true

echo "[DrapBox] Waydroid upgrade…"
waydroid upgrade || true

# HW decode toggle
PROP="/var/lib/waydroid/waydroid_base.prop"
mkdir -p /var/lib/waydroid
touch "$PROP"
HW="ON"
[[ -f /var/lib/drapbox/hwaccel ]] && HW="$(cat /var/lib/drapbox/hwaccel)"
grep -v '^media\.sf\.hwaccel=' "$PROP" > "${PROP}.tmp" || true
mv "${PROP}.tmp" "$PROP"
if [[ "$HW" == "OFF" ]]; then echo "media.sf.hwaccel=0" >> "$PROP"; else echo "media.sf.hwaccel=1" >> "$PROP"; fi

systemctl restart waydroid-container.service || true

# VANILLA: auto setup complete
if [[ "$VARIANT" == "VANILLA" ]]; then
  waydroid shell -- sh -c '
    settings put global device_provisioned 1
    settings --user 0 put secure user_setup_complete 1
    settings --user 0 put secure tv_user_setup_complete 1
  ' || true
fi

# GAPPS: uncertified helper + QR (printed in console logs)
if [[ "$VARIANT" == "GAPPS" ]]; then
  ANDROID_ID="$(waydroid shell -- sh -c \
    "sqlite3 /data/data/*/*/gservices.db 'select value from main where name=\"android_id\";'" 2>/dev/null || true)"
  echo "Android ID: ${ANDROID_ID:-<not found>}"
  echo "Open: https://www.google.com/android/uncertified"
  command -v qrencode >/dev/null 2>&1 && qrencode -t UTF8 "https://www.google.com/android/uncertified" || true
  echo "Then restart Waydroid: sudo systemctl restart waydroid-container.service"
fi

# Best-effort open Host Actions in Android (if a browser exists)
waydroid shell am start -a android.intent.action.VIEW -d "http://127.0.0.1:9876/tv" >/dev/null 2>&1 || true

touch "$STAMP"
EOF
chmod +x /usr/local/bin/drapbox-firstboot

cat >/etc/systemd/system/drapbox-firstboot.service <<'EOF'
[Unit]
Description=DrapBox first boot (network + waydroid ATV)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/drapbox-firstboot

[Install]
WantedBy=multi-user.target
EOF
systemctl enable drapbox-firstboot.service

# Autologin + auto sway
if [[ "$AUTOLOGIN" == "yes" ]]; then
  install -d /etc/systemd/system/getty@tty1.service.d
  cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \$TERM
EOF
  if ! grep -q "DrapBox autostart sway" "$UHOME/.profile" 2>/dev/null; then
    cat >>"$UHOME/.profile" <<'EOF'

# DrapBox autostart sway
export GTK_THEME=Adwaita:dark
export GDK_BACKEND=wayland
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec sway
fi
EOF
    chown "$USERNAME:$USERNAME" "$UHOME/.profile"
  fi
fi
CHROOT

chmod +x "$MNT/root/drapbox-chroot.sh"
arch-chroot "$MNT" /root/drapbox-chroot.sh \
  "$HOSTNAME" "$USERNAME" "$USERPASS" "$ROOTPASS" "$TZ" "$LOCALE" "$KEYMAP" "$AUTOLOGIN" "$FS"

p 95 "Finalizing…"
umount -R "$MNT" || true
p 100 "Done."
sleep 1

zinfo "Install complete ✅

Bluetooth:
- Enabled (bluetooth.service)

Casting:
- AirPlay (always-on) name = hostname ($HOSTNAME)
- Miracast (always-on)
- Auto-switch: $AUTOSWITCH

Host Actions:
- http://localhost:9876/tv

Waydroid AndroidTV:
- $ATV_VARIANT
- HW decode: $HWACCEL

Rebooting now…"
reboot
