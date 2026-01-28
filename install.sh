#!/usr/bin/env bash
set -euo pipefail

# DrapBox installer entrypoint.
# - If running from a repo checkout, exec the modular installer.
# - If running via curl, fetch the repo and exec from there.

DRAPBOX_REPO="${DRAPBOX_REPO:-DrapNard/DrapBox}"
DRAPBOX_REF="${DRAPBOX_REF:-refs/heads/main}"
DRAPBOX_TARBALL_URL="${DRAPBOX_TARBALL_URL:-https://codeload.github.com/${DRAPBOX_REPO}/tar.gz/${DRAPBOX_REF}}"

if [[ -n "${DRAPBOX_SRC:-}" && -d "${DRAPBOX_SRC}/installer" ]]; then
  exec bash "${DRAPBOX_SRC}/installer/entry.sh" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/installer" ]]; then
  export DRAPBOX_SRC="$SCRIPT_DIR"
  exec bash "${SCRIPT_DIR}/installer/entry.sh" "$@"
fi

WORKDIR="/run/drapbox/src"
mkdir -p "$WORKDIR"

TARBALL="$WORKDIR/drapbox.tar.gz"
rm -f "$TARBALL"

curl -fsSL "$DRAPBOX_TARBALL_URL" -o "$TARBALL"
rm -rf "$WORKDIR/repo"
mkdir -p "$WORKDIR/repo"

tar -xzf "$TARBALL" -C "$WORKDIR/repo" --strip-components=1
export DRAPBOX_SRC="$WORKDIR/repo"

exec bash "$DRAPBOX_SRC/installer/entry.sh" "$@"
