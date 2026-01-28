#!/usr/bin/env bash
set -euo pipefail

pick_timezone() {
  local def="${1:-Europe/Paris}"
  local zoneinfo="/usr/share/zoneinfo"

  [[ -d "$zoneinfo" ]] || { echo "$def"; return 0; }

  local regions=()
  mapfile -t regions < <(
    find "$zoneinfo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    sed 's|.*/||' |
    grep -Ev '^(posix|right|Etc)$' |
    sort
  )

  ((${#regions[@]})) || { echo "$def"; return 0; }

  local region
  region="$(pick_from_list "Select timezone region" "${def%%/*}" "${regions[@]}")"
  [[ -n "$region" ]] || { echo "$def"; return 0; }

  local cities=()
  mapfile -t cities < <(
    find "$zoneinfo/$region" -type f 2>/dev/null |
    sed "s|$zoneinfo/$region/||" |
    sort
  )

  ((${#cities[@]})) || { echo "$region"; return 0; }

  local city
  city="$(pick_from_list "Select city ($region)" "${def#*/}" "${cities[@]}")"

  echo "$region/$city"
}
