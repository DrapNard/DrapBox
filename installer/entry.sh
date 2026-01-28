#!/usr/bin/env bash
set -euo pipefail

DRAPBOX_SRC="${DRAPBOX_SRC:-$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DRAPBOX_SRC

source "$DRAPBOX_SRC/installer/lib/core.sh"
source "$DRAPBOX_SRC/installer/lib/guards.sh"
source "$DRAPBOX_SRC/installer/lib/logging.sh"
source "$DRAPBOX_SRC/installer/lib/ui.sh"
source "$DRAPBOX_SRC/installer/lib/ramroot.sh"
source "$DRAPBOX_SRC/installer/lib/disk.sh"
source "$DRAPBOX_SRC/installer/lib/locale.sh"
source "$DRAPBOX_SRC/installer/lib/timezone.sh"
source "$DRAPBOX_SRC/installer/lib/network.sh"
source "$DRAPBOX_SRC/installer/lib/flow.sh"

drapbox_main "$@"
