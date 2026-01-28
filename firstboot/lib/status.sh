#!/usr/bin/env bash
set -euo pipefail

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
