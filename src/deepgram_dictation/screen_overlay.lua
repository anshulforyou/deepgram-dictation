-- What the user sees while grandma looks at the screen: a soft rose glow around the edges with
-- two threads of deep-rose yarn running round it, and the panel her answers appear in. Colours come from
-- the yarn in grandma's mascot. Neither ever takes focus; the glow lets clicks through.

local core = require("deepgram_dictation.core")

local M = {}

local function log(fmt, ...) print("[deepgram-dictation] " .. string.format(fmt, ...)) end

local function rgb(hex, alpha)
  return { red = tonumber(hex:sub(1, 2), 16) / 255, green = tonumber(hex:sub(3, 4), 16) / 255,
           blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = alpha or 1 }
end

M.ROSE_DEEP, M.ROSE, M.ROSE_LIGHT = "d2626f", "fa98a3", "feb1bb"
local PANEL_BG, PANEL_TEXT, PANEL_MUTED = "1d1a1c", "f4eef0", "a8999e"

local FPS = 30
local THREAD_LENGTH = 260 -- points
local THREAD_SPEED = 420 -- points per second
local BREATH_SECONDS = 1.8
local HAZE_LAYERS, HAZE_WIDTH, HAZE_ALPHA = 18, 90, 0.04 -- the glow reaches HAZE_WIDTH / 2 into the screen

local glow, glowTimer, panel, panelKeys, pendingCancel

-- Glow ---------------------------------------------------------------------------------------

local function glowElements(frame)
  local rect = { x = 0, y = 0, w = frame.w, h = frame.h }
  local radius = { xRadius = 12, yRadius = 12 }
  local perimeter = 2 * (frame.w + frame.h)
  local function edge(id, color, alpha, width, extra)
    local e = { id = id, type = "rectangle", action = "stroke", frame = rect, roundedRectRadii = radius,
                strokeColor = rgb(color, alpha), strokeWidth = width }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
  end
  local thread = { strokeDashPattern = { THREAD_LENGTH, perimeter / 2 - THREAD_LENGTH }, strokeCapStyle = "round" }
  -- Canvas can't blur, so the glow is many faint strokes: where they overlap, at the very edge,
  -- it is strongest, and it fades out towards the middle of the screen.
  local elements = {}
  for i = 1, HAZE_LAYERS do
    table.insert(elements, edge("haze" .. i, i <= HAZE_LAYERS / 2 and M.ROSE_DEEP or M.ROSE, HAZE_ALPHA,
      HAZE_WIDTH * i / HAZE_LAYERS))
  end
  table.insert(elements, edge("line", M.ROSE_LIGHT, 0.9, 3))
  table.insert(elements, edge("thread", M.ROSE_DEEP, 1, 6, thread))
  return elements
end

function M.showGlow(screen)
  M.hideGlow(0)
  local frame = screen:fullFrame()
  glow = hs.canvas.new(frame)
  glow:level(hs.canvas.windowLevels.overlay)
  glow:behavior({ "canJoinAllSpaces", "stationary" })
  glow:appendElements(glowElements(frame))
  glow:show(0.2)
  local started = hs.timer.secondsSinceEpoch()
  glowTimer = hs.timer.doEvery(1 / FPS, function()
    if not glow then return end
    local t = hs.timer.secondsSinceEpoch() - started
    local breath = 0.5 + 0.5 * math.sin(t * 2 * math.pi / BREATH_SECONDS)
    glow:alpha(0.75 + 0.25 * breath)
    glow["thread"].strokeDashPhase = -(t * THREAD_SPEED)
  end)
end

function M.hideGlow(fade)
  if glowTimer then glowTimer:stop() glowTimer = nil end
  if glow then
    local c = glow
    glow = nil
    c:hide(fade or 0.3)
    hs.timer.doAfter((fade or 0.3) + 0.1, function() c:delete() end)
  end
end

-- Panel --------------------------------------------------------------------------------------

local W, PAD = 440, 20
local HEADER = 22
local BODY_SIZE, LINE_SPACING = 14, 3

local function styled(text, size, color, weight, alignment)
  return hs.styledtext.new(text, {
    font = { name = weight == "bold" and ".AppleSystemUIFontBold" or ".AppleSystemUIFont", size = size },
    color = rgb(color),
    paragraphStyle = { lineSpacing = LINE_SPACING, alignment = alignment or "natural" },
  })
end

-- Height `text` needs at `width`. Canvas only measures a single line, so this wraps words the
-- way the text element will and counts the lines.
local function textHeight(c, text, width, isError)
  c:appendElements({ type = "text", text = "", frame = { x = 0, y = 0, w = width, h = 10 } })
  local color = isError and M.ROSE_LIGHT or PANEL_TEXT
  local function measure(s) return c:minimumTextSize(1, styled(s, BODY_SIZE, color)) end
  local lineH = measure("Ag").h
  local lines = 0
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    lines = lines + 1
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if line ~= "" and measure(candidate).w > width - 6 then
        lines = lines + 1
        line = word
      else
        line = candidate
      end
    end
  end
  c:removeElement(1)
  return math.ceil(lines * (lineH + LINE_SPACING)) + 4
end

function M.closePanel(fade)
  if panelKeys then panelKeys:stop() panelKeys = nil end
  -- A question closed any other way (the next dictation starting) counts as Esc.
  local cancel = pendingCancel
  pendingCancel = nil
  if cancel then log("card closed: replaced") end
  if panel then
    local c = panel
    panel = nil
    c:hide(fade or 0.15)
    hs.timer.doAfter(0.3, function() c:delete() end)
  end
  if cancel then cancel("replaced") end
end

-- Shows `text` next to the mouse, on whichever display it is on now. `note` is the small line in
-- the header ("Copied"). Closes on a click on the panel, on Esc, or when the next dictation starts.
-- With `keys` ({ onReturn, onEscape }) it asks: Return and Esc are answered here and never reach
-- the app underneath (so Return can't submit a form), and a click counts as Esc. `pictures`
-- ({ { path, caption } }) are shown under the text, so a file is seen before it is uploaded.
local THUMB, CAPTION = 84, 18
function M.showPanel(text, note, isError, keys, pictures)
  pictures = pictures or {}
  M.closePanel()
  local frame = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local body = styled(text, BODY_SIZE, isError and M.ROSE_LIGHT or PANEL_TEXT)
  local maxBody = math.floor(frame.h * 0.7) - HEADER - 3 * PAD
  local c = hs.canvas.new({ x = 0, y = 0, w = W, h = 100 })
  local bodyH = math.min(textHeight(c, text, W - 2 * PAD, isError), maxBody)
  local shelf = #pictures > 0 and (12 + THUMB + CAPTION) or 0
  local h = PAD + HEADER + 10 + bodyH + shelf + PAD
  c:size({ w = W, h = h })
  c:topLeft(core.panelOrigin(hs.mouse.absolutePosition(), W, h, frame))
  c:appendElements({
    { id = "bg", type = "rectangle", action = "strokeAndFill", roundedRectRadii = { xRadius = 14, yRadius = 14 },
      fillColor = rgb(PANEL_BG), strokeColor = rgb(M.ROSE, 0.55), strokeWidth = 1,
      frame = { x = 0.5, y = 0.5, w = W - 1, h = h - 1 }, trackMouseUp = true },
    { type = "circle", action = "fill", fillColor = rgb(M.ROSE), radius = 5,
      center = { x = PAD + 5, y = PAD + HEADER / 2 } },
    { type = "text", text = styled("grandma", 13, M.ROSE_LIGHT, "bold"),
      frame = { x = PAD + 16, y = PAD + 2, w = 200, h = HEADER } },
    { type = "text", text = styled(note or "", 12, PANEL_MUTED, nil, "right"),
      frame = { x = W - PAD - 200, y = PAD + 3, w = 200, h = HEADER } },
    { type = "text", text = body, frame = { x = PAD, y = PAD + HEADER + 10, w = W - 2 * PAD, h = bodyH } },
  })
  local slot = math.floor((W - 2 * PAD) / math.max(1, math.min(#pictures, 4)))
  for i, pic in ipairs(pictures) do
    if i > 4 then break end
    local x, y = PAD + (i - 1) * slot, PAD + HEADER + 10 + bodyH + 12
    local image = hs.image.imageFromPath(pic.path)
    if image then
      c:appendElements({ type = "image", image = image, imageScaling = "scaleProportionally",
                         frame = { x = x, y = y, w = math.min(slot - 10, THUMB * 1.9), h = THUMB } })
    end
    c:appendElements({ type = "text", text = styled(pic.caption or "", 11, PANEL_MUTED),
                       frame = { x = x, y = y + THUMB + 2, w = slot - 10, h = CAPTION } })
  end
  c:level(hs.canvas.windowLevels.floating)
  c:behavior({ "canJoinAllSpaces" })
  pendingCancel = keys and keys.onEscape
  -- `how` (return, esc, click; "replaced" when a new press closed it) goes to the callback and
  -- the console, so a card nobody answered can be told apart from one the user cancelled.
  local function answer(fn, how)
    pendingCancel = nil
    M.closePanel(0)
    if keys then log("card closed: %s", how) end
    if fn then fn(how) end
  end
  c:mouseCallback(function(_, message)
    if message == "mouseUp" then answer(keys and keys.onEscape, "click") end
  end)
  c:show(0.15)
  panel = c
  panelKeys = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local code = e:getKeyCode()
    if code == hs.keycodes.map.escape then
      answer(keys and keys.onEscape, "esc")
      return keys ~= nil
    end
    if keys and (code == hs.keycodes.map["return"] or code == hs.keycodes.map.padenter) then
      answer(keys.onReturn, "return")
      return true
    end
    return false
  end):start()
end

function M.teardown()
  M.hideGlow(0)
  M.closePanel()
end

return M
