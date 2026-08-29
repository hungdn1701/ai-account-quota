#!/usr/bin/env bash
# Installs aiq into ~/.local/bin (override with PREFIX=/somewhere/bin).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/aiq.sh"
BIN="${PREFIX:-$HOME/.local/bin}"
DEST="$BIN/aiq"

[ -f "$SRC" ] || { echo "aiq.sh not found next to install.sh" >&2; exit 1; }

mkdir -p "$BIN"
cp -f "$SRC" "$DEST"
chmod +x "$DEST"
echo "installed: $DEST"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    echo
    echo "$BIN is not on your PATH. Add it:"
    case "${SHELL:-}" in
      */fish) echo "  fish_add_path $BIN" ;;
      */zsh)  echo "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc" ;;
      *)      echo "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bashrc" ;;
    esac
    ;;
esac

if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo
  echo "warning: no python3/python found — aiq needs one to read JSON." >&2
fi

echo
echo "Try:  aiq doctor"
