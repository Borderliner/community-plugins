--!nonstrict
-- The sheets on the desktop, as opposed to the notes behind them.
--
-- A desktop widget's rotation, the background panel Noctalia draws behind it,
-- and the widget entry itself are host state in settings.toml, and no plugin
-- call writes them. So everything here either reads that file or shells out to
-- tools/noctes-widget, which is the only thing in noctes that writes outside
-- its own data directory.
--
-- Nothing in here knows what a note contains.

local M = {}

local SETTINGS_PATH = "~/.local/state/noctalia/settings.toml"
local WIDGET_TYPE = 'type = "remo/noctes:note"'
local TIMEOUT_MS = 10000

local function tool()
  local dir = noctalia.pluginDir()
  if dir == nil then
    noctalia.log("noctes: no plugin dir, cannot reach the widget tool")
    return nil
  end
  return dir .. "/tools/noctes-widget"
end

local function failed()
  noctalia.notifyError(noctalia.tr("notify.add_failed.title"),
    noctalia.tr("notify.add_failed.body"))
end

-- The helper picks the key, since the keys already spoken for are split between
-- the note list and settings.toml, and reports it on its first stdout line.
local function keyFrom(stdout)
  local key = string.match(stdout or "", "key=([^\n]+)")
  return key ~= nil and noctalia.string.trim(key) or nil
end

-- The focused output and its logical size, as the fallback for where a first
-- sheet goes. The helper prefers whichever output already holds sheets.
local function focusedGeometry()
  local name = noctalia.focusedOutputName()
  local width, height = 1920, 1080

  for _, screen in ipairs(noctalia.outputs()) do
    if name == nil then
      name = screen.name
    end
    if screen.name == name then
      width = math.floor(screen.width / (screen.scale or 1))
      height = math.floor(screen.height / (screen.scale or 1))
    end
  end

  if name == nil then
    noctalia.log("noctes: no output to place a sheet on")
    return nil
  end
  return name, width, height
end

-- ── Reading the desk ────────────────────────────────────────────────────────

-- Which keys actually have a sheet, and on which output. The panel needs this
-- to tell a stuck note from a loose one, and a sheet on the other monitor is
-- the usual reason a note looks like it exists nowhere.
--
-- onResult also gets the number of sheets with no key at all. Those are the
-- ones Noctalia's own widget editor produces, since a plugin cannot fill in a
-- widget's settings as it is created.
function M.boundKeys(onResult)
  noctalia.readFileAsync(noctalia.expandPath(SETTINGS_PATH), function(contents, err)
    if contents == nil then
      noctalia.log("noctes: cannot read settings: " .. tostring(err))
      return
    end

    local outputs = {}
    for id, body in string.gmatch(contents, "%[desktop_widgets%.widget%.([%w%-]+)%]([^%[]*)") do
      if string.find(body, WIDGET_TYPE, 1, true) then
        outputs[id] = string.match(body, 'output%s*=%s*"([^"]*)"') or "?"
      end
    end

    local bound, keyed = {}, {}
    for id, body in string.gmatch(contents, "%[desktop_widgets%.widget%.([%w%-]+)%.settings%]([^%[]*)") do
      if outputs[id] ~= nil then
        local key = string.match(body, 'key%s*=%s*"([^"]*)"')
        if key ~= nil and key ~= "" then
          keyed[id] = true
          table.insert(bound, { key = key, output = outputs[id] })
        end
      end
    end

    local loose = 0
    for id in pairs(outputs) do
      if not keyed[id] then
        loose = loose + 1
      end
    end

    onResult(bound, loose)
  end)
end

-- ── Changing the desk ───────────────────────────────────────────────────────

-- Adds a sheet. `key` binds it to an existing note; without one the helper
-- generates a key avoiding everything in `avoid`. onKey receives the key used.
function M.add(options, onKey)
  local path = tool()
  local output, width, height = focusedGeometry()
  if path == nil or output == nil then
    return
  end

  local argv = {
    path, "add",
    "--output", output,
    "--screen", string.format("%dx%d", width, height),
    "--avoid", table.concat(options.avoid or {}, ","),
  }
  if (options.key or "") ~= "" then
    table.insert(argv, "--key")
    table.insert(argv, options.key)
  end

  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("noctes: noctes-widget failed: " .. tostring(result.stderr))
      failed()
      return
    end
    local key = keyFrom(result.stdout)
    if key == nil then
      noctalia.log("noctes: noctes-widget gave no key")
      return
    end
    onKey(key)
  end, TIMEOUT_MS)
end

function M.remove(key, onDone)
  local path = tool()
  if path == nil or key == nil or key == "" then
    return
  end
  noctalia.runAsync({ path, "remove", "--key", key }, function()
    onDone()
  end, TIMEOUT_MS)
end

-- Gives a key, an angle and no background panel to sheets that have none: the
-- state Noctalia's widget editor leaves them in.
function M.scatter(onDone)
  local path = tool()
  if path == nil then
    return
  end
  noctalia.runAsync({ path, "scatter" }, function()
    onDone()
  end, TIMEOUT_MS)
end

-- Every sheet crooked, or every sheet square.
function M.tilt(crooked)
  local path = tool()
  if path == nil then
    return
  end
  noctalia.runAsync({ path, "tilt", crooked and "--random" or "--square" }, nil, TIMEOUT_MS)
end

-- Noctalia's own widget editor is what moves, resizes and rotates a sheet, and
-- no Luau call opens it - only the IPC command, so the plugin asks its own CLI.
function M.toggleEditor()
  noctalia.runAsync({ "noctalia", "msg", "desktop-widgets-toggle-edit" }, nil, 5000)
end

return M
