--!nonstrict
-- Noctes service - the one owner of the note list, and the only entry that
-- touches disk.
--
-- It owns no logic of its own: `store` keeps the notes and their file, `desk`
-- keeps the sheets in Noctalia's settings, and this wires the two to the
-- surfaces. Every surface (bar widget, panel, each sheet) is a thin client that
-- reads noctes.* state and mutates through noctes.cmd.
--
-- State published:
--   noctes.notes        -> { { id, key, title, content, color, createdAt, updatedAt }, ... }
--   noctes.ready        -> true once the file has been read
--   noctes.boundKeys    -> { { key, output }, ... } - which notes have a sheet
--   noctes.editing      -> note id the panel should open ("" = nothing selected)
--   noctes.themeColors  -> the plugin-wide switch, mirrored for the sheets
--   noctes.paperOpacity -> likewise
--   noctes.savePath     -> resolved directory, informational
--
-- A note's `key` is the handle a sheet binds to, so it survives the list
-- reordering. Keys are unique; "" means the note has no sheet.
--
-- Commands accepted on noctes.cmd:
--   { op = "add", title?, content?, color?, key? }  -- creates and selects it
--   { op = "spawn_widget" }                         -- note and sheet together
--   { op = "stick", id }                            -- give a loose note a sheet
--   { op = "ensure", key }                          -- select the note with that
--                                                   -- key, creating it if absent
--   { op = "update", id, title?, content?, color? }
--   { op = "remove", id }                           -- takes the sheet down too
--   { op = "set_color", id, color }                 -- "" clears to automatic
--   { op = "set_key", id, key }
--   { op = "toggle_edit" }                          -- Noctalia's widget editor
--   { op = "refresh" }                              -- re-read the sheet list
--   { op = "reload" }                               -- re-read notes.json

local store = require("./store.luau")
local desk = require("./desk.luau")

local boundKeys = {}

-- ── Publishing ──────────────────────────────────────────────────────────────

-- The plugin-wide look, mirrored into state for the sheets: a desktop widget's
-- getConfig sees its own settings, not the plugin's. Republished on the tick so
-- a sheet that loaded before the first publish still picks it up; watchers
-- ignore a value that has not changed, so the repeat costs nothing.
local function publishPrefs()
  noctalia.state.set("noctes.themeColors", noctalia.getConfig("theme_colors") == true)
  noctalia.state.set("noctes.paperOpacity", tonumber(noctalia.getConfig("paper_opacity")) or 0.96)
end

local function publish()
  noctalia.state.set("noctes.notes", store.notes)
  noctalia.state.set("noctes.ready", store.ready)
  noctalia.state.set("noctes.boundKeys", boundKeys)
  publishPrefs()
end

-- A sheet added through Noctalia's widget editor arrives with no key, square
-- and framed, because those are fields a plugin cannot set as it is created.
-- Adopting them here is what keeps that route working without a file watcher.
local function refreshBoundKeys(adopt)
  desk.boundKeys(function(bound, loose)
    boundKeys = bound
    noctalia.state.set("noctes.boundKeys", boundKeys)

    if loose > 0 and adopt ~= false then
      desk.scatter(function()
        refreshBoundKeys(false)
      end)
    end
  end)
end

-- The panel has no keyboard-less way in: a sheet that creates a note has to
-- hand it over for editing.
local function select(id)
  noctalia.state.set("noctes.editing", id)
end

-- ── Commands ────────────────────────────────────────────────────────────────

local function addNote(fields)
  local note = store.add(fields)
  publish()
  select(note.id)
  return note
end

local function removeNote(id)
  local key = store.remove(id)
  if key == nil then
    return
  end
  if key ~= "" then
    desk.remove(key, refreshBoundKeys)
  end
  publish()
  if noctalia.state.get("noctes.editing") == id then
    select("")
  end
end

-- Note and sheet in one go: the sheet is created first, because the helper is
-- what picks a key that nothing else holds.
local function spawnWidget()
  desk.add({ avoid = store.keys() }, function(key)
    addNote({ key = key })
    refreshBoundKeys()
  end)
end

-- Gives a sheet to a note that has none: one made before the widget existed, or
-- one whose sheet was deleted from Noctalia's widget editor.
local function stickNote(id)
  local note = store.byId(id)
  if note == nil then
    return
  end

  desk.add({ key = note.key, avoid = store.keys() }, function(key)
    -- A note that already had a key keeps it; a loose one takes the key the
    -- helper picked.
    if (note.key or "") == "" then
      store.setKey(id, key)
      publish()
    end
    refreshBoundKeys()
  end)
end

-- Called by a sheet that has no note yet: it knows its key, not whether
-- anything answers to it.
local function ensureKey(key)
  if type(key) ~= "string" then
    return
  end
  local existing = store.byKey(key)
  if existing ~= nil then
    select(existing.id)
    return
  end
  addNote({ key = key })
end

-- ── The crooked-sheets switch ───────────────────────────────────────────────
--
-- Rotation is host state, so this cannot be a render-time decision: turning it
-- off rewrites every sheet's angle. And it has to be compared against what was
-- last applied rather than a value held in memory, because a config reload
-- restarts this service and the fresh copy always equals the setting.

local function applyTilt(crooked)
  local marker = store.sidecar("tilt.state")
  if marker == nil then
    return
  end
  noctalia.writeFile(marker, crooked and "random" or "square")
  desk.tilt(crooked)
end

local function syncTilt()
  local marker = store.sidecar("tilt.state")
  if marker == nil then
    return
  end

  local wanted = noctalia.getConfig("tilt") ~= false
  local applied = "random"
  if noctalia.fileExists(marker) then
    applied = noctalia.string.trim(noctalia.readFile(marker) or "random")
  end

  if (applied == "random") ~= wanted then
    applyTilt(wanted)
  end
end

-- ── Wiring ──────────────────────────────────────────────────────────────────

local function reload()
  store.useDirectory()
  noctalia.state.set("noctes.savePath", store.path() or "")
  syncTilt()
  store.load(function()
    publish()
    refreshBoundKeys()
  end)
end

noctalia.state.watch("noctes.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end

  local op = cmd.op
  if op == "add" then
    addNote(cmd)
  elseif op == "spawn_widget" then
    spawnWidget()
  elseif op == "stick" then
    stickNote(cmd.id)
  elseif op == "ensure" then
    ensureKey(cmd.key)
  elseif op == "update" then
    store.update(cmd.id, cmd)
    publish()
  elseif op == "set_color" then
    store.update(cmd.id, { color = cmd.color })
    publish()
  elseif op == "set_key" then
    store.setKey(cmd.id, cmd.key)
    publish()
  elseif op == "remove" then
    removeNote(cmd.id)
  elseif op == "toggle_edit" then
    desk.toggleEditor()
  elseif op == "refresh" then
    refreshBoundKeys()
  elseif op == "reload" then
    reload()
  end

  noctalia.state.set("noctes.cmd", nil)
end)

-- For keybinds and scripts:
--   noctalia msg plugin remo/noctes:service all desk
--   noctalia msg plugin remo/noctes:service all new ["text"]
--   noctalia msg plugin remo/noctes:service all open <key>
--   noctalia msg plugin remo/noctes:service all move
--   noctalia msg plugin remo/noctes:service all reload
function onIpc(event, payload)
  if event == "desk" then
    spawnWidget()
  elseif event == "new" then
    addNote({ content = payload })
  elseif event == "open" then
    ensureKey(noctalia.string.trim(payload or ""))
  elseif event == "move" then
    desk.toggleEditor()
  elseif event == "reload" then
    reload()
  end
end

-- Settings changed: save_path may now point somewhere else, and the tilt switch
-- may have been flipped.
function onConfigChanged()
  reload()
end

function update()
  store.flush()
  publishPrefs()
end

function onExit()
  store.flush()
end

noctalia.setUpdateInterval(2000)

select("")
publish()
reload()
