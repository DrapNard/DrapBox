#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${SCRIPT_DIR}/firstboot" ]]; then
  exec bash "${SCRIPT_DIR}/firstboot/entry.sh" "$@"
fi

if [[ -d "/usr/lib/drapbox/firstboot" ]]; then
  exec bash "/usr/lib/drapbox/firstboot/entry.sh" "$@"
fi

echo "✗ DrapBox firstboot modules not found." >&2
exit 1
