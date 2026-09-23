--!nonstrict
local Store = require("./lib/store.luau")
local Capture = require("./lib/capture.luau")
local Text = require("./lib/text.luau")

local SCAN_LINES_PER_TICK = 4
local SCAN_TICK_MS = 250

local lastSignature = nil
local scanPending = false
local forceScan = false
local gitPendingAt = nil

local function interval()
  local ms = tonumber(noctalia.getConfig("poll_interval_ms")) or 5000
  if ms < 1000 then
    ms = 1000
  end
  return ms
end

local function publish(snapshot, index)
  noctalia.state.set("snapshot", snapshot)
  noctalia.state.set("index", index or {})
end

-- Due reminders -----------------------------------------------------------

local function reminderPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/reminders.json"
end

local function loadReminders()
  local path = reminderPath()
  if path == nil then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return {}
  end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" then
    return {}
  end
  return data
end

local function saveReminders(data)
  local path = reminderPath()
  if path == nil then
    return
  end
  noctalia.writeFile(path, noctalia.json.encode(data))
end

local function checkReminders(snapshot)
  if noctalia.getConfig("due_reminders") == false then
    return
  end
  local today = Text.todayIso()
  local overdue, dueToday = 0, 0
  for _, todo in ipairs(snapshot.todos) do
    if not todo.done and todo.due ~= nil then
      if todo.due < today then
        overdue = overdue + 1
      elseif todo.due == today then
        dueToday = dueToday + 1
      end
    end
  end
  if overdue == 0 and dueToday == 0 then
    return
  end

  local sig = today .. "|" .. tostring(overdue) .. "|" .. tostring(dueToday)
  local state = loadReminders()
  if state.sig == sig then
    return
  end
  local now = noctalia.nowMs()
  if state.at ~= nil and (now - state.at) < 30 * 60 * 1000 then
    return
  end

  local parts = {}
  if dueToday > 0 then
    parts[#parts + 1] = tostring(dueToday) .. " due today"
  end
  if overdue > 0 then
    parts[#parts + 1] = tostring(overdue) .. " overdue"
  end
  noctalia.notify("Quill", table.concat(parts, " · "))
  saveReminders({ sig = sig, at = now })
end

-- Git history -------------------------------------------------------------

local function commitNotes()
  if noctalia.getConfig("git_history") == false then
    return
  end
  if not noctalia.commandExists("git") then
    return
  end

  local dir = Store.notesDir()
  local message = "notes: " .. os.date("%Y-%m-%d %H:%M:%S")

  local function commit()
    noctalia.runAsync({ "git", "-C", dir, "add", "-A" }, function()
      noctalia.runAsync({ "git", "-C", dir, "commit", "-q", "-m", message }, function(result)
        if result == nil or result.exitCode == 0 then
          return
        end
        if string.find(result.stderr or "", "who you are", 1, true) ~= nil then
          noctalia.runAsync({
            "git", "-C", dir,
            "-c", "user.name=Noctalia Quill",
            "-c", "user.email=quill@localhost",
            "commit", "-q", "-m", message,
          }, function() end)
        end
      end)
    end)
  end

  if noctalia.fileExists(dir .. "/.git") then
    commit()
  else
    noctalia.runAsync({ "git", "-C", dir, "init", "-q" }, function(result)
      if result ~= nil and result.exitCode == 0 then
        commit()
      end
    end)
  end
end

-- Scanning ----------------------------------------------------------------

local function finishSnapshot(snapshot, index)
  publish(snapshot, index)
  local ok, err = pcall(checkReminders, snapshot)
  if not ok then
    noctalia.log("notes: reminders failed: " .. tostring(err))
  end
end

local function startScan(force)
  local ok, files, signature = pcall(Store.snapshotFiles)
  if not ok then
    noctalia.log("notes: listing failed: " .. tostring(files))
    return
  end
  if not force and signature == lastSignature then
    return
  end
  lastSignature = signature
  local snapshot, index = Store.beginScan(signature, files)
  if snapshot ~= nil then
    finishSnapshot(snapshot, index)
  else
    scanPending = true
  end
end

local ok, err = pcall(function()
  Store.ensureDir()
  startScan(true)
end)
if not ok then
  noctalia.log("notes: initial scan failed: " .. tostring(err))
end

noctalia.setUpdateInterval(scanPending and SCAN_TICK_MS or interval())

noctalia.state.watch("refresh_request", function()
  forceScan = true
  noctalia.setUpdateInterval(SCAN_TICK_MS)
end)

noctalia.state.watch("notes_dirty", function()
  gitPendingAt = noctalia.nowMs()
end)

function update()
  if forceScan then
    forceScan = false
    scanPending = false
    startScan(true)
  elseif not scanPending then
    startScan(false)
  end

  if scanPending then
    local snapshot, index = Store.scanStep(SCAN_LINES_PER_TICK)
    if snapshot ~= nil then
      scanPending = false
      finishSnapshot(snapshot, index)
    end
  end

  noctalia.setUpdateInterval(scanPending and SCAN_TICK_MS or interval())

  if gitPendingAt ~= nil then
    local delay = tonumber(noctalia.getConfig("git_debounce_ms")) or 8000
    if noctalia.nowMs() - gitPendingAt >= delay then
      gitPendingAt = nil
      commitNotes()
    end
  end
end

function onConfigChanged()
  lastSignature = nil
  scanPending = false
  forceScan = true
end

-- Scriptable surface:
--   noctalia msg plugin fel/quill:index refresh
--   noctalia msg plugin fel/quill:index capture '{"text":"buy milk tomorrow"}'
--   noctalia msg plugin fel/quill:index commit
function onIpc(event, payload)
  if event == "refresh" then
    forceScan = true
    noctalia.setUpdateInterval(SCAN_TICK_MS)
    return
  end

  if event == "commit" then
    commitNotes()
    return
  end

  if event == "capture" then
    local text = Text.payloadField(payload, "text")
    if text == "" then
      noctalia.notifyError("Quill", "Nothing to capture")
      return
    end
    Capture.capture(text, noctalia.getConfig("ai_capture") ~= false, function(status)
      noctalia.notify("Quill", status)
      Store.markDirty()
    end)
  end
end
