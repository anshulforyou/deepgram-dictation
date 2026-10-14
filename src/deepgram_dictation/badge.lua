-- The badge: a small dark pill with grandma's yarn moving in it, in place of status words.
-- Listening is a strand of yarn waving, transcribing winds it into a ball, filling knits one
-- stitch per step, noting drops a stitch onto the ball, and a slow connection lets the strand
-- sag. While she thinks the pill rounds into a bubble with grandma herself in it, knitting: her
-- mascot (scripts/make_grandma_badge.py). Messages that ask something of the user (errors, "No
-- speech detected") stay as words, in hs.alert.
--
-- Each animation is a looping GIF that macOS plays by itself (scripts/render_badges.sh draws
-- them): no Lua runs per frame. Drawing live from Lua cost 12 to 35% of a core; a GIF ~8%,
-- and only while it shows. Lua only runs for a moment when the badge changes: it appears
-- growing in, fades out shrinking, and from one kind to the next the pill morphs to the new
-- shape while what is in it crossfades. Settled, the canvas holds two elements, because a GIF
-- makes hs.canvas redraw every element each frame. It never takes focus or clicks, and hides
-- at once when the screen is about to be captured.

local M = {}

local DIR = hs.configdir .. "/deepgram_dictation/badges/"
local H = 34
local WIDTH = { listening = 104, looking = 104, transcribing = 104, thinking = 92, noting = 96, slow = 104,
                filling = 196 }
local HEIGHT = { thinking = 92 } -- everything else is a pill H tall
local MASCOT = { thinking = "grandma" } -- grandma herself, in a bubble
local MASCOT_SIZE = 84
M.KINDS = WIDTH
local INSET_X, INSET_Y = 10, 3 -- where a GIF sits in the pill (scripts/badge_frames.lua INSET)
local BG, ROSE, LIGHT = "1d1a1c", "fa98a3", "feb1bb"
local STITCH, MAX_STITCHES = 10, 8 -- spacing in points, and how many show before the row scrolls
local MORPH, APPEAR, VANISH = 0.35, 0.15, 0.18 -- seconds
local TICK = 1 / 50

local canvas, kind, step, anim, suspended
local gifs = {}

local function rgb(hex, alpha)
  return { red = tonumber(hex:sub(1, 2), 16) / 255, green = tonumber(hex:sub(3, 4), 16) / 255,
           blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = alpha or 1 }
end

local function gif(name)
  if gifs[name] == nil then gifs[name] = hs.image.imageFromPath(DIR .. name .. ".gif") or false end
  return gifs[name] or nil
end

local function clamp(x) return math.max(0, math.min(1, x)) end
local function easeOut(x) return 1 - (1 - x) ^ 3 end
local function backOut(x) local c = 1.6 return 1 + (c + 1) * (x - 1) ^ 3 + c * (x - 1) ^ 2 end

local function size(k) return WIDTH[k], HEIGHT[k] or H end

local function pill(x, y, w, h)
  local r = math.min(w, h) / 2
  return { type = "rectangle", action = "strokeAndFill", roundedRectRadii = { xRadius = r, yRadius = r },
           frame = { x = x + 0.75, y = y + 0.75, w = w - 1.5, h = h - 1.5 }, fillColor = rgb(BG),
           strokeColor = rgb(ROSE, 0.85), strokeWidth = 1.5 }
end

-- A knitted stitch, a V, as in scripts/badge_frames.lua.
local function stitch(x, y)
  return { type = "segments", action = "stroke", closed = false, strokeColor = rgb(ROSE), strokeWidth = 2,
           strokeCapStyle = "round", strokeJoinStyle = "round",
           coordinates = { { x = x - 3.15, y = y - 4.5 }, { x = x, y = y + 2.7 }, { x = x + 3.15, y = y - 4.5 } } }
end

-- Filling's stitches and "Esc to stop", flattened into one image (with the pill under them when
-- `withPill`), so the settled canvas stays at two elements.
local function fillingStill(withPill)
  local w = WIDTH.filling
  local shown = math.min(step or 0, MAX_STITCHES)
  local still = withPill and { pill(0, 0, w, H) } or {}
  for i = 1, shown do table.insert(still, stitch(14 + (i - 1) * STITCH, H / 2 + 1)) end
  table.insert(still, { type = "text", frame = { x = w - 92, y = H / 2 - 8, w = 80, h = 16 },
    text = hs.styledtext.new("Esc to stop", { font = { name = ".AppleSystemUIFont", size = 11 },
      color = rgb(LIGHT, 0.75), paragraphStyle = { alignment = "right" } }) })
  local flat = hs.canvas.new({ x = 0, y = 0, w = w, h = H })
  flat:replaceElements(still)
  local image = flat:imageFromCanvas()
  flat:delete()
  return image
end

local function image(img, frame, alpha)
  return { type = "image", image = img, imageAnimates = true, imageScaling = "scaleProportionally",
           imageAlpha = alpha or 1, frame = frame }
end

-- What sits in the pill for kind `k`, with its box's top left at (x, y), faded to `alpha` and
-- scaled by `scale` about the box's centre. `still` is filling's flattened image.
local function content(k, x, y, alpha, scale, still)
  local w, h = size(k)
  scale = scale or 1
  local function at(fx, fy, fw, fh)
    return { x = x + w / 2 + (fx - w / 2) * scale, y = y + h / 2 + (fy - h / 2) * scale,
             w = fw * scale, h = fh * scale }
  end
  if k == "filling" then
    local cx = 14 + math.min(step or 0, MAX_STITCHES) * STITCH + 10
    return { image(still, at(0, 0, w, h), alpha),
             image(gif("needles"), at(cx - 20, INSET_Y, 40, h - 2 * INSET_Y), alpha) }
  elseif MASCOT[k] then
    local m = MASCOT_SIZE
    return { image(gif(MASCOT[k]), at((w - m) / 2, (h - m) / 2, m, m), alpha) }
  end
  return { image(gif(k), at(INSET_X, INSET_Y, w - 2 * INSET_X, h - 2 * INSET_Y), alpha) }
end

local function place(w, h)
  local screen = hs.screen.mainScreen() or hs.screen.primaryScreen()
  local f = screen:frame()
  -- Where hs.alert put the old words: the middle of the screen with the focused window.
  return { x = math.floor(f.x + (f.w - w) / 2), y = math.floor(f.y + (f.h - h) / 2), w = w, h = h }
end

local function stopAnim()
  if anim then anim:stop() anim = nil end
end

-- The badge at rest: two elements.
local function settle()
  stopAnim()
  local w, h = size(kind)
  canvas:frame(place(w, h))
  canvas:alpha(1)
  if kind == "filling" then
    canvas:replaceElements({ image(fillingStill(true), { x = 0, y = 0, w = w, h = h }),
                             content("filling", 0, 0, 1, 1)[2] })
  else
    local list = content(kind, 0, 0, 1, 1)
    table.insert(list, 1, pill(0, 0, w, h))
    canvas:replaceElements(list)
  end
end

-- Runs `draw(p)` with p going 0 to 1 over `seconds`, then `finish`.
local function animate(seconds, draw, finish)
  stopAnim()
  local start = hs.timer.secondsSinceEpoch()
  local function tick()
    local p = clamp((hs.timer.secondsSinceEpoch() - start) / seconds)
    draw(p)
    if p >= 1 then stopAnim() finish() end
  end
  anim = hs.timer.doEvery(TICK, tick)
  tick()
end

-- From `from` (a kind, or nil when the badge was hidden) to the current kind: the pill changes
-- shape while the old content fades out and the new fades in. Grandma pops in a little.
local function transition(from)
  local to = kind
  local w1, h1 = size(to)
  local w0, h0
  if from then w0, h0 = size(from) else w0, h0 = w1 * 0.85, h1 * 0.85 end
  local W, Hh = math.max(w0, w1), math.max(h0, h1)
  canvas:frame(place(W, Hh))
  local oldStill = from == "filling" and fillingStill(false) or nil
  local newStill = to == "filling" and fillingStill(false) or nil
  local pop = MASCOT[to] ~= nil
  animate(from and MORPH or APPEAR, function(p)
    local e = easeOut(p)
    local w, h = w0 + (w1 - w0) * e, h0 + (h1 - h0) * e
    local list = { pill((W - w) / 2, (Hh - h) / 2, w, h) }
    if from then
      local a = 1 - clamp(p / 0.45)
      if a > 0 then
        for _, el in ipairs(content(from, (W - w0) / 2, (Hh - h0) / 2, a, 1, oldStill)) do
          table.insert(list, el)
        end
      end
    end
    local q = from and clamp((p - 0.3) / 0.7) or p
    local scale = pop and (0.6 + 0.4 * backOut(q)) or (from and 1 or 0.85 + 0.15 * e)
    for _, el in ipairs(content(to, (W - w1) / 2, (Hh - h1) / 2, from and q or 1, scale, newStill)) do
      table.insert(list, el)
    end
    canvas:alpha(from and 1 or 0.4 + 0.6 * e)
    canvas:replaceElements(list)
  end, settle)
end

-- Makes the canvas and loads the GIFs, so the first show costs nothing.
function M.setup()
  if canvas then return end
  canvas = hs.canvas.new({ x = 0, y = 0, w = WIDTH.listening, h = H })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  canvas:clickActivating(false)
  for name in pairs(WIDTH) do if name ~= "filling" then gif(MASCOT[name] or name) end end
  gif("needles")
end

-- Shows the badge for `newKind` (a key of M.KINDS); for "filling", `n` is the step she is on.
function M.show(newKind, n)
  if not WIDTH[newKind] then return end
  if not canvas then M.setup() end
  suspended = nil
  local from = canvas:isShowing() and kind or nil
  local was = step
  kind, step = newKind, n or 0
  if from == newKind then
    -- The same kind again: leave it be, unless filling moved on a step.
    if newKind == "filling" and step ~= was and not anim then settle() end
    return
  end
  if not canvas:isShowing() then canvas:show() end
  transition(from)
end

-- Hides it, fading out and shrinking a little. `now` hides it at once: a screen capture needs it
-- gone. The GIFs go too, so a hidden badge isn't animating.
function M.hide(now)
  if not (canvas and canvas:isShowing()) then kind = nil return end
  local was = kind
  kind = nil
  local function gone()
    stopAnim()
    canvas:hide()
    canvas:alpha(1)
    canvas:replaceElements({ pill(0, 0, WIDTH.listening, H) }) -- hs.canvas won't take an empty list
  end
  if now or not was then return gone() end
  local w, h = size(was)
  local f = canvas:frame()
  local x, y = (f.w - w) / 2, (f.h - h) / 2
  local still = was == "filling" and fillingStill(false) or nil
  animate(VANISH, function(p)
    local s = 1 - 0.12 * easeOut(p)
    local list = { pill(x + w * (1 - s) / 2, y + h * (1 - s) / 2, w * s, h * s) }
    for _, el in ipairs(content(was, x, y, 1, s, still)) do table.insert(list, el) end
    canvas:alpha(1 - p)
    canvas:replaceElements(list)
  end, gone)
end

function M.kind() return kind end

-- Takes the badge off screen for a moment, with no animation, while grandma captures the screen
-- during a fill; resume puts it back as it was unless it was hidden or changed meanwhile.
function M.suspend()
  if canvas and canvas:isShowing() and not anim then
    suspended = kind
    canvas:hide()
  end
end

function M.resume()
  local was = suspended
  suspended = nil
  if was and canvas and kind == was and not canvas:isShowing() then canvas:show() end
end

function M.teardown()
  M.hide(true)
  if canvas then canvas:delete() canvas = nil end
  gifs = {}
end

return M
