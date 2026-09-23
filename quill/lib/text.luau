--!nonstrict
local M = {}

local STOPWORDS = {
  ["the"] = true, ["a"] = true, ["an"] = true, ["and"] = true, ["or"] = true,
  ["of"] = true, ["to"] = true, ["in"] = true, ["on"] = true, ["for"] = true,
  ["is"] = true, ["are"] = true, ["was"] = true, ["were"] = true,
  ["with"] = true, ["that"] = true, ["this"] = true, ["it"] = true, ["its"] = true,
  ["as"] = true, ["at"] = true, ["by"] = true, ["be"] = true, ["from"] = true,
  ["i"] = true, ["my"] = true, ["me"] = true, ["mine"] = true,
  ["you"] = true, ["your"] = true, ["we"] = true, ["our"] = true,
  ["do"] = true, ["does"] = true, ["did"] = true,
  ["how"] = true, ["what"] = true, ["when"] = true, ["where"] = true,
  ["which"] = true, ["who"] = true, ["why"] = true,
  ["can"] = true, ["could"] = true, ["should"] = true, ["would"] = true,
  ["will"] = true, ["about"] = true, ["into"] = true, ["over"] = true,
  ["just"] = true, ["not"] = true, ["no"] = true, ["yes"] = true,
  ["have"] = true, ["has"] = true, ["had"] = true, ["there"] = true,
  ["then"] = true, ["than"] = true, ["so"] = true, ["if"] = true,
  ["but"] = true, ["all"] = true, ["any"] = true, ["some"] = true,
  ["need"] = true, ["want"] = true, ["get"] = true, ["got"] = true,
  ["make"] = true, ["made"] = true,
}

function M.trim(s)
  if s == nil then
    return ""
  end
  s = tostring(s)
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

function M.payloadField(payload, field)
  if type(payload) == "table" then
    local value = payload[field]
    if value ~= nil then
      return tostring(value)
    end
    return ""
  end
  if type(payload) == "string" then
    local trimmed = M.trim(payload)
    if string.sub(trimmed, 1, 1) == "{" then
      local data = M.extractJson(trimmed)
      if type(data) == "table" and data[field] ~= nil then
        return tostring(data[field])
      end
      return ""
    end
    return trimmed
  end
  return ""
end

function M.splitLines(s)
  local lines = {}
  if s == nil or s == "" then
    return lines
  end
  local start = 1
  while true do
    local nl = string.find(s, "\n", start, true)
    if nl == nil then
      table.insert(lines, string.sub(s, start))
      break
    end
    table.insert(lines, string.sub(s, start, nl - 1))
    start = nl + 1
  end
  return lines
end

function M.joinLines(lines)
  return table.concat(lines, "\n")
end

function M.slugify(s)
  local out = string.lower(s or "")
  out = string.gsub(out, "[^%w]+", "-")
  out = string.gsub(out, "^-+", "")
  out = string.gsub(out, "-+$", "")
  if #out > 60 then
    out = string.sub(out, 1, 60)
    out = string.gsub(out, "-+$", "")
  end
  return out
end

function M.yamlString(s)
  s = tostring(s or "")
  if s == "" then
    return '""'
  end
  if string.find(s, "^[%w%s%-_%.%(%)%,:/']+$") ~= nil then
    return s
  end
  return '"' .. string.gsub(s, '"', '\\"') .. '"'
end

function M.stripMarkdown(s)
  local out = tostring(s or "")
  out = string.gsub(out, "!%[([^%]]*)%]%([^%)]*%)", "%1")
  out = string.gsub(out, "%[%[([^%]]*)%]%]", "%1")
  out = string.gsub(out, "%[([^%]]*)%]%([^%)]*%)", "%1")
  out = string.gsub(out, "`([^`]*)`", "%1")
  out = string.gsub(out, "%*%*([^%*]*)%*%*", "%1")
  out = string.gsub(out, "__([^_]*)__", "%1")
  out = string.gsub(out, "^%s*#+%s*", "")
  out = string.gsub(out, "^%s*[%-%*%+]%s+", "")
  out = string.gsub(out, "%s+", " ")
  return M.trim(out)
end

function M.truncate(s, n)
  s = tostring(s or "")
  if #s <= n then
    return s
  end
  return string.sub(s, 1, math.max(1, n - 1)) .. "…"
end

function M.firstLine(s)
  s = tostring(s or "")
  local nl = string.find(s, "\n", 1, true)
  if nl == nil then
    return M.trim(s)
  end
  return M.trim(string.sub(s, 1, nl - 1))
end

function M.collapseSpaces(s)
  return M.trim(string.gsub(tostring(s or ""), "%s+", " "))
end

function M.extractJson(s)
  if type(s) ~= "string" then
    return nil
  end
  local fenced = string.match(s, "```[Jj][Ss][Oo][Nn]%s*(.-)%s*```")
  if fenced ~= nil then
    s = fenced
  end
  local body = string.match(s, "({.*})")
  if body == nil then
    local arr = string.match(s, "%[(.*)%]")
    if arr ~= nil then
      body = "[" .. arr .. "]"
    end
  end
  if body == nil then
    return nil
  end
  local data = noctalia.json.decode(body)
  if type(data) == "table" then
    return data
  end
  return nil
end

function M.keywords(s)
  local out, seen = {}, {}
  for word in string.gmatch(string.lower(tostring(s or "")), "[%w_]+") do
    if #word >= 3 and not STOPWORDS[word] and not seen[word] then
      seen[word] = true
      table.insert(out, word)
    end
  end
  return out
end

function M.todayIso()
  return os.date("%Y-%m-%d")
end

function M.isoEpoch(iso, hour)
  if iso == nil or iso == "" then
    return nil
  end
  local y, mo, d = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = hour or 12,
  })
end

function M.daysUntil(iso)
  local target = M.isoEpoch(iso)
  if target == nil then
    return nil
  end
  local now = os.time()
  local midnight = os.time({
    year = tonumber(os.date("%Y", now)),
    month = tonumber(os.date("%m", now)),
    day = tonumber(os.date("%d", now)),
    hour = 12,
  })
  return math.floor((target - midnight) / 86400)
end

function M.fmtDue(iso)
  local diff = M.daysUntil(iso)
  if diff == nil then
    return nil
  end
  if diff == 0 then
    return "today"
  end
  if diff == 1 then
    return "tomorrow"
  end
  if diff == -1 then
    return "yesterday"
  end
  if diff < 0 then
    return tostring(-diff) .. "d overdue"
  end
  if diff <= 7 then
    return "in " .. tostring(diff) .. "d"
  end
  local epoch = M.isoEpoch(iso)
  return os.date("%b %d", epoch)
end

function M.relTime(seconds)
  if seconds == nil then
    return ""
  end
  if seconds < 45 then
    return "just now"
  end
  if seconds < 3600 then
    return tostring(math.floor(seconds / 60)) .. "m ago"
  end
  if seconds < 86400 then
    return tostring(math.floor(seconds / 3600)) .. "h ago"
  end
  if seconds < 86400 * 30 then
    return tostring(math.floor(seconds / 86400)) .. "d ago"
  end
  return os.date("%b %d", os.time() - seconds)
end

function M.addDays(iso, n)
  local epoch = M.isoEpoch(iso)
  if epoch == nil then
    return nil
  end
  local t = os.date("*t", epoch + n * 86400)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

function M.addMonths(iso, n)
  local y, mo, d = string.match(tostring(iso or ""), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  mo = mo + n
  while mo > 12 do
    mo = mo - 12
    y = y + 1
  end
  local dim = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then
    dim[2] = 29
  end
  if d > dim[mo] then
    d = dim[mo]
  end
  return string.format("%04d-%02d-%02d", y, mo, d)
end

function M.nextRecurrence(iso, rule)
  local base = iso
  if base == nil or base == "" then
    base = M.todayIso()
  end
  if rule == "daily" then
    return M.addDays(base, 1)
  end
  if rule == "weekly" then
    return M.addDays(base, 7)
  end
  if rule == "monthly" then
    return M.addMonths(base, 1)
  end
  return nil
end

function M.wikilinks(s)
  local out, seen = {}, {}
  for target in string.gmatch(tostring(s or ""), "%[%[([^%]]+)%]%]") do
    local clean = string.match(target, "^([^|#]+)") or target
    clean = M.trim(clean)
    if clean ~= "" and not seen[clean] then
      seen[clean] = true
      out[#out + 1] = clean
    end
  end
  return out
end

return M