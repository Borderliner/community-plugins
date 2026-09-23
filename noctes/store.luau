--!nonstrict
-- The note list and the file it lives in. Nothing else in noctes touches
-- notes.json, and nothing in here knows about desktop widgets, state keys or
-- panels - it stores notes and hands them back in order.
--
-- Order invariant: newest updatedAt first. Callers render the list directly and
-- never re-sort.

local colors = require("./colors.luau")

local M = {}

M.notes = {}
M.ready = false

local directory = nil
local idCounter = 0

-- Autosave fires about once a second while someone types, and each one would
-- otherwise rewrite the whole file. Mutations mark the list dirty instead, and
-- `flush` writes at most once per tick.
local saveDue = false

-- "" means automatic: the sheet then derives its paper from its key, so notes
-- look different from each other without anyone picking colors.
local function defaultColor()
  local configured = noctalia.getConfig("default_color")
  if type(configured) == "string" and colors.isKnown(configured) then
    return configured
  end
  return ""
end

local function storedColor(value)
  if type(value) ~= "string" or (value ~= "" and not colors.isKnown(value)) then
    return defaultColor()
  end
  return value
end

-- Unique within a run: nowMs alone collides when two notes are created in the
-- same millisecond.
local function newId()
  idCounter = idCounter + 1
  return string.format("%d-%d", math.floor(noctalia.nowMs()), idCounter)
end

local function sortNotes()
  table.sort(M.notes, function(a, b)
    return (a.updatedAt or 0) > (b.updatedAt or 0)
  end)
end

local function normalize(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local id = raw.id
  if type(id) ~= "string" or id == "" then
    id = newId()
  end
  local now = os.time()
  return {
    id = id,
    key = type(raw.key) == "string" and raw.key or "",
    title = type(raw.title) == "string" and raw.title or "",
    content = type(raw.content) == "string" and raw.content or "",
    color = storedColor(raw.color),
    createdAt = type(raw.createdAt) == "number" and raw.createdAt or now,
    updatedAt = type(raw.updatedAt) == "number" and raw.updatedAt or now,
  }
end

-- ── File ────────────────────────────────────────────────────────────────────

function M.path()
  if directory == nil then
    return nil
  end
  return directory .. "/notes.json"
end

-- A sibling of notes.json, for the one bit of state that is not a note.
function M.sidecar(name)
  if directory == nil then
    return nil
  end
  return directory .. "/" .. name
end

-- Resolves the directory from `save_path`, falling back to the plugin's own
-- data directory, and creates it.
function M.useDirectory()
  local configured = noctalia.string.trim(noctalia.getConfig("save_path") or "")
  local dir = configured ~= "" and noctalia.expandPath(configured) or noctalia.pluginDataDir()

  if dir == nil or dir == "" then
    noctalia.log("noctes: no writable data directory")
    return nil
  end

  local ok, err = noctalia.mkdirAll(dir)
  if not ok then
    noctalia.log("noctes: mkdir failed: " .. tostring(err))
  end
  directory = dir
  return dir
end

local function writeNow()
  local path = M.path()
  if path == nil then
    return
  end
  local encoded, err = noctalia.json.encode({ notes = M.notes }, true)
  if encoded == nil then
    noctalia.log("noctes: encode failed: " .. tostring(err))
    return
  end
  local ok, writeErr = noctalia.writeFile(path, encoded)
  if not ok then
    noctalia.log("noctes: write failed: " .. tostring(writeErr))
  end
end

function M.flush()
  if saveDue then
    saveDue = false
    writeNow()
  end
end

function M.load(onDone)
  -- Re-reading replaces the in-memory list, so anything still waiting on the
  -- debounce has to reach disk first or it is simply gone.
  M.flush()

  local path = M.path()
  local function finish()
    M.ready = true
    onDone()
  end

  if path == nil or not noctalia.fileExists(path) then
    finish()
    return
  end

  noctalia.readFileAsync(path, function(contents, err)
    if contents == nil then
      noctalia.log("noctes: read failed: " .. tostring(err))
      finish()
      return
    end

    local decoded, decodeErr = noctalia.json.decode(contents)
    if decoded == nil then
      noctalia.log("noctes: decode failed: " .. tostring(decodeErr))
      finish()
      return
    end

    -- Accepts both the wrapped shape this writes and a bare array, so a
    -- hand-edited file stays loadable.
    local list = type(decoded.notes) == "table" and decoded.notes or decoded
    M.notes = {}
    if type(list) == "table" then
      for _, raw in ipairs(list) do
        local note = normalize(raw)
        if note ~= nil then
          table.insert(M.notes, note)
        end
      end
    end
    sortNotes()
    finish()
  end)
end

-- ── Queries ─────────────────────────────────────────────────────────────────

function M.byId(id)
  for index, note in ipairs(M.notes) do
    if note.id == id then
      return note, index
    end
  end
  return nil
end

function M.byKey(key)
  for _, note in ipairs(M.notes) do
    if (note.key or "") == key then
      return note
    end
  end
  return nil
end

-- Every key currently spoken for, for the helper that has to pick a free one.
function M.keys()
  local keys = {}
  for _, note in ipairs(M.notes) do
    if (note.key or "") ~= "" then
      table.insert(keys, note.key)
    end
  end
  return keys
end

-- ── Mutations. Each one leaves the list sorted and the file pending. ─────────

function M.add(fields)
  fields = fields or {}
  local now = os.time()
  local note = {
    id = newId(),
    key = type(fields.key) == "string" and fields.key or "",
    title = type(fields.title) == "string" and fields.title or "",
    content = type(fields.content) == "string" and fields.content or "",
    color = storedColor(fields.color),
    createdAt = now,
    updatedAt = now,
  }
  table.insert(M.notes, note)
  sortNotes()
  saveDue = true
  return note
end

function M.update(id, fields)
  local note = M.byId(id)
  if note == nil then
    return nil
  end
  if type(fields.title) == "string" then
    note.title = fields.title
  end
  if type(fields.content) == "string" then
    note.content = fields.content
  end
  -- An empty string clears the color back to automatic.
  if type(fields.color) == "string" and (fields.color == "" or colors.isKnown(fields.color)) then
    note.color = fields.color
  end
  note.updatedAt = os.time()
  sortNotes()
  saveDue = true
  return note
end

-- Returns the key the note held, so the caller can take its sheet down too.
function M.remove(id)
  local note, index = M.byId(id)
  if note == nil then
    return nil
  end
  table.remove(M.notes, index)
  saveDue = true
  return note.key or ""
end

-- A key binds a note to a sheet, so it has to stay unique: taking a key frees
-- it from whatever note held it before.
function M.setKey(id, key)
  local note = M.byId(id)
  if note == nil or type(key) ~= "string" then
    return nil
  end
  key = noctalia.string.trim(key)

  if key ~= "" then
    for _, other in ipairs(M.notes) do
      if other.id ~= id and (other.key or "") == key then
        other.key = ""
      end
    end
  end

  note.key = key
  note.updatedAt = os.time()
  sortNotes()
  saveDue = true
  return note
end

return M
