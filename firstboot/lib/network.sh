#!/usr/bin/env bash
set -euo pipefail

is_online(){
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W2 archlinux.org >/dev/null 2>&1
}

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
