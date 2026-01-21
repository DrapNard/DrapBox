#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v0.6.2"
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
# gum UI (TTY-safe) — does NOT change logic, only wraps display/prompts
# =============================================================================
ensure_gum(){
  if command -v gum >/dev/null 2>&1; then return 0; fi
  # Install gum on the live environment (for UI)
  pacman -Sy --noconfirm --needed gum >/dev/null 2>&1 || true
  command -v gum >/dev/null 2>&1 || die "gum couldn't be installed (no repo / no net)."
}

ui_clear(){ clear >"$TTY_DEV" 2>/dev/null || true; }
ui_banner(){
  ui_clear
  gum style --border normal --margin "1 2" --padding "1 2" \
    --bold -- "🐾 DrapBox Installer" "Log: $LOG_FILE"
}
ui_note(){
  local msg="$1"
  gum style --margin "0 2" --padding "0 1" -- "$msg"
}
ui_warn(){
  local msg="$1"
  gum style --border normal --margin "0 2" --padding "0 1" --bold -- "⚠ $msg"
}
ui_fail(){
  local msg="$1"
  gum style --border normal --margin "0 2" --padding "0 1" --bold -- "✗ $msg"
}
ui_ok(){
  local msg="$1"
  gum style --border normal --margin "0 2" --padding "0 1" --bold -- "✓ $msg"
}

run_spin(){
  local title="$1"; shift
  # gum spin shows a nice spinner until the command ends
  gum spin --spinner dot --title "$title" -- bash -lc "$*"
}

ui_input_gum(){
  local prompt="$1" def="${2:-}"
  gum input --prompt "$prompt " --value "$def"
}
ui_pass_gum(){
  local prompt="$1"
  gum input --password --prompt "$prompt "
}
ui_confirm(){
  local prompt="$1"
  gum confirm "$prompt"
}
ui_choose(){
  local prompt="$1"; shift
  gum choose --header "$prompt" "$@"
}

# =============================================================================
# Disk picker (logic identical, nicer output)
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
    ui_banner
    ui_note "Select the target disk. **It will be wiped**."

    # Build list: "dev | size | model"
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
          printf "/dev/%s | %s | %s\n", name, size, model
        }'
    )

    ((${#disks[@]})) || die "No disks found."

    # gum choose returns the selected string
    local sel
    sel="$(ui_choose "Disks:" "${disks[@]}")" || true
    [[ -n "${sel:-}" ]] || continue

    local d
    d="$(awk -F'|' '{gsub(/[[:space:]]+/,"",$1); print $1}' <<<"$sel")"
    [[ -b "$d" ]] || { ui_warn "Selected $d is not a block device."; sleep 1; continue; }

    ui_clear
    gum style --margin "1 2" --bold -- "Selected: $sel"
    lsblk "$d" || true

    if ui_confirm "Confirm WIPE target: $d ?"; then
      echo "$d"
      return 0
    fi
  done
}

# =============================================================================
# Network (logic unchanged)
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
    ui_banner
    ui_warn "No internet detected."
    local c
    c="$(ui_choose "Choose:" "Retry" "Wi-Fi (iwctl)" "Shell" "Abort")" || true
    case "${c:-}" in
      "Retry") ;;
      "Wi-Fi (iwctl)")
        need iwctl || die "iwctl missing"
        local wlan ssid psk
        wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
        [[ -n "$wlan" ]] || { ui_warn "No Wi-Fi interface detected."; sleep 1; continue; }
        ssid="$(ui_input_gum "SSID for $wlan:" "")" || true
        [[ -n "${ssid:-}" ]] || continue
        psk="$(ui_pass_gum "Password (empty=open):")" || true
        iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
        iwctl station "$wlan" scan >/dev/null 2>&1 || true
        sleep 1
        if [[ -n "${psk:-}" ]]; then
          iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
        else
          iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
        fi
        ;;
      "Shell")
        ui_clear
        ui_note "Shell opened. Type 'exit' to return."
        bash || true
        ;;
      "Abort"|*) die "Aborted" ;;
    esac
  done
}

# =============================================================================
# MAIN (same logic, only UI changes + gum in packages)
# =============================================================================
maybe_use_ramroot
fix_system_after_overlay

# Keyring baseline (idempotent)
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# Live deps (+ gum)
run_spin "Installing live dependencies…" \
  "pacman -Sy --noconfirm --needed \
    iwd networkmanager gum \
    gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
    arch-install-scripts \
    curl git jq \
   >/dev/null"

ensure_gum

ui_banner
ui_note "This will install DrapBox on a target disk."
ui_note "Step 1: Internet check."
run_spin "Checking network…" "true"
ensure_network
ui_ok "Internet OK"

DISK="$(pick_disk)" || die "No disk selected"

HOSTNAME="$(ui_input_gum "Hostname (also AirPlay name):" "drapbox")"
USERNAME="$(ui_input_gum "Admin user (sudo):" "drapnard")"
USERPASS="$(ui_pass_gum "Password for user '$USERNAME':")"
ROOTPASS="$(ui_pass_gum "Password for root:")"

TZ="$(ui_input_gum "Timezone (e.g. Europe/Paris):" "Europe/Paris")"
LOCALE="$(ui_input_gum "Locale (e.g. en_US.UTF-8, fr_FR.UTF-8):" "en_US.UTF-8")"
KEYMAP="$(ui_input_gum "Keymap (e.g. us, fr, de):" "us")"

FS="$(ui_choose "Root filesystem:" "ext4" "btrfs")"
SWAP_G="$(ui_input_gum "Swapfile size GiB (0=none):" "0")"
[[ "$SWAP_G" =~ ^[0-9]+$ ]] || die "Invalid swap size: $SWAP_G"

AUTO_REBOOT="yes"
if ui_confirm "Auto reboot after install?"; then AUTO_REBOOT="yes"; else AUTO_REBOOT="no"; fi

ui_banner
gum style --margin "1 2" --border normal --padding "1 2" --bold -- \
"SUMMARY" \
"Disk:      $DISK" \
"FS:        $FS" \
"Swap:      ${SWAP_G}GiB" \
"TZ:        $TZ" \
"Locale:    $LOCALE" \
"Keymap:    $KEYMAP" \
"Hostname:  $HOSTNAME" \
"User:      $USERNAME" \
"Log:       $LOG_FILE"

ui_confirm "Proceed (WIPE + INSTALL)?" || die "Aborted"

# ---- Partition / format ----
ui_banner
run_spin "Partitioning + formatting…" \
  "umount -R '$MNT' >/dev/null 2>&1 || true; \
   swapoff -a >/dev/null 2>&1 || true; \
   true"

_unmount_disk_everything "$DISK"
wipefs -af "$DISK" >/dev/null 2>&1 || true

run_spin "Creating GPT + partitions…" \
  "sgdisk --zap-all '$DISK'; \
   sgdisk -o '$DISK'; \
   sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:'EFI' '$DISK'; \
   sgdisk -n 2:0:0      -t 2:8300 -c 2:'ROOT' '$DISK'; \
   partprobe '$DISK' || true; \
   udevadm settle || true; \
   sleep 1"

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
fi

umount -R "$EFI_PART" >/dev/null 2>&1 || true
umount -R "$ROOT_PART" >/dev/null 2>&1 || true

run_spin "Formatting EFI (FAT32)…" "mkfs.fat -F32 -n EFI '$EFI_PART'"
if [[ "$FS" == "ext4" ]]; then
  run_spin "Formatting ROOT (ext4)…" "mkfs.ext4 -F -L ROOT '$ROOT_PART'"
else
  run_spin "Formatting ROOT (btrfs)…" "mkfs.btrfs -f -L ROOT '$ROOT_PART'"
fi

run_spin "Mounting target…" \
  "mount '$ROOT_PART' '$MNT'; \
   mkdir -p '$MNT/boot'; \
   mount '$EFI_PART' '$MNT/boot'"

if [[ "$FS" == "btrfs" ]]; then
  run_spin "Creating btrfs subvolumes…" \
    "btrfs subvolume create '$MNT/@'; \
     btrfs subvolume create '$MNT/@home'; \
     umount '$MNT'; \
     mount -o subvol=@ '$ROOT_PART' '$MNT'; \
     mkdir -p '$MNT/home' '$MNT/boot'; \
     mount -o subvol=@home '$ROOT_PART' '$MNT/home'; \
     mount '$EFI_PART' '$MNT/boot'"
fi

# ---- Pacstrap base ----
ui_banner
ui_note "Installing base system (repo packages)…"

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

run_spin "pacstrap (this can take a while)..." \
  "pacstrap -K '$MNT' ${BASE_PKGS[*]}"

run_spin "Generating fstab…" "genfstab -U '$MNT' > '$MNT/etc/fstab'"

# Swapfile
if [[ "$SWAP_G" != "0" ]]; then
  ui_note "Configuring swapfile (${SWAP_G}GiB)…"
  if [[ "$FS" == "ext4" ]]; then
    run_spin "Creating swapfile…" \
      "fallocate -l '${SWAP_G}G' '$MNT/swapfile'; \
       chmod 600 '$MNT/swapfile'; \
       mkswap '$MNT/swapfile'; \
       echo '/swapfile none swap defaults 0 0' >> '$MNT/etc/fstab'"
  else
    run_spin "Creating swapfile…" \
      "mkdir -p '$MNT/swap'; \
       chattr +C '$MNT/swap' || true; \
       fallocate -l '${SWAP_G}G' '$MNT/swap/swapfile'; \
       chmod 600 '$MNT/swap/swapfile'; \
       mkswap '$MNT/swap/swapfile'; \
       echo '/swap/swapfile none swap defaults 0 0' >> '$MNT/etc/fstab'"
  fi
fi

# ---- Fetch firstboot now so it's embedded ----
FIRSTBOOT_URL="${FIRSTBOOT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/firstboot.sh}"
mkdir -p "$MNT/usr/lib/drapbox"
run_spin "Fetching firstboot.sh…" \
  "curl -fsSL '$FIRSTBOOT_URL' -o '$MNT/usr/lib/drapbox/firstboot.sh'; \
   chmod 0755 '$MNT/usr/lib/drapbox/firstboot.sh'"

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

# ---- Chroot config (unchanged logic) ----
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
ui_banner
run_spin "Configuring installed system (chroot)..." \
  "arch-chroot '$MNT' /root/drapbox-chroot.sh '$HOSTNAME' '$USERNAME' '$USERPASS' '$ROOTPASS' '$TZ' '$LOCALE' '$KEYMAP' '$FS'"

ui_banner
ui_ok "Install complete."
ui_note "Log file: $LOG_FILE"
ui_note "After reboot, **firstboot** will start automatically (network / bluetooth helpers)."

umount -R "$MNT" >/dev/null 2>&1 || true

if [[ "${AUTO_REBOOT:-yes}" == "yes" ]]; then
  ui_note "Rebooting now…"
  sleep 2
  reboot
else
  ui_warn "Auto-reboot disabled."
  ui_note "You can reboot manually. Log: $LOG_FILE"
  bash
fi
