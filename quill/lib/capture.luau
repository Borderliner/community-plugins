--!nonstrict
local Store = require("./store.luau")
local AI = require("./ai.luau")
local Text = require("./text.luau")

local M = {}

local function finish(cb, status)
  Store.markDirty()
  if cb ~= nil then
    cb(status)
  end
end

function M.capture(text, useAI, cb)
  text = Text.trim(text)
  if text == "" then
    if cb ~= nil then
      cb("Nothing to capture")
    end
    return
  end

  local aiOk = AI.available()
  if not useAI or not aiOk then
    Store.appendTodo(text)
    finish(cb, "Added todo: " .. Text.truncate(text, 50))
    return
  end

  AI.parseCapture(text, function(data, err)
    if data == nil then
      Store.appendTodo(text)
      finish(cb, "AI failed (" .. tostring(err) .. ") · added as a todo")
      return
    end

    if tostring(data.kind or "todo") == "note" then
      local title = tostring(data.text or text)
      Store.createNote(title, tostring(data.body or ""))
      finish(cb, "Saved note: " .. Text.truncate(title, 50))
      return
    end

    local due = tostring(data.due or "")
    if due == "" then
      due = nil
    end
    local tags = type(data.tags) == "table" and data.tags or nil
    local priority = tonumber(data.priority) or 0
    Store.appendTodo(tostring(data.text or text), due, tags, priority)
    finish(cb, "Added todo: " .. Text.truncate(tostring(data.text or text), 50))
  end)
end

return M