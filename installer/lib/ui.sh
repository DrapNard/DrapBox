#!/usr/bin/env bash
set -euo pipefail

GUM=0

pty_ok(){ [[ -c /dev/ptmx ]] && mountpoint -q /dev/pts; }

ui_init(){
  if command -v gum >/dev/null 2>&1 && pty_ok; then
    GUM=1
  else
    GUM=0
  fi
}

gum_ui(){ command gum "$@" </dev/tty >/dev/tty 2>/dev/tty; }

gum_val(){ command gum "$@" </dev/tty 2>/dev/tty; }

ui_clear(){ printf "\033c" >"$TTY_DEV" 2>/dev/null || true; }

ui_title(){
  local t="$1"
  if (( GUM )); then
    ui_clear
    gum_ui style --border double --padding "1 2" --margin "1 2" --bold "$APP" "$t" "Log: $LOG_FILE"
  else
    ui_clear
    _tty_echo "== $APP == $t"
    _tty_echo "Log: $LOG_FILE"
  fi
}

ui_info(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --faint "$msg"
  else _tty_echo "$msg"; fi
}

ui_warn(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --foreground 214 --bold "⚠ $msg"
  else _tty_echo "⚠ $msg"; fi
}

ui_ok(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --foreground 42 --bold "✓ $msg"
  else _tty_echo "✓ $msg"; fi
}

ui_err(){
  local msg="$1"
  if (( GUM )); then gum_ui style --margin "0 2" --foreground 196 --bold "✗ $msg"
  else _tty_echo "✗ $msg"; fi
}

ui_yesno(){
  local q="$1"
  if (( GUM )); then
    gum_ui confirm "$q"
  else
    local ans
    ans="$(_tty_readline "$q [y/N]: " "")"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  fi
}

ui_input(){
  local prompt="$1" def="${2:-}"
  if (( GUM )); then
    gum_val input --prompt "$prompt " --value "$def"
  else
    _tty_readline "$prompt [$def]: " "$def"
  fi
}

ui_pass(){
  local prompt="$1"
  if (( GUM )); then
    gum_val input --password --prompt "$prompt "
  else
    ui_warn "Password input is visible in pure CLI fallback."
    _tty_readline "$prompt: " ""
  fi
}

ui_spin(){
  local title="$1"; shift
  if (( GUM )); then
    gum_ui style --margin "0 2" --faint "⏳ $title"
    "$@"
  else
    ui_info "$title"
    "$@"
  fi
}
