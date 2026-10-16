# appkeys — agent notes

- `hypr/appkeys.lua` runs inside Hyprland's compositor loop. Bind callbacks must
  not block: no io.popen/os.execute in anything reachable from a keypress (only
  /proc reads). Load-time work (M.setup) may shell out.
- Test without a keyboard: `hyprctl eval '<lua>'` / `hyprctl repl '<lua>'`;
  the module is global `appkeys` (entries, jump(key, here), webapp_class).
- `bin/appkeys` is stdlib-only python3. `appkeys describe` = dry run of a bind.
- Only hl.* APIs, never omarchy's `o.*` helpers (they change between releases).
  Omarchy commands used are optional with fallbacks (omarchy-launch-webapp,
  omarchy-menu-select, omarchy-launch-terminal-herdr).
- After changing the lua: `hyprctl reload && hyprctl configerrors`, and check
  `hyprctl binds -j | grep -c '"modmask": 128'` (= 88).
