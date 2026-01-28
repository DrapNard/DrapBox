#!/usr/bin/env bash
set -euo pipefail

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
