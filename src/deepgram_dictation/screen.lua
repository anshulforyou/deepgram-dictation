-- Asking grandma about the screen (Fn+Control): captures the display under the mouse, then sends
-- the spoken question and the screenshot to Claude, which either writes text to paste where the
-- user is typing or answers in a panel. Screenshots are deleted as soon as they are encoded and
-- never saved with the dictation history.

local core = require("deepgram_dictation.core")
local memory = require("deepgram_dictation.screen_memory")

local M = {}

local API_URL = "https://api.anthropic.com/v1/messages"
local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local MAX_EDGE = 1920 -- pixels on the long side: small text stays readable (100 to 450 KB a screen)
local JPEG_QUALITY = 60
local CAPTURE_TIMEOUT = 5 -- seconds; usually well under one
local TMP_DIR = os.getenv("TMPDIR") or "/tmp/"
local TMP_PREFIX = "deepgram-dictation-screen-"
-- Sweaters or projects Claude may open for one question. Given more, it opens more whether or not
-- it needs them (seen in make eval-screen), at 2 to 3 s each, so after this it has to answer.
local MAX_OPENS = 1
local MEMORY_CHARS = 240000 -- memory per question in all, as in grandma_context.py
local MIN_OPEN_CHARS = 20000 -- an opened item always gets at least this much

-- Captures a rectangle (in points) to a JPEG no wider than MAX_EDGE: screencapture, then sips.
local CAPTURE = [[
/usr/sbin/screencapture -x -t png -R "$3" "$1" && \
/usr/bin/sips -s format jpeg -s formatOptions "$4" ${5:+-Z "$5"} "$1" --out "$2" >/dev/null && \
rm -f "$1"
]]

local cfg, instructions
local captureCount = 0
-- Tasks in flight: an hs.task nothing refers to can be collected before it ends, and its
-- callback never runs. Only written, never read, on purpose.
local capturing = {} -- luacheck: ignore 241

local function log(fmt, ...) print("[deepgram-dictation] screen: " .. string.format(fmt, ...)) end

local function getApiKey()
  local out, ok = hs.execute("/usr/bin/security find-generic-password -s '" .. cfg.anthropicKeychainName .. "' -w")
  if ok and out and out:match("%S") then return (out:gsub("%s+$", "")) end
  return nil
end

-- Screenshots left behind by a reload or crash mid-capture.
local function removeStaleCaptures()
  for file in hs.fs.dir(TMP_DIR) do
    if file:sub(1, #TMP_PREFIX) == TMP_PREFIX then os.remove(TMP_DIR .. "/" .. file) end
  end
end

function M.setup(config)
  cfg = config
  pcall(removeStaleCaptures)
  memory.setup(config)
  if not cfg.screenAssist then return end
  local f = io.open(MODULE_DIR .. "/screen_prompt.txt", "r")
  instructions = f and f:read("a")
  if f then f:close() end
  if not instructions then log("screen_prompt.txt not found") end
end

function M.enabled() return cfg and cfg.screenAssist and instructions ~= nil end

function M.teardown() memory.teardown() end

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
  local base = TMP_DIR .. "/" .. TMP_PREFIX .. captureCount
  local png, jpg = base .. ".png", base .. ".jpg"
  local started = hs.timer.secondsSinceEpoch()
  local rect = string.format("%d,%d,%d,%d", math.floor(frame.x), math.floor(frame.y), math.floor(frame.w),
    math.floor(frame.h))
  local finished, timer, task = false, nil, nil
  local function finish(shot, err)
    if finished then return end
    finished = true
    if timer then timer:stop() end
    if task then capturing[task] = nil end
    os.remove(png)
    os.remove(jpg)
    done(shot, err)
  end
  timer = hs.timer.doAfter(CAPTURE_TIMEOUT, function()
    if task and task:isRunning() then task:terminate() end
    finish(nil, "timed out")
  end)
  task = hs.task.new("/bin/sh", function(code, _, stderr)
    if finished then return end
    local f = code == 0 and io.open(jpg, "rb")
    local data = f and f:read("a")
    if f then f:close() end
    if not data or #data == 0 then return finish(nil, "screen capture failed: " .. tostring(stderr)) end
    finish({ data = hs.base64.encode(data), screen = screen,
             ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000 + 0.5) })
  end, { "-c", CAPTURE, "sh", png, jpg, rect, tostring(JPEG_QUALITY), pixels > MAX_EDGE and tostring(MAX_EDGE) or "" })
  capturing[task] = true
  if not task:start() then finish(nil, "could not start screencapture") end
end

-- Asks Claude `question` about `shot`, then calls `done(answer, info)` exactly once. `answer` is
-- { kind = "insert" | "answer", text } or nil; `info` is { status = "ok" | "timeout" | "error",
-- ms, reason, memory = names sent with the question, opened = names Claude opened }.
-- With grandma memory, Claude may stop to open a sweater or project; the question then goes on
-- with that memory, up to MAX_OPENS of them.
function M.ask(question, shot, done)
  local key = getApiKey()
  if not key then
    local reason = "No Anthropic key in the Keychain ('" .. cfg.anthropicKeychainName .. "')."
    return done(nil, { status = "error", reason = reason })
  end
  local started = hs.timer.secondsSinceEpoch()
  local finished, timer, body = false, nil, nil
  local sent, opened, opens, sentChars = {}, {}, 0, 0
  local function finish(answer, status, reason)
    if finished then return end
    finished = true
    if timer then timer:stop() end
    local ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000 + 0.5)
    if status ~= "ok" then log("%s after %d ms%s", status, ms, reason and (": " .. reason) or "") end
    done(answer, { status = status, ms = ms, reason = reason, memory = sent, opened = opened })
    memory.refreshProfile()
  end
  timer = hs.timer.doAfter(cfg.screenTimeout, function() finish(nil, "timeout", "no answer after "
    .. cfg.screenTimeout .. " s") end)

  local post -- defined below

  -- Answers each open_memory call in `resp` (in order), then continues the conversation.
  local function openMemory(calls, resp)
    local results = {}
    local function nextCall(i)
      if finished then return end
      local call = calls[i]
      if not call then
        core.continueWithResults(body, resp, results)
        if opens >= MAX_OPENS then body.tool_choice = { type = "none" } end
        return post()
      end
      opens = opens + 1
      if opens > MAX_OPENS or call.tool ~= "open_memory" then
        table.insert(results, { id = call.id, isError = true,
          text = "No more memory can be opened for this question. Answer with what you have." })
        return nextCall(i + 1)
      end
      memory.open(call.name, math.max(MIN_OPEN_CHARS, MEMORY_CHARS - sentChars), function(block, err)
        if block then
          table.insert(opened, block.name)
          table.insert(results, { id = call.id, text = block.text })
        else
          table.insert(results, { id = call.id, text = tostring(err), isError = true })
        end
        nextCall(i + 1)
      end)
    end
    nextCall(1)
  end

  post = function()
    hs.http.asyncPost(API_URL, hs.json.encode(body), {
      ["x-api-key"] = key,
      ["anthropic-version"] = "2023-06-01",
      ["content-type"] = "application/json",
    }, function(status, respBody)
      if finished then return end
      local ok, resp = pcall(hs.json.decode, respBody or "")
      if status ~= 200 then
        local message = ok and type(resp) == "table" and type(resp.error) == "table" and resp.error.message
        return finish(nil, "error", "HTTP " .. tostring(status) .. (message and (": " .. message) or ""))
      end
      local calls = core.memoryRequests(ok and resp or nil)
      if #calls > 0 then return openMemory(calls, resp) end
      local answer, why = core.parseScreenAnswer(ok and resp or nil, hs.json.decode)
      if answer then finish(answer, "ok") else finish(nil, "error", why) end
    end)
  end

  if not memory.enabled() then
    body = core.screenRequest(cfg, instructions, question, shot.data, "image/jpeg")
    return post()
  end
  memory.context(question, function(context, err)
    if finished then return end
    if not context then log("no grandma memory for this question: %s", tostring(err)) end
    for _, m in ipairs(context and context.memory or {}) do
      table.insert(sent, m.name)
      sentChars = sentChars + #m.text
    end
    body = core.screenRequest(cfg, instructions, question, shot.data, "image/jpeg", context)
    post()
  end)
end

return M
