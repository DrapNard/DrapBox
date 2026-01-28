#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-/run/drapbox}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"

setup_logging(){
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "=== DrapBox installer log: $LOG_FILE ==="
  echo "Started: $(date -Is)"
  echo
}

setup_error_trap(){
  on_err() {
    local ec=$?
    echo
    echo "✗ ERROR: exit=$ec line=$LINENO"
    echo "✗ CMD: $BASH_COMMAND"
    echo "✗ LOG: $LOG_FILE"
    echo
    printf "\n✗ ERROR: exit=%s line=%s\n✗ CMD: %s\n✗ LOG: %s\n\n" \
      "$ec" "$LINENO" "$BASH_COMMAND" "$LOG_FILE" >"$TTY_DEV" 2>/dev/null || true
    exit "$ec"
  }
  trap on_err ERR
}
