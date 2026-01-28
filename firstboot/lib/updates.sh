#!/usr/bin/env bash
set -euo pipefail

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
    local user
    user="$(getent group wheel | awk -F: '{print $4}' | cut -d, -f1)"
    if [[ -n "$user" ]]; then
      su - "$user" -c "paru -Syu --noconfirm --skipreview" || true
    else
      paru -Syu --noconfirm --skipreview || true
    fi
  fi
}
