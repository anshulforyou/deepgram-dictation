-- Draws the badge animations frame by frame, for scripts/render_badges.sh to turn into the GIFs
-- in src/deepgram_dictation/badges/. Run inside Hammerspoon (it draws with hs.canvas). Live
-- drawing from Lua costs 12 to 35% of a core at 24 fps; a GIF macOS plays itself costs ~8%.
--
-- Every animation loops in LOOP seconds, so each speed below is a whole number of turns per loop.
-- Coordinates are in the badge's points (WIDTH x H); the GIF is the part inside INSET, which
-- sits wholly inside the pill's rounded ends.

local M = {}

M.LOOP, M.FPS, M.H = 2.4, 20, 34
M.WIDTH = { listening = 104, looking = 104, transcribing = 104, noting = 96, slow = 104, needles = 40 }
M.INSET = { x = 10, y = 3 } -- trimmed from each side (only y for needles, which sit mid-pill)
M.BG = "1d1a1c"
local ROSE, DEEP, LIGHT, WOOD = "fa98a3", "d2626f", "feb1bb", "e2b68c" -- WOOD: her needles, as in the mascot
local H, TAU = M.H, 2 * math.pi

local function rgb(hex, alpha)
  return { red = tonumber(hex:sub(1, 2), 16) / 255, green = tonumber(hex:sub(3, 4), 16) / 255,
           blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = alpha or 1 }
end

-- Angular speed for `turns` whole turns per loop.
local function per(turns) return turns * TAU / M.LOOP end

local function ease(x) x = math.max(0, math.min(1, x)) return x * x * (3 - 2 * x) end

-- A strand of yarn from x0 to x1 around y: `waves` waves along it, moving with `phase`,
-- pinned at both ends, and sagging by `sag` in the middle.
local function strand(x0, x1, y, amp, phase, waves, color, width, sag)
  local points, n = {}, 28
  for i = 0, n do
    local u = i / n
    local pin = math.sin(math.pi * u)
    table.insert(points, { x = x0 + (x1 - x0) * u,
                           y = y + amp * pin * math.sin(TAU * waves * u - phase) + (sag or 0) * pin })
  end
  return { type = "segments", coordinates = points, action = "stroke", closed = false,
           strokeColor = color, strokeWidth = width or 2.4, strokeCapStyle = "round", strokeJoinStyle = "round" }
end

-- A ball of yarn: rose, with three deep-rose wraps round it (great circles seen at a tilt)
-- turned by `turn` radians.
local function ball(list, cx, cy, r, turn)
  table.insert(list, { type = "circle", center = { x = cx, y = cy }, radius = r, action = "fill",
                       fillColor = rgb(ROSE) })
  for i, tilt in ipairs({ 0, 60, 120 }) do
    local a = math.rad(tilt) + turn
    local squash = 0.32 + 0.12 * i
    local points = {}
    for j = 0, 24 do
      local u = j / 24 * math.pi -- the near half of the wrap only
      local x, y = r * 0.92 * math.cos(u), r * 0.92 * squash * math.sin(u)
      table.insert(points, { x = cx + x * math.cos(a) - y * math.sin(a), y = cy + x * math.sin(a) + y * math.cos(a) })
    end
    table.insert(list, { type = "segments", coordinates = points, action = "stroke", closed = false,
                         strokeColor = rgb(DEEP), strokeWidth = 1.2, strokeCapStyle = "round" })
  end
end

-- One of her knitting needles, from its knob at (x0, y0) to its tip at (x1, y1), turned by
-- `angle` (radians) about (px, py).
local function needle(list, x0, y0, x1, y1, px, py, angle)
  local function turn(x, y)
    local dx, dy = x - px, y - py
    return px + dx * math.cos(angle) - dy * math.sin(angle), py + dx * math.sin(angle) + dy * math.cos(angle)
  end
  local ax, ay = turn(x0, y0)
  local bx, by = turn(x1, y1)
  table.insert(list, { type = "segments", coordinates = { { x = ax, y = ay }, { x = bx, y = by } },
                       action = "stroke", strokeColor = rgb(WOOD), strokeWidth = 2.2, strokeCapStyle = "round" })
  table.insert(list, { type = "circle", center = { x = ax, y = ay }, radius = 2.4, action = "fill",
                       fillColor = rgb(DEEP) })
end

-- Her two needles held as she knits: tips crossing just above (cx, cy), knobs out and down,
-- `half` wide. The right one dips as each stitch is made (`dip`, 0 to 1), the left one answers.
local function needles(list, cx, cy, half, dip)
  needle(list, cx - half, cy + 3, cx + 4, cy - 6, cx + 4, cy - 6, math.rad(-6 * dip))
  needle(list, cx + half, cy + 3, cx - 4, cy - 6, cx - 4, cy - 6, math.rad(-9 * dip))
end

-- The sparkles around her in the mascot: a four-pointed star.
local function sparkle(list, x, y, size, alpha)
  if size <= 0.2 then return end
  local k = size * 0.28
  table.insert(list, { type = "segments", closed = true, action = "fill", fillColor = rgb(LIGHT, alpha),
    coordinates = { { x = x, y = y - size }, { x = x + k, y = y - k }, { x = x + size, y = y },
                    { x = x + k, y = y + k }, { x = x, y = y + size }, { x = x - k, y = y + k },
                    { x = x - size, y = y }, { x = x - k, y = y - k } } })
end

-- A knitted stitch: a V, grown in by `g` (0 to 1). Also drawn live by badge.lua.
function M.stitch(list, x, y, g, color, size)
  local s = (size or 4.5) * ease(g)
  if s <= 0 then return end
  table.insert(list, { type = "segments", action = "stroke", closed = false, strokeColor = color or rgb(ROSE),
    strokeWidth = size and 1.6 or 2, strokeCapStyle = "round", strokeJoinStyle = "round",
    coordinates = { { x = x - s * 0.7, y = y - s }, { x = x, y = y + s * 0.6 }, { x = x + s * 0.7, y = y - s } } })
end

local FRAMES = {}

-- A strand of yarn waving: she is listening.
function FRAMES.listening(t, w)
  return { strand(16, w - 16, H / 2, 5 + 1.5 * math.sin(t * per(1)), t * per(2), 2, rgb(ROSE)) }
end

-- Fn+Control held: the same strand in her lighter yarn, with her sparkles.
function FRAMES.looking(t, w)
  local list = { strand(20, w - 20, H / 2, 5 + 1.5 * math.sin(t * per(1)), t * per(2), 2, rgb(LIGHT)) }
  sparkle(list, 14, 9, 2.6 * (0.5 + 0.5 * math.sin(t * per(2))), 0.9)
  sparkle(list, w - 14, H - 9, 2.6 * (0.5 + 0.5 * math.sin(t * per(2) + 2)), 0.9)
  return list
end

-- The strand flows into a turning ball: the words are being written down.
function FRAMES.transcribing(t, w)
  local list = { strand(14, w - 32, H / 2, 3, t * per(3), 2.5, rgb(ROSE), 2) }
  ball(list, w - 24, H / 2, 9, t * per(1))
  return list
end

-- A stitch arcs over and drops onto the ball, which gives a little as it lands: noted.
function FRAMES.noting(t, w)
  local list = {}
  local p = (t % (M.LOOP / 2)) / (M.LOOP / 2)
  local fall = ease(p / 0.75)
  local cx, cy = w / 2 + 6, H / 2 + 2
  local give = p > 0.75 and 1 + 0.08 * math.sin((p - 0.75) / 0.25 * math.pi) or 1
  ball(list, cx, cy, 9 * give, t * per(1))
  if p < 0.8 then
    local x = cx - 26 + 26 * fall
    local y = cy - 4 - 12 * math.sin(math.pi * fall) * (1 - fall) - (1 - fall) * 2
    M.stitch(list, x, y - 2, 1)
  end
  return list
end

-- A slow connection: the strand barely moves and sags.
function FRAMES.slow(t, w)
  return { strand(16, w - 16, H / 2 - 3, 2.5, t * per(1), 1.5, rgb(ROSE, 0.6), 2.2, 7) }
end

-- Filling: only her needles move; badge.lua draws the stitches.
function FRAMES.needles(t, w)
  local list = {}
  needles(list, w / 2, H / 2 - 1, 13, math.sin(t * per(4) / 2) ^ 2)
  return list
end

M.KINDS = { "listening", "looking", "transcribing", "noting", "slow", "needles" }

-- Renders every frame of `kind` to <dir>/<kind>-NN.png, on the badge colour, uncropped.
function M.render(kind, dir)
  local w = M.WIDTH[kind]
  local c = hs.canvas.new({ x = 0, y = 0, w = w, h = H })
  local n = math.floor(M.LOOP * M.FPS + 0.5)
  for i = 0, n - 1 do
    local list = FRAMES[kind](i / M.FPS, w)
    table.insert(list, 1, { type = "rectangle", action = "fill", fillColor = rgb(M.BG) })
    c:replaceElements(list)
    c:imageFromCanvas():saveToFile(string.format("%s/%s-%02d.png", dir, kind, i))
  end
  c:delete()
  return n
end

return M
