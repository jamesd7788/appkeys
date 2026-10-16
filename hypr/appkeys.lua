-- appkeys: caps + key jumps to an app; every app gets its own workspace.
--
--   caps + key          go to the app (cycle its windows if already there);
--                       not running -> launch it on an empty workspace
--   caps + shift + key  bring the app here (pull its window over, or launch here)
--   caps + space        send the focused window off to its own empty workspace
--   caps + enter        bind mode: next key binds the focused app (backspace unbinds)
--
-- caps is AltGr via keyd, which lv3:ralt_switch turns into Mod5 -- a modifier
-- nothing else uses, so shift/ctrl stack on it cleanly. Key table:
-- ~/.config/appkeys/keys.tsv, written by `appkeys bind`, read at config load.
-- Uses only hl.* (no omarchy helpers) so omarchy updates can't break it.

local M = {}
_G.appkeys = M

local HOME = os.getenv("HOME")
local CONFIG = (os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/appkeys"
M.keys_file = CONFIG .. "/keys.tsv"

local MOD = "MOD5"
-- Everything bindable: digits by keycode (layout-proof), letters minus h/j/k/l,
-- which keyd turns into arrows while caps is held, and punctuation.
local KEYS = {}
for i = 1, 10 do
  KEYS[#KEYS + 1] = { name = tostring(i % 10), spec = "code:" .. (i + 9) }
end
for c in ("abcdefgimnopqrstuvwxyz"):gmatch(".") do
  KEYS[#KEYS + 1] = { name = c, spec = c }
end
-- Punctuation by physical key, labelled as on a UK keyboard (# is next to
-- enter, \ left of z). Grave is left out: keyd remaps it.
for _, k in ipairs({ { "-", 20 }, { "=", 21 }, { "[", 34 }, { "]", 35 }, { ";", 47 }, { "'", 48 },
                     { "#", 51 }, { ",", 59 }, { ".", 60 }, { "/", 61 }, { "\\", 94 } }) do
  KEYS[#KEYS + 1] = { name = k[1], spec = "code:" .. k[2] }
end

local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function exec(cmd)
  hl.dispatch(hl.dsp.exec_cmd(cmd))
end

local function notify(msg)
  exec("notify-send -a appkeys -t 2500 " .. sh_quote(msg))
end

-- Load-time only (io.popen would stall the compositor inside a bind).
local function has_cmd(name)
  local p = io.popen("command -v " .. sh_quote(name) .. " 2>/dev/null")
  local out = p:read("*l")
  p:close()
  return out ~= nil and out ~= ""
end

local function read_file(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Chromium names an --app=URL window "chrome-<host>_<path, / -> _>-<profile>".
function M.webapp_class(url)
  local host, path = url:match("^%a+://([^/?#]+)([^?#]*)")
  if not host then return nil end
  if path == "" then path = "/" end
  return "chrome-" .. host .. "_" .. (path:gsub("/", "_")) .. "-"
end

local function desktop_launch(id)
  return "uwsm-app -- " .. sh_quote(id)
end

-- Installed PWAs: the desktop id carries the chromium profile, which differs per host.
local function pwa_desktop(id)
  local p = io.popen("cd ~/.local/share/applications 2>/dev/null && ls chrome-" .. id .. "-*.desktop 2>/dev/null | head -1")
  local out = p:read("*l")
  p:close()
  return out
end

local function proc_children(pid)
  local out = {}
  local s = read_file("/proc/" .. pid .. "/task/" .. pid .. "/children")
  if s then
    for c in s:gmatch("%d+") do out[#out + 1] = c end
  end
  return out
end

-- Entry -> { name, matches(window), launch }
local function resolve(e)
  local kind, target = e.kind, e.target
  local r = { name = e.name, launch = e.launch }

  if kind == "web" then
    local prefix = M.webapp_class(target)
    if not prefix then return nil end
    r.matches = function(w) return w.class:sub(1, #prefix) == prefix end
    r.launch = r.launch or (M.have_webapp_launcher and ("omarchy-launch-webapp " .. sh_quote(target))
      or ("uwsm-app -- chromium --app=" .. sh_quote(target)))
  elseif kind == "pwa" then
    local a, b = "chrome-" .. target .. "-", "crx_" .. target
    r.matches = function(w) return w.class:sub(1, #a) == a or w.class == b end
    if not r.launch then
      local desktop = pwa_desktop(target)
      if not desktop then return nil end -- not installed on this host
      r.launch = desktop_launch(desktop)
    end
  elseif kind == "class" then
    local set = {}
    for c in target:gmatch("[^|]+") do set[c:lower()] = true end
    r.matches = function(w) return set[w.class:lower()] or set[(w.initial_class or ""):lower()] or false end
    local launch = r.launch or target:match("^[^|]+")
    r.launch = launch:match("^uwsm%-app") and launch or ("uwsm-app -- " .. launch)
  elseif kind == "proc" then
    -- A terminal window whose direct child is <target> (herdr, wled-tui, ...).
    r.matches = function(w)
      for _, c in ipairs(proc_children(w.pid)) do
        local comm = read_file("/proc/" .. c .. "/comm")
        if comm and comm:gsub("%s+$", "") == target then return true end
      end
      return false
    end
    r.launch = r.launch or ("xdg-terminal-exec -e " .. target)
  elseif kind == "cmd" then
    r.cmd = target
  else
    return nil
  end
  return r
end

function M.load()
  M.entries = {}
  local s = read_file(M.keys_file)
  if not s then return end
  for line in s:gmatch("[^\n]+") do
    if not (line:match("^# ") or line == "#") then -- "#<tab>..." is the # key
      local f = {}
      for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
      local key, name, kind, target, launch = f[1], f[2], f[3], f[4], f[5]
      if key and kind and target and target ~= "" then
        local r = resolve({ name = name ~= "" and name or target, kind = kind, target = target,
          launch = (launch and launch ~= "") and launch or nil })
        if r then M.entries[key:lower()] = r end
      end
    end
  end
end

local function app_windows(r)
  local out = {}
  for _, w in ipairs(hl.get_windows()) do
    -- Skip special (scratchpad) workspaces: negative ids.
    if w.mapped and not w.hidden and w.workspace and w.workspace.id > 0 and r.matches(w) then
      out[#out + 1] = w
    end
  end
  return out
end

local function most_recent(wins, skip_ws)
  local best
  for _, w in ipairs(wins) do
    if not (skip_ws and w.workspace.id == skip_ws) then
      local h = w.focus_history_id
      if h and h >= 0 and (not best or h < best.focus_history_id) then best = w end
    end
  end
  return best
end

local function focus(w)
  hl.dispatch(hl.dsp.focus({ window = "address:" .. w.address }))
end

function M.jump(key, here)
  M.last = (here and "here:" or "go:") .. key -- debugging: hyprctl eval 'return appkeys.last'
  local r = M.entries[key]
  if not r then
    notify("caps+" .. key .. " is unbound · caps+enter binds the focused app")
    return
  end
  if r.cmd then
    exec(r.cmd)
    return
  end

  local wins = app_windows(r)
  local active = hl.get_active_window()
  local ws = hl.get_active_workspace()

  if here then
    if #wins == 0 then
      exec(r.launch)
      return
    end
    local w = most_recent(wins, ws and ws.id) or most_recent(wins) or wins[1]
    if ws and w.workspace.id ~= ws.id then
      hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws.id), follow = false, window = "address:" .. w.address }))
    end
    focus(w)
    return
  end

  if #wins == 0 then
    -- Stand on an empty workspace first, so even single-instance apps (whose
    -- window comes from another process) land there.
    if ws and ws.windows > 0 then
      hl.dispatch(hl.dsp.focus({ workspace = "empty" }))
    end
    exec(r.launch)
    return
  end

  if active and r.matches(active) then
    if #wins == 1 then return end
    table.sort(wins, function(a, b) return a.stable_id < b.stable_id end)
    for i, w in ipairs(wins) do
      if w.address == active.address then
        focus(wins[i % #wins + 1])
        return
      end
    end
  end
  focus(most_recent(wins) or wins[1])
end

-- For the bar widget: every app workspace with the apps on it and their keys,
-- as JSON. Called through `hyprctl repl`, never from a bind.
local function json_str(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
end

local function short_class(class)
  local host = class:match("^chrome%-(.-)__")
  if host then
    local label
    for part in host:gmatch("[^.]+") do
      if part ~= "www" and part ~= "web" and part ~= "app" and part ~= "m" then label = label or part end
    end
    class = label or host
  else
    class = class:match("([^.]+)$") or class
  end
  return (class:gsub("^%l", string.upper))
end

function M.labels()
  local keys = {}
  for k in pairs(M.entries) do keys[#keys + 1] = k end
  table.sort(keys)
  local spaces, order = {}, {}
  for _, w in ipairs(hl.get_windows()) do
    if w.mapped and not w.hidden and w.workspace and w.workspace.id > 0 then
      local key, name
      for _, k in ipairs(keys) do
        local r = M.entries[k]
        if r.matches and r.matches(w) then key, name = k, r.name break end
      end
      local id = w.workspace.id
      if not spaces[id] then spaces[id] = {} order[#order + 1] = id end
      spaces[id][#spaces[id] + 1] = string.format('{"key":%s,"name":%s,"address":%s,"floating":%s}',
        json_str(key or ""), json_str(name or short_class(w.class)), json_str(w.address), tostring(w.floating))
    end
  end
  table.sort(order)
  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = string.format('{"id":%d,"apps":[%s]}', id, table.concat(spaces[id], ","))
  end
  return "[" .. table.concat(out, ",") .. "]"
end

function M.setup()
  M.have_webapp_launcher = has_cmd("omarchy-launch-webapp")
  M.load()

  -- Caps arrives as AltGr; make it Mod5. Append, so the layout's own options stay.
  local opts = hl.get_config("input.kb_options") or ""
  if not opts:find("lv3:ralt_switch", 1, true) then
    hl.config({ input = { kb_options = (opts == "" and "" or opts .. ",") .. "lv3:ralt_switch" } })
  end

  for _, k in ipairs(KEYS) do
    local e = M.entries[k.name]
    local label = e and e.name or "unbound"
    hl.bind(MOD .. " + " .. k.spec, function() M.jump(k.name, false) end, { description = "Go to " .. label })
    hl.bind(MOD .. " + SHIFT + " .. k.spec, function() M.jump(k.name, true) end, { description = "Bring here: " .. label })
  end

  hl.bind(MOD .. " + space", hl.dsp.window.move({ workspace = "empty" }), { description = "Window to its own workspace" })

  -- Bind mode. "reset" closes the submap after any bind fires; escape (= a caps
  -- tap) cancels; a timer bails out if nothing is pressed.
  hl.bind(MOD .. " + Return", function()
    hl.dispatch(hl.dsp.submap("appkeys"))
    notify("bind mode: press a key for the focused app · ⌫ unbind · esc cancel")
    hl.timer(function()
      if hl.get_current_submap() == "appkeys" then hl.dispatch(hl.dsp.submap("reset")) end
    end, { timeout = 6000, type = "oneshot" })
  end, { description = "Bind focused app to a caps key" })

  hl.define_submap("appkeys", "reset", function()
    for _, k in ipairs(KEYS) do
      local cmd = hl.dsp.exec_cmd("appkeys bind " .. sh_quote(k.name))
      hl.bind(k.spec, cmd)
      hl.bind(MOD .. " + " .. k.spec, cmd) -- caps still held
    end
    hl.bind("BackSpace", hl.dsp.exec_cmd("appkeys unbind"))
    hl.bind("Escape", hl.dsp.submap("reset"))
  end)

  -- Apps open alone on their workspace: no gaps or border when a window is alone.
  hl.workspace_rule({ workspace = "w[tv1]s[false]", gaps_out = 0, gaps_in = 0 })
  hl.workspace_rule({ workspace = "f[1]s[false]", gaps_out = 0, gaps_in = 0 })
  hl.window_rule({ match = { float = false, workspace = "w[tv1]s[false]" }, border_size = 0 })
  hl.window_rule({ match = { float = false, workspace = "w[tv1]s[false]" }, rounding = 0 })
  hl.window_rule({ match = { float = false, workspace = "f[1]s[false]" }, border_size = 0 })
  hl.window_rule({ match = { float = false, workspace = "f[1]s[false]" }, rounding = 0 })
end

M.setup()
return M
