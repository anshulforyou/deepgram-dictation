-- The badge: a small dark pill with grandma's yarn moving in it, in place of status words.
-- Listening is a strand of yarn waving, transcribing winds it into a ball, thinking is her
-- needles tapping beside the ball, filling knits one stitch per step, noting drops a stitch
-- onto the ball, and a slow connection lets the strand sag. Messages that ask something of
-- the user (errors, "No speech detected") stay as words, in hs.alert.
--
-- Each animation is a looping GIF that macOS plays by itself (scripts/render_badges.sh draws
-- them): no Lua runs per frame. Drawing live from Lua cost 12 to 35% of a core; a GIF ~8%,
-- and only while it shows. The pill is made once and the GIFs loaded at setup, so pressing
-- the hotkey shows it in the same frame. It never takes focus or clicks, and hides at once
-- when the screen is captured.

local M = {}

local DIR = hs.configdir .. "/deepgram_dictation/badges/"
local H = 34
local WIDTH = { listening = 104, looking = 104, transcribing = 104, thinking = 112, noting = 96, slow = 104,
                filling = 196 }
M.KINDS = WIDTH
local INSET_X, INSET_Y = 10, 3 -- where a GIF sits in the pill (scripts/badge_frames.lua INSET)
local BG, ROSE, LIGHT = "1d1a1c", "fa98a3", "feb1bb"
local STITCH, MAX_STITCHES = 10, 8 -- spacing in points, and how many show before the row scrolls

local canvas, kind, step
local gifs = {}

local function rgb(hex, alpha)
  return { red = tonumber(hex:sub(1, 2), 16) / 255, green = tonumber(hex:sub(3, 4), 16) / 255,
           blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = alpha or 1 }
end

local function gif(name)
  if gifs[name] == nil then gifs[name] = hs.image.imageFromPath(DIR .. name .. ".gif") or false end
  return gifs[name] or nil
end

local function pill(w)
  return { type = "rectangle", action = "strokeAndFill", roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
           frame = { x = 0.75, y = 0.75, w = w - 1.5, h = H - 1.5 }, fillColor = rgb(BG),
           strokeColor = rgb(ROSE, 0.85), strokeWidth = 1.5 }
end

local function animation(name, frame)
  return { type = "image", image = gif(name), imageAnimates = true, imageScaling = "scaleProportionally",
           frame = frame }
end

-- A knitted stitch, a V, as in scripts/badge_frames.lua.
local function stitch(x, y)
  return { type = "segments", action = "stroke", closed = false, strokeColor = rgb(ROSE), strokeWidth = 2,
           strokeCapStyle = "round", strokeJoinStyle = "round",
           coordinates = { { x = x - 3.15, y = y - 4.5 }, { x = x, y = y + 2.7 }, { x = x + 3.15, y = y - 4.5 } } }
end

-- Filling: one stitch per step, her needles at the end of the row, and how to stop her. The GIF
-- makes the canvas redraw every element each frame, and hs.canvas reads every attribute of every
-- element on each redraw (8 elements cost ~20% of a core), so everything that only changes per
-- step is flattened into one image.
local function fillingElements(w)
  local shown = math.min(step, MAX_STITCHES)
  local still = { pill(w) }
  for i = 1, shown do table.insert(still, stitch(14 + (i - 1) * STITCH, H / 2 + 1)) end
  table.insert(still, { type = "text", frame = { x = w - 92, y = H / 2 - 8, w = 80, h = 16 },
    text = hs.styledtext.new("Esc to stop", { font = { name = ".AppleSystemUIFont", size = 11 },
      color = rgb(LIGHT, 0.75), paragraphStyle = { alignment = "right" } }) })
  local flat = hs.canvas.new({ x = 0, y = 0, w = w, h = H })
  flat:replaceElements(still)
  local image = flat:imageFromCanvas()
  flat:delete()
  local cx = 14 + shown * STITCH + 10
  return { { type = "image", image = image, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = w, h = H } },
           animation("needles", { x = cx - 20, y = INSET_Y, w = 40, h = H - 2 * INSET_Y }) }
end

local function elements()
  local w = WIDTH[kind]
  if kind == "filling" then return fillingElements(w) end
  return { pill(w), animation(kind, { x = INSET_X, y = INSET_Y, w = w - 2 * INSET_X, h = H - 2 * INSET_Y }) }
end

local function place(w)
  local screen = hs.screen.mainScreen() or hs.screen.primaryScreen()
  local f = screen:frame()
  -- Where hs.alert put the old words: the middle of the screen with the focused window.
  return { x = math.floor(f.x + (f.w - w) / 2), y = math.floor(f.y + (f.h - H) / 2), w = w, h = H }
end

-- Makes the pill and loads the GIFs, so the first show costs nothing.
function M.setup()
  if canvas then return end
  canvas = hs.canvas.new({ x = 0, y = 0, w = WIDTH.listening, h = H })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  canvas:clickActivating(false)
  for name in pairs(WIDTH) do if name ~= "filling" then gif(name) end end
  gif("needles")
end

-- Shows the badge for `newKind` (a key of M.KINDS); for "filling", `n` is the step she is on.
function M.show(newKind, n)
  if not WIDTH[newKind] then return end
  if not canvas then M.setup() end
  local same = newKind == kind and newKind ~= "filling"
  kind, step = newKind, n or 0
  if same and canvas:isShowing() then return end -- leave a running animation alone
  canvas:frame(place(WIDTH[kind]))
  canvas:replaceElements(elements())
  if not canvas:isShowing() then canvas:show() end
end

-- Hides it at once. No fade: a fade still running when the next dictation shows the badge would
-- hide it again, and a screen capture needs it gone now. The GIF goes too, so a hidden badge
-- isn't animating.
function M.hide()
  kind = nil
  if canvas and canvas:isShowing() then
    canvas:hide()
    canvas:replaceElements({ pill(WIDTH.listening) })
  end
end

function M.kind() return kind end

function M.teardown()
  M.hide()
  if canvas then canvas:delete() canvas = nil end
  gifs = {}
end

return M
