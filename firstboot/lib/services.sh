#!/usr/bin/env bash
set -euo pipefail

ensure_services(){
  systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  systemctl enable --now iwd >/dev/null 2>&1 || true
  systemctl enable --now bluetooth >/dev/null 2>&1 || true
}
