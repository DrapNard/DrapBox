#!/usr/bin/env bash
set -euo pipefail

no_input_detected(){
  if ls /dev/input/event* >/dev/null 2>&1; then
    for e in /dev/input/event*; do
      udevadm info -q property -n "$e" 2>/dev/null | grep -q '^ID_INPUT_KEYBOARD=1$' && return 1
    done
  fi
  ls /dev/input/by-id/*kbd* >/dev/null 2>&1 && return 1
  return 0
}
