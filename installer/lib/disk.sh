#!/usr/bin/env bash
set -euo pipefail

_unmount_disk_everything(){
  local disk="$1"
  local parts
  mapfile -t parts < <(lsblk -lnpo NAME "$disk" 2>/dev/null | tail -n +2 || true)
  for p in "${parts[@]}"; do
    local mps
    mapfile -t mps < <(lsblk -lnpo MOUNTPOINT "$p" 2>/dev/null | awk 'NF{print}')
    for mp in "${mps[@]}"; do umount -R "$mp" >/dev/null 2>&1 || true; done
    swapoff "$p" >/dev/null 2>&1 || true
  done
}

pick_disk(){
  while true; do
    ui_title "Disk selection"
    ui_info "Target disk will be WIPED."

    udevadm settle || true

    mapfile -t disks < <(
      lsblk -dn -o NAME,TYPE,SIZE,MODEL -P |
      awk '
        $0 ~ /TYPE="disk"/ {
          name=""; size=""; model=""
          for (i=1;i<=NF;i++){
            if ($i ~ /^NAME=/){ gsub(/NAME=|"/,"",$i); name=$i }
            if ($i ~ /^SIZE=/){ gsub(/SIZE=|"/,"",$i); size=$i }
            if ($i ~ /^MODEL=/){ gsub(/MODEL=|"/,"",$i); model=$i }
          }
          printf "/dev/%s  %s  %s\n", name, size, model
        }'
    )

    ((${#disks[@]})) || die "No disks found."

    local chosen_line=""
    if (( GUM )); then
      chosen_line="$(gum_val choose --height 12 --header "Select target disk" "${disks[@]}")" || true
    else
      _tty_echo ""
      local i=0
      for line in "${disks[@]}"; do
        i=$((i+1))
        printf "%2d) %s\n" "$i" "$line" >"$TTY_DEV"
      done
      local choice
      choice="$(_tty_readline "Select disk number [1-$i] (or 'r' refresh): " "")"
      [[ -z "$choice" ]] && continue
      [[ "${choice,,}" == "r" ]] && continue
      [[ "$choice" =~ ^[0-9]+$ ]] || continue
      (( choice>=1 && choice<=i )) || continue
      chosen_line="${disks[$((choice-1))]}"
    fi

    [[ -n "$chosen_line" ]] || {
      if (( GUM )); then
        ui_warn "No selection from gum; falling back to text mode."
        GUM=0
      fi
      continue
    }

    local d
    d="$(awk '{print $1}' <<<"$chosen_line")"
    if [[ ! -b "$d" ]]; then
      if (( GUM )); then
        ui_warn "Disk $d not found. Falling back to text mode."
        GUM=0
      fi
      continue
    fi

    ui_clear
    lsblk "$d" || true
    ui_yesno "Confirm WIPE target: $d ?" || continue
    echo "$d"
    return 0
  done
}
