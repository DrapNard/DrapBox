#!/usr/bin/env bash
set -euo pipefail

FB_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$FB_DIR/lib/core.sh"
source "$FB_DIR/lib/input.sh"
source "$FB_DIR/lib/services.sh"
source "$FB_DIR/lib/network.sh"
source "$FB_DIR/lib/bluetooth.sh"
source "$FB_DIR/lib/status.sh"
source "$FB_DIR/lib/updates.sh"
source "$FB_DIR/lib/diagnostics.sh"
source "$FB_DIR/lib/menu.sh"

firstboot_entry "$@"
