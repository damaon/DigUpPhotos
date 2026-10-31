#!/bin/bash
# Installs DigUp for this user on Linux, from a build (scripts/build-llama.sh, scripts/build-onnx.sh, then
# `swift build -c release --product digup --static-swift-stdlib`): the program and ONNX Runtime in ~/.local/lib/digup, `digup` on PATH in
# ~/.local/bin, "DigUp" in the app menu (it opens DigUp in the browser), and a systemd user service that runs
# `digup serve` from login on, so new files are found while the page is closed.
#   packaging/linux/install.sh              install, or update
#   packaging/linux/install.sh --remove     take it all out again (the index and the model stay in ~/.local/share/DigUpPhotos)
set -euo pipefail
cd "$(dirname "$0")/../.."
LIB="$HOME/.local/lib/digup"
BIN="$HOME/.local/bin"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
has_systemd() { command -v systemctl > /dev/null && systemctl --user show-environment > /dev/null 2>&1; }

if [[ "${1:-}" == --remove ]]; then
  has_systemd && systemctl --user disable --now digup.service 2> /dev/null || true
  rm -rf "$LIB" "$BIN/digup" "$APPS/digup.desktop" "$ICONS/digup.png" "$UNITS/digup.service"
  has_systemd && systemctl --user daemon-reload || true
  echo "DigUp is gone (the index and the model are still in ${XDG_DATA_HOME:-$HOME/.local/share}/DigUpPhotos)"
  exit 0
fi

[[ -x .build/release/digup ]] || { echo "build it first: swift build -c release --product digup --static-swift-stdlib" >&2; exit 1; }
mkdir -p "$LIB" "$BIN" "$APPS" "$ICONS" "$UNITS"
cp .build/release/digup "$LIB/"
cp -P Vendor/onnxruntime/lib/libonnxruntime.so* "$LIB/"   # found next to the program ($ORIGIN)
ln -sf "$LIB/digup" "$BIN/digup"
cp docs/logo.png "$ICONS/digup.png"
sed "s|@DIGUP@|$LIB/digup|" packaging/linux/digup.desktop > "$APPS/digup.desktop"
sed "s|@DIGUP@|$LIB/digup|" packaging/linux/digup.service > "$UNITS/digup.service"
if has_systemd; then
  systemctl --user daemon-reload
  systemctl --user enable --now digup.service
  systemctl --user restart digup.service   # an update: the new program
  echo "DigUp runs in the background (systemctl --user status digup) at http://127.0.0.1:7811/"
else
  echo "No systemd user session: DigUp starts when you open it from the app menu."
fi
command -v update-desktop-database > /dev/null && update-desktop-database "$APPS" 2> /dev/null || true
echo "Installed. Open \"DigUp\" from the app menu, or run: digup serve --open"
