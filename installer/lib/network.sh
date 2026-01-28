#!/usr/bin/env bash
set -euo pipefail

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
        3)
          ui_info "Shell opened. Type 'exit' to return."
          bash || true
          ;;
        4) die "Aborted" ;;
        *) ;;
      esac
    fi
  done
}
