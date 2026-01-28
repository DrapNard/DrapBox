#!/usr/bin/env bash
set -euo pipefail

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

firstboot_main(){
  say "=== $APP starting ==="
  say "Log: $LOG_FILE"

  ensure_services

  if no_input_detected; then
    say "⚠ No input device detected -> launching Bluetooth helper."
    bt_helper || true
  fi

  net_helper || true

  yn "Configure a Bluetooth remote now?" && bt_helper || true
  yn "Run updates now?" && updates_helper || true

  date -Is > "$DONE_FLAG"
  say "✓ Firstboot complete."
}

firstboot_entry(){
  setup_logging

  case "${1:-}" in
    --overlay)
      overlay_menu
      ;;
    --firstboot|"")
      [[ -f "$DONE_FLAG" ]] && exit 0
      firstboot_main
      ;;
    *)
      overlay_menu
      ;;
  esac
}
