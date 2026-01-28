#!/usr/bin/env bash
set -euo pipefail

APP="DrapBox FirstBoot"
STATE_DIR="/var/lib/drapbox"
DONE_FLAG="$STATE_DIR/firstboot.done"
LOG_DIR="/var/log/drapbox"
LOG_FILE="$LOG_DIR/firstboot.log"

TTY="${TTY:-/dev/tty}"

setup_logging(){
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

say(){ printf "%b\n" "$*" | tee /dev/fd/2; }
pause(){ printf "\nPress Enter..." >"$TTY"; IFS= read -r _ <"$TTY" || true; }
ask(){ local p="$1" d="${2:-}"; printf "%b" "$p" >"$TTY"; local a=""; IFS= read -r a <"$TTY" || true; [[ -n "$a" ]] && printf "%s" "$a" || printf "%s" "$d"; }
yn(){ local a; a="$(ask "$1 [y/N]: " "")"; [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; }
have(){ command -v "$1" >/dev/null 2>&1; }
