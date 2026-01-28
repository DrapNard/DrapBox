#!/usr/bin/env bash
set -euo pipefail

pick_from_list() {
  local title="$1"; shift
  local def="$1"; shift
  local items=("$@")
  local chosen=""

  ((${#items[@]})) || { echo "$def"; return 0; }

  if (( GUM )); then
    chosen="$(gum_val choose --height 14 --header "$title" "${items[@]}")" || true
  else
    _tty_echo ""
    _tty_echo "== $title =="
    local i=0
    for it in "${items[@]}"; do
      i=$((i+1))
      printf "%2d) %s\n" "$i" "$it" >"$TTY_DEV"
    done
    local n
    n="$(_tty_readline "Select [1-$i] (default: $def): " "")"
    if [[ -z "$n" ]]; then
      chosen="$def"
    elif [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=i )); then
      chosen="${items[$((n-1))]}"
    else
      chosen="$def"
    fi
  fi

  [[ -n "$chosen" ]] && echo "$chosen" || echo "$def"
}

pick_locale() {
  local def="${1:-en_US.UTF-8}"
  local locales=()

  if [[ -r /usr/share/i18n/SUPPORTED ]]; then
    mapfile -t locales < <(
      awk '{print $1}' /usr/share/i18n/SUPPORTED 2>/dev/null |
      grep -E 'UTF-8$' |
      sort -u
    )
  fi

  if ((${#locales[@]}==0)); then
    locales=(en_US.UTF-8 fr_FR.UTF-8 de_DE.UTF-8 es_ES.UTF-8 it_IT.UTF-8)
  fi

  local common=(en_US.UTF-8 fr_FR.UTF-8 en_GB.UTF-8 de_DE.UTF-8 es_ES.UTF-8 it_IT.UTF-8 pt_BR.UTF-8)
  local merged=()
  for c in "${common[@]}"; do
    if printf '%s\n' "${locales[@]}" | grep -qx "$c"; then merged+=("$c"); fi
  done
  for l in "${locales[@]}"; do
    printf '%s\n' "${merged[@]}" | grep -qx "$l" || merged+=("$l")
  done

  pick_from_list "Select locale" "$def" "${merged[@]}"
}

pick_keymap() {
  local def="${1:-us}"
  local kms=()

  if command -v localectl >/dev/null 2>&1; then
    mapfile -t kms < <(localectl list-keymaps 2>/dev/null | sed '/^\s*$/d')
  fi

  if ((${#kms[@]}==0)) && [[ -d /usr/share/kbd/keymaps ]]; then
    mapfile -t kms < <(
      find /usr/share/kbd/keymaps -type f -name '*.map.gz' 2>/dev/null |
      sed -E 's|.*/||; s|\.map\.gz$||' |
      sort -u
    )
  fi

  if ((${#kms[@]}==0)); then
    kms=(us fr fr-latin1 uk de es it)
  fi

  pick_from_list "Select keyboard layout (keymap)" "$def" "${kms[@]}"
}
