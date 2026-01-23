#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox Installer v0.6.3"
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
# Error trap (so crashes always show the failing command + line)
# =============================================================================
on_err() {
  local ec=$?
  echo
  echo "✗ ERROR: exit=$ec line=$LINENO"
  echo "✗ CMD: $BASH_COMMAND"
  echo "✗ LOG: $LOG_FILE"
  echo
  printf "\n✗ ERROR: exit=%s line=%s\n✗ CMD: %s\n✗ LOG: %s\n\n" \
    "$ec" "$LINENO" "$BASH_COMMAND" "$LOG_FILE" >"$TTY_DEV" 2>/dev/null || true
  exit "$ec"
}
trap on_err ERR

# =============================================================================
# Gum UI (fallback to plain if gum missing / PTY missing)
# =============================================================================
GUM=0
pty_ok(){ [[ -c /dev/ptmx ]] && mountpoint -q /dev/pts; }

if command -v gum >/dev/null 2>&1 && pty_ok; then
  GUM=1
fi

# IMPORTANT:
# - stdout+stderr are logged via tee.
# - gum TUI must NOT pollute logs.
# - commands must remain loggable -> NEVER run commands through gum.
gum_ui(){ command gum "$@" </dev/tty >/dev/tty 2>/dev/tty; }
gum_val(){ command gum "$@" </dev/tty 2>/dev/tty; }

ui_clear(){ printf "\033c" >"$TTY_DEV" 2>/dev/null || true; }

ui_title(){
  local t="$1"
  if (( GUM )); then
    ui_clear
    gum_ui style --border double --padding "1 2" --margin "1 2" --bold "$APP" "$t" "Log: $LOG_FILE"
  else
    ui_clear
    _tty_echo "== $APP == $t"
    _tty_echo "Log: $LOG_FILE"
  fi
}

ui_info(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --faint "$msg"
  else _tty_echo "$msg"; fi
}

ui_warn(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --foreground 214 --bold "⚠ $msg"
  else _tty_echo "⚠ $msg"; fi
}

ui_ok(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --foreground 42 --bold "✓ $msg"
  else _tty_echo "✓ $msg"; fi
}

ui_err(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --foreground 196 --bold "✗ $msg"
  else _tty_echo "✗ $msg"; fi
}

ui_yesno(){
  local q="$1"
  if (( GUM )); then
    gum_ui confirm "$q"
  else
    local ans
    ans="$(_tty_readline "$q [y/N]: " "")"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  fi
}

ui_input(){
  local prompt="$1" def="${2:-}"
  if (( GUM )); then
    gum_val input --prompt "$prompt " --value "$def"
  else
    _tty_readline "$prompt [$def]: " "$def"
  fi
}

ui_pass(){
  local prompt="$1"
  if (( GUM )); then
    gum_val input --password --prompt "$prompt "
  else
    ui_warn "Password input is visible in pure CLI fallback."
    _tty_readline "$prompt: " ""
  fi
}

# ---- NOTE: ui_spin prints UI via gum but runs command normally (logs stay intact) ----
ui_spin(){
  local title="$1"; shift
  if (( GUM )); then
    gum_ui style --margin "0 2" --faint "⏳ $title"
    "$@"
  else
    ui_info "$title"
    "$@"
  fi
}

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

  # --- IMPORTANT: rbind so /dev/pts + /dev/ptmx exist (gum needs PTY) ---
  for d in proc sys dev run tmp; do mkdir -p "/run/drapbox-ramroot/merged/$d"; done

  mount --rbind /proc /run/drapbox-ramroot/merged/proc
  mount --rbind /sys  /run/drapbox-ramroot/merged/sys
  mount --rbind /dev  /run/drapbox-ramroot/merged/dev
  mount --rbind /run  /run/drapbox-ramroot/merged/run
  mount --rbind /tmp  /run/drapbox-ramroot/merged/tmp

  mount --make-rslave /run/drapbox-ramroot/merged/proc || true
  mount --make-rslave /run/drapbox-ramroot/merged/sys  || true
  mount --make-rslave /run/drapbox-ramroot/merged/dev  || true
  mount --make-rslave /run/drapbox-ramroot/merged/run  || true
  mount --make-rslave /run/drapbox-ramroot/merged/tmp  || true

  # Belt & suspenders: devpts + shm inside merged root
  mkdir -p /run/drapbox-ramroot/merged/dev/pts /run/drapbox-ramroot/merged/dev/shm
  mountpoint -q /run/drapbox-ramroot/merged/dev/pts || \
    mount -t devpts devpts /run/drapbox-ramroot/merged/dev/pts -o gid=5,mode=620
  mountpoint -q /run/drapbox-ramroot/merged/dev/shm || \
    mount -t tmpfs shm /run/drapbox-ramroot/merged/dev/shm -o mode=1777,nosuid,nodev

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
    ui_warn "airootfs low (${free_mb}MB free). FORCING RAM-root overlay (${want_mb}MB)."
    enter_ramroot_overlay "$want_mb"
  fi
}

fix_system_after_overlay() {
  [[ "${IN_RAMROOT:-0}" == "1" ]] || return 0
  ui_info "• [ramroot] Fixing system state after overlay…"

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

  ui_ok "• [ramroot] Done."
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
    for mp in "${mps[@]}"; do umount -R "$mp" >/dev/null 2>&1 || true; done
    swapoff "$p" >/dev/null 2>&1 || true
  done
}

pick_disk(){
  while true; do
    ui_title "Disk selection"
    ui_info "Target disk will be WIPED."

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
          printf "/dev/%s  %s  %s\n", name, size, model
        }'
    )

    ((${#disks[@]})) || die "No disks found."

    local chosen_line=""
    if (( GUM )); then
      chosen_line="$(gum_val choose --height 12 --header "Select target disk" "${disks[@]}")" || true
    else
      _tty_echo ""
      local i=0
      for line in "${disks[@]}"; do
        i=$((i+1))
        printf "%2d) %s\n" "$i" "$line" >"$TTY_DEV"
      done
      local choice
      choice="$(_tty_readline "Select disk number [1-$i] (or 'r' refresh): " "")"
      [[ -z "$choice" ]] && continue
      [[ "${choice,,}" == "r" ]] && continue
      [[ "$choice" =~ ^[0-9]+$ ]] || continue
      (( choice>=1 && choice<=i )) || continue
      chosen_line="${disks[$((choice-1))]}"
    fi

    [[ -n "$chosen_line" ]] || continue

    local d
    d="$(awk '{print $1}' <<<"$chosen_line")"
    [[ -b "$d" ]] || continue

    ui_clear
    lsblk "$d" || true
    ui_yesno "Confirm WIPE target: $d ?" || continue
    echo "$d"
    return 0
  done
}

# =============================================================================
# Locale + keymap pickers
# =============================================================================

pick_from_list() {
  # usage: pick_from_list "Title" default "item1" "item2" ...
  local title="$1"; shift
  local def="$1"; shift
  local items=("$@")
  local chosen=""

  ((${#items[@]})) || { echo "$def"; return 0; }

  if (( GUM )); then
    chosen="$(gum_val choose --height 14 --header "$title" "${items[@]}")" || true
  else
    _tty_echo ""
    _tty_echo "== $title =="
    local i=0
    for it in "${items[@]}"; do
      i=$((i+1))
      printf "%2d) %s\n" "$i" "$it" >"$TTY_DEV"
    done
    local n
    n="$(_tty_readline "Select [1-$i] (default: $def): " "")"
    if [[ -z "$n" ]]; then
      chosen="$def"
    elif [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=i )); then
      chosen="${items[$((n-1))]}"
    else
      chosen="$def"
    fi
  fi

  [[ -n "$chosen" ]] && echo "$chosen" || echo "$def"
}

pick_locale() {
  local def="${1:-en_US.UTF-8}"
  local locales=()

  # Best source on Arch: /usr/share/i18n/SUPPORTED contains full locale names
  if [[ -r /usr/share/i18n/SUPPORTED ]]; then
    mapfile -t locales < <(
      awk '{print $1}' /usr/share/i18n/SUPPORTED 2>/dev/null |
      grep -E 'UTF-8$' |
      sort -u
    )
  fi

  # Fallback if file missing
  if ((${#locales[@]}==0)); then
    locales=(en_US.UTF-8 fr_FR.UTF-8 de_DE.UTF-8 es_ES.UTF-8 it_IT.UTF-8)
  fi

  # Keep list reasonable: prioritize common ones first (optional)
  local common=(en_US.UTF-8 fr_FR.UTF-8 en_GB.UTF-8 de_DE.UTF-8 es_ES.UTF-8 it_IT.UTF-8 pt_BR.UTF-8)
  local merged=()
  for c in "${common[@]}"; do
    if printf '%s\n' "${locales[@]}" | grep -qx "$c"; then merged+=("$c"); fi
  done
  for l in "${locales[@]}"; do
    # avoid duplicates
    printf '%s\n' "${merged[@]}" | grep -qx "$l" || merged+=("$l")
  done

  pick_from_list "Select locale" "$def" "${merged[@]}"
}

pick_keymap() {
  local def="${1:-us}"
  local kms=()

  if command -v localectl >/dev/null 2>&1; then
    mapfile -t kms < <(localectl list-keymaps 2>/dev/null | sed '/^\s*$/d')
  fi

  if ((${#kms[@]}==0)) && [[ -d /usr/share/kbd/keymaps ]]; then
    mapfile -t kms < <(
      find /usr/share/kbd/keymaps -type f -name '*.map.gz' 2>/dev/null |
      sed -E 's|.*/||; s|\.map\.gz$||' |
      sort -u
    )
  fi

  if ((${#kms[@]}==0)); then
    kms=(us fr fr-latin1 uk de es it)
  fi

  pick_from_list "Select keyboard layout (keymap)" "$def" "${kms[@]}"
}

# =============================================================================
# Timezone picker
# =============================================================================

pick_timezone() {
  local def="${1:-Europe/Paris}"
  local zoneinfo="/usr/share/zoneinfo"

  [[ -d "$zoneinfo" ]] || { echo "$def"; return 0; }

  # List regions (continents)
  local regions=()
  mapfile -t regions < <(
    find "$zoneinfo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    sed 's|.*/||' |
    grep -Ev '^(posix|right|Etc)$' |
    sort
  )

  ((${#regions[@]})) || { echo "$def"; return 0; }

  local region
  region="$(pick_from_list "Select timezone region" "${def%%/*}" "${regions[@]}")"
  [[ -n "$region" ]] || { echo "$def"; return 0; }

  # List cities inside region
  local cities=()
  mapfile -t cities < <(
    find "$zoneinfo/$region" -type f 2>/dev/null |
    sed "s|$zoneinfo/$region/||" |
    sort
  )

  ((${#cities[@]})) || { echo "$region"; return 0; }

  local city
  city="$(pick_from_list "Select city ($region)" "${def#*/}" "${cities[@]}")"

  echo "$region/$city"
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
    ui_title "Network"
    ui_warn "No internet detected."

    if (( GUM )); then
      local act
      act="$(gum_val choose --height 8 --header "Choose action" \
        "Retry" \
        "Wi-Fi (iwctl)" \
        "Shell" \
        "Abort"
      )" || true

      case "$act" in
        "Retry") ;;
        "Wi-Fi (iwctl)")
          need iwctl || die "iwctl missing"
          local wlan ssid psk
          wlan="$(ls /sys/class/net 2>/dev/null | grep -E '^(wl|wlan)' | head -n1 || true)"
          [[ -n "$wlan" ]] || { ui_err "No Wi-Fi interface detected."; sleep 1; continue; }
          ssid="$(ui_input "SSID for $wlan:" "")"
          [[ -n "$ssid" ]] || continue
          psk="$(ui_pass "Password (empty=open):")"
          iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
          iwctl station "$wlan" scan >/dev/null 2>&1 || true
          sleep 1
          if [[ -n "$psk" ]]; then
            iwctl --passphrase "$psk" station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
          else
            iwctl station "$wlan" connect "$ssid" >/dev/null 2>&1 || true
          fi
          ;;
        "Shell")
          ui_info "Shell opened. Type 'exit' to return."
          bash || true
          ;;
        "Abort") die "Aborted" ;;
        *) ;;
      esac
    else
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
          [[ -n "$wlan" ]] || { ui_err "No Wi-Fi interface detected."; sleep 1; continue; }
          ssid="$(ui_input "SSID for $wlan:" "")"
          [[ -n "$ssid" ]] || continue
          psk="$(ui_pass "Password (empty=open):")"
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
        *) ;;
      esac
    fi
  done
}

# =============================================================================
# MAIN
# =============================================================================
ui_title "Bootstrap"
maybe_use_ramroot
fix_system_after_overlay

# Keyring baseline (don’t hide errors: logs matter)
ui_spin "Refreshing keyring (live)..." pacman -Sy --noconfirm --needed archlinux-keyring
pacman-key --populate archlinux >/dev/null 2>&1 || true

# Live deps (+ gum)
ui_spin "Installing live dependencies (incl. gum)..." pacman -Sy --noconfirm --needed \
  iwd networkmanager \
  gptfdisk util-linux dosfstools e2fsprogs btrfs-progs \
  arch-install-scripts \
  curl git jq \
  gum

# enable gum UI after install (only if PTY works)
if command -v gum >/dev/null 2>&1 && pty_ok; then GUM=1; else GUM=0; fi

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

# ---- Partition / format ----
ui_title "Partitioning"
ui_spin "Umount disk" _unmount_disk_everything "$DISK"

ui_spin "Wiping signatures..." wipefs -af "$DISK"

ui_spin "Creating GPT..." sgdisk --zap-all "$DISK"
sgdisk -o "$DISK"
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0      -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK" || true
udevadm settle || true

# Wait for partitions to appear (VMs can lag)
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

# ---- Pacstrap base ----
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

# Swapfile
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

# ---- Fetch firstboot ----
ui_title "Firstboot"
FIRSTBOOT_URL="${FIRSTBOOT_URL:-https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/firstboot.sh}"
mkdir -p "$MNT/usr/lib/drapbox"
ui_spin "Downloading firstboot.sh..." curl -fsSL "$FIRSTBOOT_URL" -o "$MNT/usr/lib/drapbox/firstboot.sh"
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
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
EOF

# ---- Chroot config ----
ui_title "Chroot configuration"
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

# --- PGP / keyring recovery ---
echo "[chroot] fixing pacman keyring (PGP)..."
timedatectl set-ntp true >/dev/null 2>&1 || true
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
rm -f /var/cache/pacman/pkg/archlinux-keyring-*.pkg.tar.* 2>/dev/null || true
pacman -Syy --noconfirm
pacman -S --noconfirm --needed archlinux-keyring
pacman -Syu --noconfirm

# --- Font defaults: JetBrainsMono Nerd Font ---
mkdir -p /etc/fonts/conf.d
cat >/etc/fonts/local.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>JetBrainsMono Nerd Font</family>
      <family>JetBrains Mono</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>JetBrainsMono Nerd Font</family>
      <family>JetBrains Mono</family>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>JetBrainsMono Nerd Font</family>
      <family>JetBrains Mono</family>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>
</fontconfig>
EOF

mkdir -p /etc/xdg/foot
if [[ ! -f /etc/xdg/foot/foot.ini ]]; then
  cat >/etc/xdg/foot/foot.ini <<'EOF'
[main]
font=JetBrainsMono Nerd Font:size=12
EOF
else
  if grep -q '^[[:space:]]*font=' /etc/xdg/foot/foot.ini; then
    sed -i 's|^[[:space:]]*font=.*|font=JetBrainsMono Nerd Font:size=12|' /etc/xdg/foot/foot.ini
  else
    printf "\n[main]\nfont=JetBrainsMono Nerd Font:size=12\n" >> /etc/xdg/foot/foot.ini
  fi
fi

# Try install yay from repo first
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
ui_spin "Running arch-chroot config..." arch-chroot "$MNT" /root/drapbox-chroot.sh \
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
