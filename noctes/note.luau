--!nonstrict
-- One post-it, one widget instance. Add a second desktop widget for a second
-- note; each instance is bound to a note by its `key` setting.
--
-- Desktop widgets are background layer-shell surfaces: they take clicks but
-- never keyboard focus. So the paper is a single click target that hands the
-- note to the panel, which is the surface that can take typing.
--
-- The paper is drawn out of plain flex nodes, because the ui vocabulary has no
-- z-stacking: the drop shadow is an L of translucent boxes along the bottom and
-- right edges, and the folded corner is a staircase of 3px boxes whose leading
-- step is lighter, which reads as the lit edge of a lifted corner.

local colors = require("./colors.luau")

local FOLD_STEP = 1
local SHADOW_WIDTH = 4
-- Bottom corners only: a sheet is lifted from its bottom edge, so a dog-ear at
-- the top reads as a rendering mistake rather than a fold.
local FOLD_CORNERS = { "bottom_right", "bottom_left" }
local TAPE_SPOTS = { "none", "left", "center", "right", "center" }

local noteKey = noctalia.string.trim(noctalia.getConfig("key") or "")
local colorSetting = noctalia.getConfig("color") or "auto"
local foldSetting = noctalia.getConfig("fold") or "auto"
local tapeSetting = noctalia.getConfig("tape") or "auto"
local paperWidth = math.max(80, math.floor(tonumber(noctalia.getConfig("paper_width")) or 220))
local paperHeight = math.max(60, math.floor(tonumber(noctalia.getConfig("paper_height")) or 200))
local fontSize = math.max(8, math.floor(tonumber(noctalia.getConfig("font_size")) or 13))
local maxLines = math.max(1, math.floor(tonumber(noctalia.getConfig("max_lines")) or 14))
local showTitle = noctalia.getConfig("show_title") ~= false
local paperOpacityOverride = tonumber(noctalia.getConfig("opacity_override")) or 0
local paperOpacityDefault = tonumber(noctalia.state.get("noctes.paperOpacity")) or 0.96

local function paperOpacity()
  if paperOpacityOverride > 0 then
    return paperOpacityOverride
  end
  return paperOpacityDefault
end
local withShadow = noctalia.getConfig("shadow") ~= false
-- Tri-state: this sheet can opt in or out, or leave it to the plugin-wide
-- switch. The plugin-wide value arrives as state rather than getConfig, because
-- getConfig here reads this widget's own settings, and because state makes the
-- switch take effect the moment it is toggled.
local themeChoice = noctalia.getConfig("use_theme_colors") or "inherit"
local themeColorsDefault = noctalia.state.get("noctes.themeColors") == true

local function useThemeColors()
  if themeChoice == "on" then
    return true
  end
  if themeChoice == "off" then
    return false
  end
  return themeColorsDefault
end

-- Everything generated (paper tint, fold corner, tape) hangs off a seed, so two
-- post-its differ from each other while each one stays the same over time. The
-- key is the stable identity when there is one; otherwise the note's id at
-- least separates one keyless note from another.
local function seedOf(note)
  if noteKey ~= "" then
    return noteKey
  end
  if note ~= nil then
    return note.id
  end
  return "default"
end

local fontFamily = nil
local fontPath = noctalia.string.trim(noctalia.getConfig("font_path") or "")
if fontPath ~= "" then
  local family, err = noctalia.loadFont(fontPath)
  if family ~= nil then
    fontFamily = family
  else
    noctalia.log("noctes: font load failed: " .. tostring(err))
  end
end

local notes = {}
local ready = false

-- What this sheet last drew. Every note edit republishes the whole list to
-- every sheet, so without this each keystroke's autosave would rebuild the tree
-- of every post-it on the desktop, not just the one being written.
local lastDrawn = nil

local function signatureOf(note)
  if note == nil then
    return "-|" .. tostring(ready)
  end
  return table.concat({
    note.id, note.key or "", note.title or "", note.content or "",
    note.color or "", tostring(ready),
  }, "\30")
end

local function currentNote()
  for _, note in ipairs(notes) do
    if (note.key or "") == noteKey then
      return note
    end
  end
  return nil
end

-- The widget setting overrides the note; "" at either level means dynamic, and
-- colors.paper turns that into a palette role or a generated paper.
local function resolvedColor(note)
  if colorSetting ~= "auto" and colors.isKnown(colorSetting) then
    return colorSetting
  end
  return note ~= nil and note.color or ""
end

local function resolvedFold(seed)
  if foldSetting == "none" then
    return nil
  end
  if foldSetting ~= "auto" then
    return foldSetting
  end
  return colors.pick(FOLD_CORNERS, seed, "fold")
end

local function resolvedTape(seed)
  if tapeSetting == "none" then
    return nil
  end
  if tapeSetting ~= "auto" then
    return tapeSetting
  end
  local spot = colors.pick(TAPE_SPOTS, seed, "tape")
  return spot ~= "none" and spot or nil
end

-- A small signed jitter from the seed, so no two sheets share a fold size or a
-- tape width exactly.
local function jitter(seed, salt, spread)
  return (colors.hash(salt .. "|" .. seed) % (spread * 2 + 1)) - spread
end

-- ── Paper parts ─────────────────────────────────────────────────────────────

-- A staircase triangle in a bottom corner, widening as it goes down. Each row
-- is one step tall; the first step-sized box of the row is the crease, the rest
-- is the shaded underside.
--
-- Off by default, and honestly so: this vocabulary has no rotation, no clipping
-- and no vector primitive, so a diagonal can only be a stack of rectangles. At
-- one pixel per step it is as smooth as it gets, and the host still rotates the
-- whole sheet afterwards, which resamples the staircase into visible hatching.
-- A dog-ear that reads as a rendering artifact is worse than no dog-ear.
local function foldRows(corner, size)
  local steps = math.max(2, math.floor(size / FOLD_STEP))
  local rows = {}
  local atRight = corner == "bottom_right"

  for i = 1, steps do
    local bodyWidth = math.max(FOLD_STEP, i * FOLD_STEP - FOLD_STEP)
    local edge = ui.box({ width = FOLD_STEP, height = FOLD_STEP, fill = colors.FOLD_EDGE })
    local body = ui.box({ width = bodyWidth, height = FOLD_STEP, fill = colors.FOLD_SHADE })

    local cells
    if atRight then
      cells = { ui.spacer({ flexGrow = 1 }), edge, body }
    else
      cells = { body, edge, ui.spacer({ flexGrow = 1 }) }
    end
    table.insert(rows, ui.row({ gap = 0, height = FOLD_STEP }, cells))
  end
  return rows
end

-- A strip of matte tape near the top edge.
local function tapeRow(spot, seed)
  local width = 62 + jitter(seed, "tapew", 9)
  local inset = 14 + jitter(seed, "tapex", 8)
  local strip = ui.column({ gap = 0, width = width, height = 13, align = "stretch" }, {
    ui.box({ height = 1, fill = colors.TAPE_EDGE }),
    ui.box({ flexGrow = 1, fill = colors.TAPE }),
    ui.box({ height = 1, fill = colors.TAPE_EDGE }),
  })

  local cells
  if spot == "left" then
    cells = { ui.spacer({ width = inset }), strip, ui.spacer({ flexGrow = 1 }) }
  elseif spot == "right" then
    cells = { ui.spacer({ flexGrow = 1 }), strip, ui.spacer({ width = inset }) }
  else
    cells = { ui.spacer({ flexGrow = 1 }), strip, ui.spacer({ flexGrow = 1 }) }
  end
  return ui.row({ gap = 0, height = 20, align = "center" }, cells)
end

-- ── Actions ─────────────────────────────────────────────────────────────────

local function openPanel()
  -- togglePanel is the only entry point, so opening an already-open panel would
  -- close it. The panel publishes its own state for exactly this check.
  if noctalia.state.get("noctes.panelOpen") ~= true then
    noctalia.togglePanel("remo/noctes:panel")
  end
end

local function onPaperClick()
  local note = currentNote()
  if note == nil then
    -- The service creates the note for this key and selects it; the panel opens
    -- on it, so a blank post-it is one click away from being written.
    noctalia.state.set("noctes.cmd", { op = "ensure", key = noteKey })
  else
    noctalia.state.set("noctes.editing", note.id)
  end
  openPanel()
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function render()
  local note = currentNote()
  lastDrawn = signatureOf(note)
  local seed = seedOf(note)
  local paper, ink, inkMuted, edge = colors.paper(resolvedColor(note), seed, useThemeColors())
  local fold = resolvedFold(seed)
  local tape = resolvedTape(seed)

  local body = {}

  if tape ~= nil then
    table.insert(body, tapeRow(tape, seed))
  end

  local foldSize = math.min(44, math.max(16, math.floor(paperWidth * 0.15) + jitter(seed, "fold", 5)))

  local text = {}
  local hasTitle = note ~= nil and (note.title or "") ~= ""
  if showTitle and hasTitle then
    table.insert(text, ui.label({
      text = note.title,
      fontSize = fontSize + 3,
      fontWeight = "bold",
      fontFamily = fontFamily,
      color = ink,
      maxLines = 2,
    }))
  end

  local content
  if not ready then
    content = noctalia.tr("note.loading")
  elseif note == nil then
    content = noctalia.tr("note.empty_hint")
  elseif noctalia.string.trim(note.content or "") == "" then
    content = noctalia.tr("note.empty_hint")
  else
    content = note.content
  end
  local isPlaceholder = note == nil or noctalia.string.trim(note.content or "") == ""

  table.insert(text, ui.label({
    text = content,
    fontSize = fontSize,
    fontFamily = fontFamily,
    color = isPlaceholder and inkMuted or ink,
    maxLines = maxLines,
    flexGrow = 1,
  }))

  table.insert(body, ui.column({
    gap = 6,
    paddingH = 14,
    paddingV = tape ~= nil and 6 or 14,
    flexGrow = 1,
    align = "stretch",
  }, text))

  if fold ~= nil then
    for _, row in ipairs(foldRows(fold, foldSize)) do
      table.insert(body, row)
    end
  end

  -- Paper corners stay nearly square: a rounded card reads as UI, a sharp one
  -- reads as paper.
  local sheetWidth = withShadow and (paperWidth - SHADOW_WIDTH) or paperWidth
  local sheetHeight = withShadow and (paperHeight - SHADOW_WIDTH) or paperHeight

  local sheet = ui.column({
    width = sheetWidth,
    height = sheetHeight,
    gap = 0,
    radius = 2,
    fill = colors.withAlpha(paper, paperOpacity()),
    border = edge,
    borderWidth = edge ~= nil and 1 or nil,
    align = "stretch",
    onClick = onPaperClick,
  }, body)

  if not withShadow then
    desktopWidget.render(sheet)
    return
  end

  -- The shadow is one softened box down the right edge and one along the
  -- bottom. Stacked hard-edged bands were the obvious way to fake a falloff and
  -- the wrong one: the host rotates the whole sheet, and rotating three crisp
  -- 3px stripes resamples them into a staircase. A single box with a wide
  -- `softness` is one edge for the rotation to deal with, and the feathering
  -- does the falloff that the bands were imitating.
  local armLength = sheetHeight - SHADOW_WIDTH

  desktopWidget.render(ui.column({ gap = 0, width = paperWidth, height = paperHeight }, {
    ui.row({ gap = 0, height = sheetHeight }, {
      sheet,
      ui.column({ gap = 0, width = SHADOW_WIDTH, height = sheetHeight }, {
        ui.spacer({ width = SHADOW_WIDTH, height = SHADOW_WIDTH }),
        ui.box({
          width = SHADOW_WIDTH,
          height = armLength,
          fill = colors.SHADOW,
          softness = SHADOW_WIDTH,
        }),
      }),
    }),
    ui.row({ gap = 0, height = SHADOW_WIDTH }, {
      ui.spacer({ width = SHADOW_WIDTH, height = SHADOW_WIDTH }),
      ui.box({
        width = paperWidth - SHADOW_WIDTH,
        height = SHADOW_WIDTH,
        fill = colors.SHADOW,
        softness = SHADOW_WIDTH,
      }),
    }),
  }))
end

noctalia.state.watch("noctes.notes", function(value)
  notes = type(value) == "table" and value or {}
  if signatureOf(currentNote()) == lastDrawn then
    return
  end
  render()
end)

noctalia.state.watch("noctes.paperOpacity", function(value)
  local next = tonumber(value) or 0.96
  if next == paperOpacityDefault then
    return
  end
  paperOpacityDefault = next
  render()
end)

noctalia.state.watch("noctes.ready", function(value)
  ready = value == true
  render()
end)

noctalia.state.watch("noctes.themeColors", function(value)
  -- The service republishes this on its tick, so a sheet that started before
  -- the first publish still picks it up. Guard on change, or that heartbeat
  -- would redraw every sheet every couple of seconds.
  local next = value == true
  if next == themeColorsDefault then
    return
  end
  themeColorsDefault = next
  render()
end)

local initialNotes = noctalia.state.get("noctes.notes")
notes = type(initialNotes) == "table" and initialNotes or {}
ready = noctalia.state.get("noctes.ready") == true
render()
