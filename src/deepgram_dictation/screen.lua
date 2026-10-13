-- Asking grandma about the screen (Fn+Control): captures the display under the mouse, then sends
-- the spoken question and the screenshot to Claude, which either writes text to paste where the
-- user is typing or answers in a panel. Screenshots are deleted as soon as they are encoded and
-- never saved with the dictation history.

local core = require("deepgram_dictation.core")

local M = {}

local API_URL = "https://api.anthropic.com/v1/messages"
local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local MAX_EDGE = 1920 -- pixels on the long side: small text stays readable, the upload stays ~120 KB
local JPEG_QUALITY = 75

-- Captures a rectangle (in points) to a JPEG no wider than MAX_EDGE: screencapture, then sips.
local CAPTURE = [[
/usr/sbin/screencapture -x -t png -R "$3" "$1" && \
/usr/bin/sips -s format jpeg -s formatOptions "$4" ${5:+-Z "$5"} "$1" --out "$2" >/dev/null && \
rm -f "$1"
]]

local cfg, instructions
local captureCount = 0

local function log(fmt, ...) print("[deepgram-dictation] screen: " .. string.format(fmt, ...)) end

local function getApiKey()
  local out, ok = hs.execute("/usr/bin/security find-generic-password -s '" .. cfg.anthropicKeychainName .. "' -w")
  if ok and out and out:match("%S") then return (out:gsub("%s+$", "")) end
  return nil
end

function M.setup(config)
  cfg = config
  if not cfg.screenAssist then return end
  local f = io.open(MODULE_DIR .. "/screen_prompt.txt", "r")
  instructions = f and f:read("a")
  if f then f:close() end
  if not instructions then log("screen_prompt.txt not found") end
end

function M.enabled() return cfg and cfg.screenAssist and instructions ~= nil end

-- Whether Hammerspoon may record the screen. Asking shows macOS's permission prompt once.
function M.permitted(ask) return hs.screenRecordingState(ask == true) end

-- Captures the display under the mouse in the background, then calls
-- `done(shot, err)` with shot = { data = base64 JPEG, screen = hs.screen, ms }.
function M.capture(done)
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local frame = screen:fullFrame()
  local mode = screen:currentMode() or {}
  local pixels = math.max(frame.w, frame.h) * (mode.scale or 1)
  captureCount = captureCount + 1
  local base = (os.getenv("TMPDIR") or "/tmp/") .. "deepgram-dictation-screen-" .. captureCount
  local png, jpg = base .. ".png", base .. ".jpg"
  local started = hs.timer.secondsSinceEpoch()
  local rect = string.format("%d,%d,%d,%d", frame.x, frame.y, frame.w, frame.h)
  local task = hs.task.new("/bin/sh", function(code, _, stderr)
    local f = code == 0 and io.open(jpg, "rb")
    local data = f and f:read("a")
    if f then f:close() end
    os.remove(png)
    os.remove(jpg)
    if not data or #data == 0 then return done(nil, "screen capture failed: " .. tostring(stderr)) end
    done({ data = hs.base64.encode(data), screen = screen,
           ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000 + 0.5) })
  end, { "-c", CAPTURE, "sh", png, jpg, rect, tostring(JPEG_QUALITY), pixels > MAX_EDGE and tostring(MAX_EDGE) or "" })
  if not task:start() then done(nil, "could not start screencapture") end
end

-- Asks Claude `question` about `shot`, then calls `done(answer, info)` exactly once. `answer` is
-- { kind = "insert" | "answer", text } or nil; `info` is { status = "ok" | "timeout" | "error",
-- ms, reason }.
function M.ask(question, shot, done)
  local key = getApiKey()
  if not key then
    local reason = "No Anthropic key in the Keychain ('" .. cfg.anthropicKeychainName .. "')."
    return done(nil, { status = "error", reason = reason })
  end
  local started = hs.timer.secondsSinceEpoch()
  local finished, timer = false, nil
  local function finish(answer, status, reason)
    if finished then return end
    finished = true
    if timer then timer:stop() end
    local ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000 + 0.5)
    if status ~= "ok" then log("%s after %d ms%s", status, ms, reason and (": " .. reason) or "") end
    done(answer, { status = status, ms = ms, reason = reason })
  end
  timer = hs.timer.doAfter(cfg.screenTimeout, function() finish(nil, "timeout", "no answer after "
    .. cfg.screenTimeout .. " s") end)
  local body = core.screenRequest(cfg, instructions, question, shot.data, "image/jpeg")
  hs.http.asyncPost(API_URL, hs.json.encode(body), {
    ["x-api-key"] = key,
    ["anthropic-version"] = "2023-06-01",
    ["content-type"] = "application/json",
  }, function(status, respBody)
    local ok, resp = pcall(hs.json.decode, respBody or "")
    if status ~= 200 then
      local message = ok and type(resp) == "table" and type(resp.error) == "table" and resp.error.message
      return finish(nil, "error", "HTTP " .. tostring(status) .. (message and (": " .. message) or ""))
    end
    local answer, why = core.parseScreenAnswer(ok and resp or nil, hs.json.decode)
    if answer then finish(answer, "ok") else finish(nil, "error", why) end
  end)
end

return M
