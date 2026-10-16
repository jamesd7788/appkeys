#!/usr/bin/env bash
# Install or update appkeys for the current user. Safe to re-run -- and re-run
# it after `omarchy refresh hyprland` or anything else that rewrites
# ~/.config/hypr/bindings.lua or /etc/keyd.
#
#   ./install.sh            everything; shows what it will change and asks first
#   ./install.sh --yes      don't ask
#   ./install.sh --no-keyd  leave /etc/keyd alone (set caps up yourself, see README)
#
# Works from an `omarchy plugin add` checkout (~/.config/omarchy/plugins/<id>)
# or any other clone, which it links into the plugins folder.
#
# What it does:
#   1. `appkeys` on PATH (symlink into this checkout)
#   2. ~/.config/hypr/appkeys.lua -> this checkout, required from bindings.lua
#      inside a marked block (pcall'd: a broken module can't take Hyprland down)
#   3. ~/.config/appkeys/keys.tsv seeded from keys.default.tsv if missing
#   4. keyd: caps held = AltGr instead of Ctrl+Alt+Super+Shift ([hyper:G]),
#      after backing up the file (asks for your password)
#   5. the bar widget plugin, discoverable by omarchy-shell (not enabled)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ID="io.github.jamesd7788.appkeys"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BINDINGS="$HOME/.config/hypr/bindings.lua"
KEYD_CONF=/etc/keyd/default.conf
KEYD=1
YES=0
for arg in "$@"; do
  case "$arg" in
    --no-keyd) KEYD=0 ;;
    --yes|-y) YES=1 ;;
    *) echo "usage: $0 [--yes] [--no-keyd]"; exit 2 ;;
  esac
done

say() { printf '\033[1;36m›\033[0m %s\n' "$*"; }

# Run from outside the session (e.g. over ssh): find the running Hyprland.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  sig="$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)"
  [[ -n "$sig" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

keyd_state=skip
if (( KEYD )); then
  if [[ ! -f "$KEYD_CONF" ]]; then keyd_state=missing
  elif grep -q '^\[hyper:G\]' "$KEYD_CONF"; then keyd_state=done
  elif grep -q '^\[hyper:C-A-M-S\]' "$KEYD_CONF"; then keyd_state=change
  else keyd_state=unknown
  fi
fi

if (( ! YES )); then
  echo "appkeys will:"
  echo "  - link ~/.local/bin/appkeys and ~/.config/hypr/appkeys.lua to $REPO"
  grep -q '^-- >>> appkeys >>>' "$BINDINGS" 2>/dev/null \
    || echo "  - append a marked appkeys block to $BINDINGS (backup first)"
  [[ -e "$HOME/.config/appkeys/keys.tsv" ]] || echo "  - create ~/.config/appkeys/keys.tsv"
  [[ "$keyd_state" == change ]] && echo "  - change caps in $KEYD_CONF: [hyper:C-A-M-S] -> [hyper:G] (backup first, as root)"
  [[ "$REPO" != "$(readlink -f "$PLUGIN_DIR" 2>/dev/null)" ]] && echo "  - link $PLUGIN_DIR to $REPO"
  read -r -p "continue? [y/N] " ok
  [[ "$ok" == [yY]* ]] || { echo "nothing changed"; exit 1; }
fi

if [[ "$REPO" != "$(readlink -f "$PLUGIN_DIR" 2>/dev/null)" ]]; then
  if [[ -e "$PLUGIN_DIR" && ! -L "$PLUGIN_DIR" ]]; then
    echo "  warning: $PLUGIN_DIR exists and is not this checkout; leaving it"
  else
    say "linking the bar widget plugin"
    mkdir -p "$(dirname "$PLUGIN_DIR")"
    ln -sfn "$REPO" "$PLUGIN_DIR"
  fi
fi

say "linking appkeys and the Hyprland module"
mkdir -p "$HOME/.local/bin" "$HOME/.config/hypr" "$HOME/.config/appkeys"
ln -sfn "$REPO/bin/appkeys" "$HOME/.local/bin/appkeys"
ln -sfn "$REPO/hypr/appkeys.lua" "$HOME/.config/hypr/appkeys.lua"

if [[ ! -e "$HOME/.config/appkeys/keys.tsv" ]]; then
  say "seeding ~/.config/appkeys/keys.tsv"
  cp "$REPO/keys.default.tsv" "$HOME/.config/appkeys/keys.tsv"
fi

if [[ -f "$BINDINGS" ]] && ! grep -q '^-- >>> appkeys >>>' "$BINDINGS"; then
  say "adding the appkeys block to bindings.lua"
  cp "$BINDINGS" "$BINDINGS.bak.appkeys.$(date +%s)"
  cat >> "$BINDINGS" <<'EOF'
-- >>> appkeys >>>
-- caps+key app switching (github.com/jamesd7788/appkeys). Managed by its
-- install.sh; re-run that after `omarchy refresh hyprland`.
local appkeys_ok, appkeys_err = pcall(require, "hypr.appkeys")
if not appkeys_ok then
  hl.exec_cmd("notify-send -u critical appkeys " .. string.format("%q", tostring(appkeys_err)))
end
-- <<< appkeys <<<
EOF
elif [[ ! -f "$BINDINGS" ]]; then
  echo "  warning: $BINDINGS not found; add: pcall(require, \"hypr.appkeys\")"
fi

case "$keyd_state" in
  done) say "keyd already sends AltGr for caps" ;;
  change)
    say "keyd: caps held -> AltGr (needs root)"
    sudo cp "$KEYD_CONF" "$KEYD_CONF.bak.appkeys.$(date +%s)"
    sudo sed -i 's/^\[hyper:C-A-M-S\]/[hyper:G]/' "$KEYD_CONF"
    sudo keyd reload
    ;;
  missing|unknown)
    echo "  note: set caps up in keyd by hand (see README):"
    echo "    [main]  capslock = overload(hyper, esc)     [hyper:G]"
    ;;
esac

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null; then
  say "reloading Hyprland"
  hyprctl reload >/dev/null
  errs="$(hyprctl configerrors)"
  [[ -n "${errs//[[:space:]]/}" ]] && { echo "  config errors:"; echo "$errs"; exit 1; }
  n="$(hyprctl binds -j | grep -c '"modmask": 128' || true)"
  echo "  $n caps binds live"
fi

say "done. caps+enter binds the focused app; \`appkeys list\` shows the table"
echo "  bar widget: omarchy plugin enable $PLUGIN_ID"
echo "  (omarchy plugin disable omarchy.workspaces drops the numbered workspaces)"
