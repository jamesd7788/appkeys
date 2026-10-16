#!/usr/bin/env bash
# Undo install.sh. Asks first (--yes to skip). Leaves ~/.config/appkeys/keys.tsv
# in place; delete it yourself if you want your key table gone too.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ID="io.github.jamesd7788.appkeys"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BINDINGS="$HOME/.config/hypr/bindings.lua"
KEYD_CONF=/etc/keyd/default.conf
YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

say() { printf '\033[1;36m›\033[0m %s\n' "$*"; }

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  while IFS='=' read -r k v; do
    case "$k" in HYPRLAND_INSTANCE_SIGNATURE|WAYLAND_DISPLAY|XDG_RUNTIME_DIR) export "$k=$v";; esac
  done < <(systemctl --user show-environment 2>/dev/null)
fi

keyd_revert=0
[[ -f "$KEYD_CONF" ]] && grep -q '^\[hyper:G\]' "$KEYD_CONF" && keyd_revert=1

if (( ! YES )); then
  echo "appkeys uninstall will:"
  echo "  - remove the appkeys block from $BINDINGS (backup first)"
  echo "  - remove the ~/.local/bin/appkeys and ~/.config/hypr/appkeys.lua links"
  (( keyd_revert )) && echo "  - set caps in $KEYD_CONF back to [hyper:C-A-M-S] (backup first, as root)"
  [[ -L "$PLUGIN_DIR" ]] && echo "  - remove the $PLUGIN_DIR link"
  read -r -p "continue? [y/N] " ok
  [[ "$ok" == [yY]* ]] || { echo "nothing changed"; exit 1; }
fi

if [[ -f "$BINDINGS" ]] && grep -q '^-- >>> appkeys >>>' "$BINDINGS"; then
  say "removing the appkeys block from bindings.lua"
  cp "$BINDINGS" "$BINDINGS.bak.appkeys.$(date +%s)"
  sed -i '/^-- >>> appkeys >>>/,/^-- <<< appkeys <<</d' "$BINDINGS"
fi

for link in "$HOME/.local/bin/appkeys" "$HOME/.config/hypr/appkeys.lua"; do
  [[ -L "$link" ]] && rm -f "$link"
done

if (( keyd_revert )); then
  say "keyd: caps held -> Ctrl+Alt+Super+Shift again (needs root)"
  sudo cp "$KEYD_CONF" "$KEYD_CONF.bak.appkeys.$(date +%s)"
  sudo sed -i 's/^\[hyper:G\]/[hyper:C-A-M-S]/' "$KEYD_CONF"
  sudo keyd reload
fi

if command -v omarchy >/dev/null; then
  omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
fi
if [[ -L "$PLUGIN_DIR" ]]; then
  rm -f "$PLUGIN_DIR"
elif [[ -d "$PLUGIN_DIR" ]]; then
  echo "  the plugin checkout stays until you run: omarchy plugin remove $PLUGIN_ID"
fi

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null
fi
say "done. kb_options gets lv3:ralt_switch only from the appkeys module, so it's gone too."
echo "  re-enable numbered workspaces with: omarchy plugin enable omarchy.workspaces"
