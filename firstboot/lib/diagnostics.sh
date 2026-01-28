#!/usr/bin/env bash
set -euo pipefail

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
