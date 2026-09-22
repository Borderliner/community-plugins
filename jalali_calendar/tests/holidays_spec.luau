--!nonstrict
local h = require("./harness")
local holidays = require("../holidays")
local jalali = require("../jalali")

local function titles(list)
  local out = {}
  for _, o in list do
    table.insert(out, o.title)
  end
  return table.concat(out, " | ")
end

-- What the plugin ships with: civil and ancient Iranian days, no religious or
-- political commemorations, no Afghan events.
local DEFAULT = { national = true, ancient = true }
local ALL = { national = true, ancient = true, religious = true, political = true, afghan = true }

local function hasHoliday(list)
  for _, o in list do
    if o.holiday then
      return true
    end
  end
  return false
end

return function()
  h.describe("fixed solar occasions", function()
    local nowruz = holidays.forDay(1405, 1, 1)
    h.ok(#nowruz >= 1, "nowruz has at least one occasion")
    h.eq(hasHoliday(nowruz), true, "nowruz is a day off")
    h.eq(holidays.isHoliday(1405, 1, 1), true, "nowruz is a holiday")

    h.eq(holidays.isHoliday(1405, 1, 13), true, "sizdah bedar is a holiday")
    h.eq(holidays.isHoliday(1405, 11, 22), true, "22 bahman is a holiday")
    h.eq(holidays.isHoliday(1405, 12, 29), true, "29 esfand is a holiday")
    h.eq(holidays.isHoliday(1405, 3, 14), true, "14 khordad is a holiday")
  end)

  h.describe("solar occasions apply to every year", function()
    -- Keyed by rule, not resolved per year, so any year works.
    for _, jy in { 1390, 1400, 1405, 1420, 1450 } do
      h.eq(holidays.isHoliday(jy, 1, 1), true, `nowruz is a holiday in {jy}`)
    end
  end)

  h.describe("lunar occasions resolve through the hijri calendar", function()
    -- 10 Muharram 1447 (Ashura) fell on 2025-07-06, inside the observed data.
    local jy, jm, jd = jalali.fromJDN(jalali.gregorianToJDN(2025, 7, 6))
    local list = holidays.forDay(jy, jm, jd)
    h.eq(hasHoliday(list), true, `ashura 1447 is a holiday: {titles(list)}`)

    -- Eid al-Fitr, 1 Shawwal 1446, fell on 2025-03-31.
    local fy, fm, fd = jalali.fromJDN(jalali.gregorianToJDN(2025, 3, 31))
    h.eq(hasHoliday(holidays.forDay(fy, fm, fd)), true, "eid al-fitr 1446 is a holiday")
  end)

  h.describe("ordinary days", function()
    -- 31 Shahrivar 1405 carries no official holiday.
    h.eq(holidays.isHoliday(1405, 6, 31), false, "31 shahrivar is not a holiday")
  end)

  h.describe("every occasion is well formed", function()
    local bad = 0
    local seen = 0
    for jm = 1, 12 do
      for jd = 1, jalali.monthLength(1405, jm) do
        for _, o in holidays.forDay(1405, jm, jd) do
          seen += 1
          if type(o.title) ~= "string" or o.title == "" then
            bad += 1
          end
          if type(o.holiday) ~= "boolean" then
            bad += 1
          end
        end
      end
    end
    h.ok(seen > 100, `1405 has a substantial occasion list, got {seen}`)
    h.eq(bad, 0, "every occasion has a title and a holiday flag")
  end)

  h.describe("official holiday count is plausible", function()
    -- Iran has roughly 26 official public holidays a year across all three
    -- calendars. A wild number here means a lookup is double counting, a
    -- calendar is not resolving, or another country's holidays are leaking in
    -- (Afghan days off are not Iranian ones).
    local count = 0
    for jm = 1, 12 do
      for jd = 1, jalali.monthLength(1405, jm) do
        if holidays.isHoliday(1405, jm, jd, DEFAULT) then
          count += 1
        end
      end
    end
    h.ok(count >= 20 and count <= 32, `1405 has 20-32 holidays, got {count}`)
  end)

  h.describe("month view", function()
    local farvardin = holidays.forMonth(1405, 1)
    h.ok(farvardin[1] ~= nil and #farvardin[1] >= 1, "day 1 has an occasion")
    h.ok(farvardin[13] ~= nil and #farvardin[13] >= 1, "day 13 has an occasion")
  end)

  h.describe("official holidays keep their names whatever the filters", function()
    -- Ashura 1447 fell on 2025-07-06 and is a public holiday in Iran. Its name
    -- is what the day off is called, so it must survive the religious filter --
    -- a calendar that says only "official holiday" knows more than it admits.
    local jy, jm, jd = jalali.fromJDN(jalali.gregorianToJDN(2025, 7, 6))

    local shown = holidays.forDay(jy, jm, jd, DEFAULT)
    h.eq(holidays.isHoliday(jy, jm, jd, DEFAULT), true, "ashura is a holiday")
    h.eq(hasHoliday(shown), true, `and is named by default: {titles(shown)}`)

    -- 22 Bahman is a political holiday; it is still the name of a day off.
    local bahman = holidays.forDay(1405, 11, 22, DEFAULT)
    h.eq(hasHoliday(bahman), true, `22 bahman is named by default: {titles(bahman)}`)
  end)

  h.describe("political commemorations are not carried at all", function()
    -- 31 Shahrivar used to carry the start of the Iran-Iraq war and Sacred
    -- Defense Week. Those are not a toggle: they are absent from the data, so
    -- enabling every category cannot bring them back.
    for _, entry in holidays.forDay(1405, 6, 31, ALL) do
      h.ok(
        not string.find(entry.title, "دفاع مقدس")
          and not string.find(entry.title, "جنگ تحمیلی"),
        `no war commemoration on 31 shahrivar, got: {entry.title}`
      )
    end
    h.eq(holidays.isHoliday(1405, 6, 31, ALL), false, "31 shahrivar is not a day off")
  end)

  h.describe("political public holidays survive, since they are days off", function()
    -- 22 Bahman is an Islamic Republic anniversary and a public holiday. The
    -- commemorations go; the day off stays, named.
    local shown = holidays.forDay(1405, 11, 22, DEFAULT)
    h.eq(holidays.isHoliday(1405, 11, 22, DEFAULT), true, "22 bahman is a day off")
    h.eq(hasHoliday(shown), true, `and keeps its name: {titles(shown)}`)
  end)

  h.describe("religious honorifics are stripped from titles", function()
    -- "حضرت" is an honorific and "سعید" devotional framing; the events keep
    -- their names without them.
    local eid = holidays.forDay(1405, 1, 1, DEFAULT)
    local joined = titles(eid)
    h.ok(not string.find(joined, "حضرت"), `no honorific in: {joined}`)
    h.ok(string.find(joined, "عید فطر") ~= nil, `eid is named plainly: {joined}`)

    local ashura = holidays.forDay(1405, 4, 6, DEFAULT)
    h.ok(not string.find(titles(ashura), "حضرت"), "no honorific on ashura")
  end)

  h.describe("other countries' holidays do not become iranian days off", function()
    -- Afghan rows carry their own holiday flags. They must only count when
    -- Afghan events are switched on.
    local iranian, afghan = 0, 0
    for jm = 1, 12 do
      for jd = 1, jalali.monthLength(1405, jm) do
        if holidays.isHoliday(1405, jm, jd, DEFAULT) then
          iranian += 1
        end
        if holidays.isHoliday(1405, jm, jd, ALL) then
          afghan += 1
        end
      end
    end
    h.ok(afghan > iranian, `enabling afghan events adds days off ({iranian} -> {afghan})`)
  end)

  h.describe("ancient iranian festivals are available", function()
    -- Mehregan, 16 Mehr in the ancient set.
    local found = false
    for jd = 1, 30 do
      for _, o in holidays.forDay(1405, 7, jd, ALL) do
        if o.category == "ancient" then
          found = true
        end
      end
    end
    h.eq(found, true, "mehr carries ancient iranian occasions")
  end)

  h.describe("availability", function()
    h.eq(holidays.isAvailable(), true, "data loaded")
  end)
end
