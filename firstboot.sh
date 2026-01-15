#!/usr/bin/env bash
set -euo pipefail

# DrapBox Firstboot "mega" script
# - run-once wizard on first boot
# - overlay menu (AppleTV-like CLI for now)
# - helpers: internet, bluetooth remote, uxplay/miracast status, updates, diagnostics
# - auto bluetooth helper if no input devices detected

APP="DrapBox FirstBoot"
STATE_DIR="/var/lib/drapbox"
DONE_FLAG="$STATE_DIR/firstboot.done"
LOG_DIR="/var/log/drapbox"
mkdir -p "$STATE_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/firstboot.log"
exec > >(tee -a "$LOG_FILE") 2>&1

export TERM="${TERM:-linux}"
TTY="${TTY:-/dev/tty}"

say(){ printf "%b\n" "$*" | tee /dev/fd/2; }
pause(){ printf "\nPress Enter..." >"$TTY"; IFS= read -r _ <"$TTY" || true; }
ask(){ local p="$1" d="${2:-}"; printf "%b" "$p" >"$TTY"; local a=""; IFS= read -r a <"$TTY" || true; [[ -n "$a" ]] && printf "%s" "$a" || printf "%s" "$d"; }
yn(){ local a; a="$(ask "$1 [y/N]: " "")"; [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; }
have(){ command -v "$1" >/dev/null 2>&1; }

is_online(){
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W2 archlinux.org >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Input detection
# -----------------------------------------------------------------------------
no_input_detected(){
  # If ANY keyboard is detected, return 1 (NOT no-input)
  if ls /dev/input/event* >/dev/null 2>&1; then
    for e in /dev/input/event*; do
      udevadm info -q property -n "$e" 2>/dev/null | grep -q '^ID_INPUT_KEYBOARD=1$' && return 1
    done
  fi
  ls /dev/input/by-id/*kbd* >/dev/null 2>&1 && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Services baseline
# -----------------------------------------------------------------------------
ensure_services(){
  systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  systemctl enable --now iwd >/dev/null 2>&1 || true
  systemctl enable --now bluetooth >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Network helper
# -----------------------------------------------------------------------------
wifi_wizard(){
  have iwctl || { say "iwctl missing"; return 1; }

  local wlan ssid psk
  wlan="$(ls /sys/class/net | grep -E '^(wl|wlan)' | head -n1 || true)"
  [[ -n "$wlan" ]] || { say "No Wi-Fi interface detected."; return 1; }

  ssid="$(ask "SSID: " "")"
  [[ -n "$ssid" ]] || return 1
  psk="$(ask "Password (empty=open): " "")"

  iwctl device "$wlan" set-property Powered on >/dev/null 2>&1 || true
  iwctl station "$wlan" scan >/dev/null 2>&1 || true
  sleep 1
  if [[ -n "$psk" ]]; then
    iwctl --passphrase "$psk" station "$wlan" connect "$ssid" || return 1
  else
    iwctl station "$wlan" connect "$ssid" || return 1
  fi
  return 0
}

net_helper(){
  say "== $APP / Internet Helper =="
  ensure_services
  timedatectl set-ntp true >/dev/null 2>&1 || true

  if is_online; then
    say "✓ Internet already OK."
    return 0
  fi

  while ! is_online; do
    say ""
    say "No internet detected."
    say " 1) Retry (DHCP)"
    say " 2) Wi-Fi (iwctl)"
    say " 3) Shell"
    say " 4) Skip"
    local c; c="$(ask "Select [1-4]: " "1")"
    case "$c" in
      1) ;;
      2) wifi_wizard || say "Wi-Fi failed." ;;
      3) bash || true ;;
      4) return 0 ;;
      *) ;;
    esac
  done
  say "✓ Internet OK."
}

# -----------------------------------------------------------------------------
# Bluetooth helper (remote pairing)
# -----------------------------------------------------------------------------
bt_list(){
  bluetoothctl devices || true
  bluetoothctl paired-devices || true
}

bt_scan(){
  say "Scanning 10s..."
  bluetoothctl scan on >/dev/null 2>&1 || true
  sleep 10
  bluetoothctl scan off >/dev/null 2>&1 || true
}

bt_pair_connect(){
  local mac
  mac="$(ask "Enter device MAC (empty=cancel): " "")"
  [[ -n "$mac" ]] || return 1

  bluetoothctl power on >/dev/null 2>&1 || true
  bluetoothctl agent on >/dev/null 2>&1 || true
  bluetoothctl default-agent >/dev/null 2>&1 || true

  bluetoothctl pair "$mac" || true
  bluetoothctl trust "$mac" || true
  bluetoothctl connect "$mac" || true
  return 0
}

bt_helper(){
  say "== $APP / Bluetooth Remote Helper =="
  ensure_services
  have bluetoothctl || { say "bluetoothctl missing"; return 1; }

  bluetoothctl power on >/dev/null 2>&1 || true
  bluetoothctl agent on >/dev/null 2>&1 || true
  bluetoothctl default-agent >/dev/null 2>&1 || true

  bt_scan
  say ""
  say "Devices:"
  bt_list
  say ""
  bt_pair_connect || true
}

# -----------------------------------------------------------------------------
# UxPlay / Miracast / status
# -----------------------------------------------------------------------------
uxplay_status(){
  say "== UxPlay status =="
  systemctl status uxplay --no-pager || true
  pause
}

miracast_status(){
  say "== Miracast (gnome-network-displays) status =="
  systemctl status gnome-network-displays --no-pager || true
  pause
}

# -----------------------------------------------------------------------------
# Updates (pacman + paru if present)
# -----------------------------------------------------------------------------
updates_helper(){
  say "== $APP / Updates =="
  net_helper || true

  if ! is_online; then
    say "No internet, skipping updates."
    return 0
  fi

  say "Running pacman -Syu..."
  pacman -Syu --noconfirm || true

  if have paru; then
    say "Running paru -Syu..."
    # run as first wheel user if exists; else as root
    local user
    user="$(getent group wheel | awk -F: '{print $4}' | cut -d, -f1)"
    if [[ -n "$user" ]]; then
      su - "$user" -c "paru -Syu --noconfirm --skipreview" || true
    else
      paru -Syu --noconfirm --skipreview || true
    fi
  fi
}

# -----------------------------------------------------------------------------
# Diagnostics bundle (writes a snapshot file)
# -----------------------------------------------------------------------------
diag_helper(){
  local out="$LOG_DIR/diag-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "=== DrapBox diagnostics ==="
    date -Is
    echo
    echo "--- uname ---"; uname -a || true
    echo
    echo "--- lsblk ---"; lsblk || true
    echo
    echo "--- ip a ---"; ip a || true
    echo
    echo "--- rfkill ---"; rfkill list || true
    echo
    echo "--- systemctl failed ---"; systemctl --failed || true
    echo
    echo "--- journal (boot) ---"; journalctl -b --no-pager -n 300 || true
  } > "$out"
  say "Diagnostics written: $out"
  pause
}

# -----------------------------------------------------------------------------
# Overlay menu (AppleTV-like CLI version)
# -----------------------------------------------------------------------------
overlay_menu(){
  ensure_services
  while true; do
    clear || true
    echo "========== DrapBox Overlay =========="
    echo "1) Internet setup"
    echo "2) Bluetooth remote setup"
    echo "3) UxPlay status"
    echo "4) Miracast status"
    echo "5) Updates"
    echo "6) Diagnostics"
    echo "7) Exit"
    echo "===================================="
    local c
    c="$(ask "Select [1-7]: " "7")"
    case "$c" in
      1) net_helper; pause ;;
      2) bt_helper; pause ;;
      3) uxplay_status ;;
      4) miracast_status ;;
      5) updates_helper; pause ;;
      6) diag_helper ;;
      7) exit 0 ;;
      *) ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Firstboot main (run-once)
# -----------------------------------------------------------------------------
firstboot_main(){
  say "=== $APP starting ==="
  say "Log: $LOG_FILE"

  ensure_services

  # If no keyboard/input: push BT helper immediately
  if no_input_detected; then
    say "⚠ No input device detected -> launching Bluetooth helper."
    bt_helper || true
  fi

  # Always try network
  net_helper || true

  # optional guided steps
  yn "Configure a Bluetooth remote now?" && bt_helper || true
  yn "Run updates now?" && updates_helper || true

  # mark done
  date -Is > "$DONE_FLAG"
  say "✓ Firstboot complete."
}

# -----------------------------------------------------------------------------
# Entry
# -----------------------------------------------------------------------------
case "${1:-}" in
  --overlay)
    overlay_menu
    ;;
  *)
    [[ -f "$DONE_FLAG" ]] && exit 0
    firstboot_main
    ;;
esac
