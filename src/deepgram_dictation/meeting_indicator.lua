-- A small floating pill shown while a meeting is being recorded: a pulsing dot, the meeting
-- name and elapsed time, and pause/resume and stop buttons. Drag it anywhere; the position is
-- remembered. It never takes focus.

local core = require("deepgram_dictation.core")

local M = {}

local W, H = 236, 52
local BTN = 30
local POSITION_KEY = "deepgramDictation.indicatorPosition"

local RED = { red = 0.95, green = 0.27, blue = 0.23 }
local AMBER = { red = 1, green = 0.73, blue = 0.18 }
local GREY = { white = 0.55 }

local canvas, dragTap
local handlers = {}
local pulse = false

local function onSomeScreen(point)
  for _, screen in ipairs(hs.screen.allScreens()) do
    if hs.geometry.point(point.x, point.y):inside(screen:frame()) then return true end
  end
  return false
end

local function initialTopLeft()
  local saved = hs.settings.get(POSITION_KEY)
  if type(saved) == "table" and saved.x and saved.y and onSomeScreen({ x = saved.x + 10, y = saved.y + 10 }) then
    return saved
  end
  local frame = hs.screen.mainScreen():frame()
  return { x = frame.x + frame.w - W - 12, y = frame.y + math.floor(frame.h * 0.3) }
end

local function startDrag()
  if dragTap then dragTap:stop() end
  local mouseStart = hs.mouse.absolutePosition()
  local origin = canvas:topLeft()
  local types = hs.eventtap.event.types
  dragTap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, function(event)
    if not canvas then return false end
    local now = hs.mouse.absolutePosition()
    canvas:topLeft({ x = origin.x + now.x - mouseStart.x, y = origin.y + now.y - mouseStart.y })
    if event:getType() == types.leftMouseUp then
      dragTap:stop()
      dragTap = nil
      hs.settings.set(POSITION_KEY, canvas:topLeft())
    end
    return false
  end)
  dragTap:start()
end

local function circleButton(id, x, fill)
  return { id = id, type = "circle", action = "fill", fillColor = fill,
           center = { x = x + BTN / 2, y = H / 2 }, radius = BTN / 2, trackMouseUp = true }
end

-- Icons are drawn shapes rather than emoji so they look the same everywhere.
local function pauseIcon(x)
  local cx, cy = x + BTN / 2, H / 2
  return {
    { id = "pause", type = "rectangle", action = "fill", fillColor = { white = 1 }, trackMouseUp = true,
      frame = { x = cx - 5, y = cy - 6, w = 3.5, h = 12 } },
    { id = "pause", type = "rectangle", action = "fill", fillColor = { white = 1 }, trackMouseUp = true,
      frame = { x = cx + 1.5, y = cy - 6, w = 3.5, h = 12 } },
  }
end

local function playIcon(x)
  local cx, cy = x + BTN / 2, H / 2
  return { { id = "pause", type = "segments", action = "fill", closed = true, fillColor = { white = 1 },
             trackMouseUp = true,
             coordinates = { { x = cx - 4, y = cy - 6.5 }, { x = cx + 6.5, y = cy }, { x = cx - 4, y = cy + 6.5 } } } }
end

local function stopIcon(x)
  local cx, cy = x + BTN / 2, H / 2
  return { { id = "stop", type = "rectangle", action = "fill", fillColor = { white = 1 }, trackMouseUp = true,
             roundedRectRadii = { xRadius = 2, yRadius = 2 }, frame = { x = cx - 5.5, y = cy - 5.5, w = 11, h = 11 } } }
end

local function elements(info)
  local headline, detail = core.indicatorText(info.state, info.paused, info.elapsed, info.name)
  local recording = info.state == "recording"
  local dotColor = not recording and GREY or (info.paused and AMBER or RED)
  local dotAlpha = (recording and not info.paused and pulse) and 0.35 or 1
  local textWidth = (recording and (W - 2 * BTN - 62) or (W - 48))

  local list = {
    { id = "drag", type = "rectangle", action = "fill", fillColor = { white = 0.1, alpha = 0.94 },
      strokeColor = { white = 1, alpha = 0.12 }, roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
      trackMouseDown = true },
    { id = "drag", type = "circle", action = "fill", center = { x = 22, y = H / 2 }, radius = 5,
      fillColor = { red = dotColor.red, green = dotColor.green, blue = dotColor.blue, white = dotColor.white,
                    alpha = dotAlpha }, trackMouseDown = true },
    { id = "drag", type = "text", text = headline, frame = { x = 36, y = 9, w = textWidth, h = 18 },
      textSize = 13, textColor = { white = 1 }, textLineBreak = "truncateTail", trackMouseDown = true },
    { id = "drag", type = "text", text = detail, frame = { x = 36, y = 27, w = textWidth, h = 16 },
      textSize = 11, textColor = { white = 0.65 }, textLineBreak = "truncateTail", trackMouseDown = true },
  }
  if recording then
    local pauseX, stopX = W - 2 * BTN - 18, W - BTN - 11
    table.insert(list, circleButton("pause", pauseX, { white = 0.26 }))
    for _, e in ipairs(info.paused and playIcon(pauseX) or pauseIcon(pauseX)) do table.insert(list, e) end
    table.insert(list, circleButton("stop", stopX, RED))
    for _, e in ipairs(stopIcon(stopX)) do table.insert(list, e) end
  end
  return list
end

local function create()
  local topLeft = initialTopLeft()
  canvas = hs.canvas.new({ x = topLeft.x, y = topLeft.y, w = W, h = H })
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:mouseCallback(function(_, message, id)
    if message == "mouseDown" and id == "drag" then
      startDrag()
    elseif message == "mouseUp" and handlers[id] then
      handlers[id]()
    end
  end)
  canvas:show(0.15)
end

function M.hide()
  if dragTap then dragTap:stop() dragTap = nil end
  if canvas then canvas:delete(0.15) canvas = nil end
end

-- `info` = { state = ..., paused = bool, elapsed = seconds, name = meeting name or nil }.
-- Hidden when idle. Call about once a second while recording so the dot pulses.
function M.update(info)
  if not info or info.state == "idle" then return M.hide() end
  if not canvas then create() end
  pulse = not pulse
  canvas:replaceElements(elements(info))
end

-- `actions` = { pause = fn, stop = fn }.
function M.setup(actions)
  handlers = actions or {}
end

return M
