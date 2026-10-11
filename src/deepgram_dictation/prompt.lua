-- A small floating card in the top-right corner with two buttons, used to offer meeting
-- transcription. It doesn't take focus, so it never interrupts typing.

local M = {}

local WIDTH, HEIGHT, MARGIN = 330, 96, 14
local current, dismissTimer

function M.hide()
  if dismissTimer then dismissTimer:stop() dismissTimer = nil end
  if current then current:delete(0.15) current = nil end
end

function M.isShown() return current ~= nil end

local function button(id, label, frame, fill, textColor)
  return {
    { id = id, type = "rectangle", action = "fill", frame = frame, fillColor = fill,
      roundedRectRadii = { xRadius = 7, yRadius = 7 }, trackMouseUp = true },
    { id = id, type = "text", text = label, frame = { x = frame.x, y = frame.y + 5, w = frame.w, h = frame.h },
      textSize = 13, textColor = textColor, textAlignment = "center", trackMouseUp = true },
  }
end

-- Shows the card. `onAccept` runs when the primary button is clicked; the card disappears on
-- its own after `timeout` seconds (default 90).
function M.show(title, subtitle, acceptLabel, onAccept, timeout)
  M.hide()
  local screen = hs.screen.mainScreen():frame()
  local canvas = hs.canvas.new({
    x = screen.x + screen.w - WIDTH - MARGIN, y = screen.y + MARGIN, w = WIDTH, h = HEIGHT,
  })
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  canvas:appendElements({
    type = "rectangle", action = "fill", fillColor = { white = 0.11, alpha = 0.97 },
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
  }, {
    type = "text", text = title, frame = { x = 16, y = 12, w = WIDTH - 32, h = 20 },
    textSize = 14, textColor = { white = 1 },
  }, {
    type = "text", text = subtitle, frame = { x = 16, y = 33, w = WIDTH - 32, h = 18 },
    textSize = 12, textColor = { white = 0.7 },
  })
  canvas:appendElements(button("dismiss", "Not now", { x = WIDTH - 236, y = 58, w = 90, h = 26 },
    { white = 0.25 }, { white = 0.9 }))
  canvas:appendElements(button("accept", acceptLabel, { x = WIDTH - 136, y = 58, w = 120, h = 26 },
    { red = 0.9, green = 0.27, blue = 0.23 }, { white = 1 }))

  canvas:mouseCallback(function(_, message, id)
    if message ~= "mouseUp" then return end
    if id == "accept" then
      M.hide()
      onAccept()
    elseif id == "dismiss" then
      M.hide()
    end
  end)

  current = canvas:show(0.15)
  dismissTimer = hs.timer.doAfter(timeout or 90, M.hide)
end

return M
