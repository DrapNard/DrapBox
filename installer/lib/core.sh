#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-DrapBox Installer v0.6.3}"
MNT="${MNT:-/mnt}"
TTY_DEV="${TTY_DEV:-/dev/tty}"

export TERM="${TERM:-linux}"

say_err(){ echo "✗ $*" >&2; }

die(){ say_err "$*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

_tty_echo(){ printf "%b\n" "$*" >"$TTY_DEV"; }
_tty_readline(){
  local prompt="$1" default="${2:-}" ans=""
  printf "%b" "$prompt" >"$TTY_DEV"
  IFS= read -r ans <"$TTY_DEV" || true
  [[ -n "$ans" ]] && printf "%s" "$ans" || printf "%s" "$default"
}
