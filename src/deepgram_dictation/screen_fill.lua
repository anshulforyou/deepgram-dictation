-- Filling in a form on screen for the user, after they confirmed the fields and values grandma
-- planned. Claude drives the screen through the computer-use toolset; every action is run here
-- one at a time and checked first (core.checkFillAction, core.fillClickAllowed):
--
--   - only the confirmed values can be typed, so text on the page can't make her type anything else
--   - Return/Enter is never pressed, and buttons, links, checkboxes and menu items are never
--     clicked (checked through macOS Accessibility before each click), so nothing gets submitted
--   - password fields are never typed into
--   - Esc, or any mouse or keyboard input from the user, stops her at once, and so does switching
--     to another app; at most core.FILL_MAX_ACTIONS actions and core.FILL_MAX_SECONDS seconds
--
-- Screenshots go to Anthropic's API and are never saved.

local core = require("deepgram_dictation.core")
local screen = require("deepgram_dictation.screen")

local M = {}

local API_URL = "https://api.anthropic.com/v1/messages"
local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local SETTLE = 0.15 -- seconds for the page to react after a click or typing
local NOT_EXECUTED = "Not executed: an earlier computer action in this turn failed."
-- hs.json turns an empty Lua table into [], but a tool_use input must go back as {}.
local EMPTY_OBJECT = "__deepgram_dictation_empty_object__"

local cfg, instructions, active

local function log(fmt, ...) print("[deepgram-dictation] fill: " .. string.format(fmt, ...)) end

function M.setup(config)
  cfg = config
  if not cfg.screenAssist then return end
  local f = io.open(MODULE_DIR .. "/fill_prompt.txt", "r")
  instructions = f and f:read("a")
  if f then f:close() end
  if not instructions then log("fill_prompt.txt not found") end
end

function M.enabled() return cfg ~= nil and cfg.screenAssist and instructions ~= nil end
function M.running() return active ~= nil end

-- Stops the fill in progress, if any.
function M.stop(reason)
  if active then active(reason or "stopped") end
end

local function encode(body)
  return (hs.json.encode(body):gsub('"' .. EMPTY_OBJECT .. '"', "{}"))
end

-- Claude's turn as it goes back in the next request, with empty tool inputs kept as objects.
local function assistantTurn(content)
  for _, block in ipairs(content) do
    local empty = type(block) == "table" and block.type == "tool_use"
      and (type(block.input) ~= "table" or next(block.input) == nil)
    if empty then
      block.input = EMPTY_OBJECT
    end
  end
  return { role = "assistant", content = content }
end

local function element(point)
  local ok, el = pcall(hs.axuielement.systemElementAtPosition, point)
  return ok and el or nil
end

local function attr(el, name)
  if not el then return nil end
  local ok, value = pcall(function() return el:attributeValue(name) end)
  return ok and value or nil
end

local function focused()
  local ok, el = pcall(function() return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement") end)
  return ok and el or nil
end

-- Chromium browsers only show the page's fields to Accessibility when asked, and build that tree
-- lazily: right after asking, every point on the page still reads as its scroll area. Returns the
-- seconds to wait before the first click can be checked (0 when it was already on).
local EXPOSE_WAIT = 1.5
local function exposePage(app)
  local el = hs.axuielement.applicationElement(app)
  if attr(el, "AXManualAccessibility") == true then return 0 end
  local ok = pcall(function() el:setAttributeValue("AXManualAccessibility", true) end)
  return ok and EXPOSE_WAIT or 0
end

local function click(point, count)
  local types = hs.eventtap.event.types
  local state = hs.eventtap.event.properties.mouseEventClickState
  for n = 1, count do
    hs.eventtap.event.newMouseEvent(types.leftMouseDown, point):setProperty(state, n):post()
    hs.eventtap.event.newMouseEvent(types.leftMouseUp, point):setProperty(state, n):post()
  end
end

local KEY_NAMES = { backspace = "delete", delete = "forwarddelete" }

-- Fills `fields` ({ { label, value, skip } }, as confirmed) on `scr`. `progress(n)` is called before
-- each action; `done(summary, info)` exactly once, with info = { status = "done" | "stopped" |
-- "error", reason, ms, actions = { "left_click", ... } }.
function M.run(fields, scr, progress, done)
  if active then return done(nil, { status = "error", reason = "a fill is already running", actions = {} }) end
  local key = screen.apiKey()
  if not key then
    return done(nil, { status = "error", reason = "No Anthropic key in the Keychain.", actions = {} })
  end
  local frame = scr:fullFrame()
  local scale = core.fillScale(frame.w, frame.h)
  local size = { w = math.floor(frame.w * scale), h = math.floor(frame.h * scale) }
  local app = hs.application.frontmostApplication()
  local bundle = app and app:bundleID()
  local exposeWait = app and exposePage(app) or 0

  local started = hs.timer.secondsSinceEpoch()
  local finished, body, menuOpen = false, nil, false
  local actions = {}
  local watcher, deadline

  local function finish(summary, status, reason)
    if finished then return end
    finished = true
    active = nil
    if watcher then watcher:stop() end
    if deadline then deadline:stop() end
    local ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000 + 0.5)
    if status ~= "done" then log("%s after %d ms and %d actions: %s", status, ms, #actions, tostring(reason)) end
    done(summary, { status = status, reason = reason, ms = ms, actions = actions })
  end
  active = function(reason) finish(nil, "stopped", reason) end

  -- Anything the user does with the mouse or keyboard stops her. Her own events come from this
  -- process, so they don't count.
  local ownPid = hs.processInfo.processID
  local sourcePid = hs.eventtap.event.properties.eventSourceUnixProcessID
  local types = hs.eventtap.event.types
  watcher = hs.eventtap.new({ types.keyDown, types.flagsChanged, types.leftMouseDown, types.rightMouseDown,
                              types.mouseMoved, types.scrollWheel }, function(e)
    if finished or e:getProperty(sourcePid) == ownPid then return false end
    if e:getType() == types.keyDown and e:getKeyCode() == hs.keycodes.map.escape then
      finish(nil, "stopped", "you pressed Esc")
      return true
    end
    finish(nil, "stopped", "you used the mouse or keyboard")
    return false
  end):start()
  deadline = hs.timer.doAfter(core.FILL_MAX_SECONDS, function()
    finish(nil, "stopped", "it took longer than " .. core.FILL_MAX_SECONDS .. " seconds")
  end)

  local function shoot(cb)
    screen.capture(function(shot, err) cb(shot and shot.data, err) end, { screen = scr, size = size })
  end

  -- Runs one action, then calls cb(result, failed).
  local function runAction(a, cb)
    local ok, why = core.checkFillAction(a.name, a.input, fields)
    if not ok then return cb(core.fillResult(a.id, "Refused: " .. why, true), true) end
    if #actions >= core.FILL_MAX_ACTIONS then
      return finish(nil, "stopped", "it reached " .. core.FILL_MAX_ACTIONS .. " actions")
    end
    local front = hs.application.frontmostApplication()
    if bundle and (not front or front:bundleID() ~= bundle) then
      return finish(nil, "stopped", "another app came to the front")
    end
    table.insert(actions, a.name)
    progress(#actions)
    local input = a.input
    local function after(result, failed)
      hs.timer.doAfter(SETTLE, function() if not finished then cb(result, failed) end end)
    end

    if a.name == "screenshot" then
      return shoot(function(data, err)
        if data then return cb(core.fillImage(a.id, data)) end
        cb(core.fillResult(a.id, "Error: " .. tostring(err), true), true)
      end)
    elseif a.name == "zoom" then
      local r = type(input.region) == "table" and input.region or {}
      local p0, p1 = core.fillPoint({ r[1], r[2] }, frame, scale), core.fillPoint({ r[3], r[4] }, frame, scale)
      if not p0 or not p1 or p1.x <= p0.x or p1.y <= p0.y then
        return cb(core.fillResult(a.id, "Error: region outside the screen", true), true)
      end
      return screen.capture(function(shot, err)
        if shot then return cb(core.fillImage(a.id, shot.data)) end
        cb(core.fillResult(a.id, "Error: " .. tostring(err), true), true)
      end, { screen = scr, rect = { x = p0.x, y = p0.y, w = p1.x - p0.x, h = p1.y - p0.y } })
    elseif a.name == "left_click" or a.name == "triple_click" then
      local point = input.coordinate and core.fillPoint(input.coordinate, frame, scale) or hs.mouse.absolutePosition()
      if not point then return cb(core.fillResult(a.id, "Error: coordinate outside the screen", true), true) end
      local el = element(point)
      local role, subrole = attr(el, "AXRole"), attr(el, "AXSubrole")
      local allowed, reason = core.fillClickAllowed(role, subrole, menuOpen)
      if not allowed then return cb(core.fillResult(a.id, "Refused: " .. reason, true), true) end
      menuOpen = role == "AXPopUpButton" or role == "AXComboBox"
      click(point, a.name == "triple_click" and 3 or 1)
      return after(core.fillResult(a.id, "OK"))
    elseif a.name == "type" then
      local f = focused()
      if attr(f, "AXSubrole") == "AXSecureTextField" then
        return cb(core.fillResult(a.id, "Refused: password fields are never filled", true), true)
      end
      if input.text:find("[\r\n]") and attr(f, "AXRole") ~= "AXTextArea" then
        return cb(core.fillResult(a.id, "Refused: a new line would submit this field", true), true)
      end
      hs.eventtap.keyStrokes(input.text)
      return after(core.fillResult(a.id, "OK"))
    elseif a.name == "key" then
      local mods, name = core.fillKey(input.text)
      for _ = 1, math.max(1, math.floor(tonumber(input["repeat"]) or 1)) do
        hs.eventtap.keyStroke(mods, KEY_NAMES[name] or name, 0)
      end
      return after(core.fillResult(a.id, "OK"))
    elseif a.name == "scroll" then
      local point = input.coordinate and core.fillPoint(input.coordinate, frame, scale)
      if point then hs.mouse.absolutePosition(point) end
      local n = math.min(20, math.max(1, math.floor(tonumber(input.scroll_amount) or 3))) * 3
      local dir = input.scroll_direction
      local offsets = { up = { 0, n }, down = { 0, -n }, left = { n, 0 }, right = { -n, 0 } }
      hs.eventtap.scrollWheel(offsets[dir] or { 0, -n }, {}, "line")
      return after(core.fillResult(a.id, "OK"))
    elseif a.name == "wait" then
      local seconds = math.min(5, math.max(0, tonumber(input.duration) or 1))
      return hs.timer.doAfter(seconds, function() if not finished then cb(core.fillResult(a.id, "OK")) end end)
    elseif a.name == "cursor_position" then
      local p = hs.mouse.absolutePosition()
      return cb(core.fillResult(a.id, string.format("X=%d, Y=%d", math.floor((p.x - frame.x) * scale),
        math.floor((p.y - frame.y) * scale))))
    end
    cb(core.fillResult(a.id, "Refused: unknown action", true), true)
  end

  local post -- defined below

  -- Runs a turn's actions in order. After the first failure the rest are not run.
  local function runTurn(list, resp)
    local results, failed = {}, false
    local function step(i)
      if finished then return end
      local a = list[i]
      if not a then
        table.insert(body.messages, assistantTurn(resp.content))
        table.insert(body.messages, { role = "user", content = results })
        return post()
      end
      if failed then
        table.insert(results, core.fillResult(a.id, NOT_EXECUTED, true))
        return step(i + 1)
      end
      runAction(a, function(result, didFail)
        table.insert(results, result)
        failed = didFail == true
        step(i + 1)
      end)
    end
    step(1)
  end

  post = function()
    hs.http.asyncPost(API_URL, encode(body), {
      ["x-api-key"] = key,
      ["anthropic-version"] = "2023-06-01",
      ["content-type"] = "application/json",
    }, function(status, respBody)
      if finished then return end
      local ok, resp = pcall(hs.json.decode, respBody or "")
      if status ~= 200 or not ok or type(resp) ~= "table" then
        local message = ok and type(resp) == "table" and type(resp.error) == "table" and resp.error.message
        return finish(nil, "error", "HTTP " .. tostring(status) .. (message and (": " .. message) or ""))
      end
      if resp.stop_reason == "tool_use" then
        local list = core.fillActions(resp)
        if #list > 0 then return runTurn(list, resp) end
      end
      if resp.stop_reason == "refusal" then return finish(nil, "error", "Claude declined to fill this form") end
      local parts = {}
      for _, block in ipairs(type(resp.content) == "table" and resp.content or {}) do
        if type(block) == "table" and block.type == "text" then table.insert(parts, block.text) end
      end
      local summary = table.concat(parts):match("^%s*(.-)%s*$")
      finish(summary ~= "" and summary or "Done.", "done")
    end)
  end

  hs.timer.doAfter(exposeWait, function()
    if finished then return end
    shoot(function(data, err)
      if finished then return end
      if not data then return finish(nil, "error", "couldn't capture the screen: " .. tostring(err)) end
      body = core.fillRequest(cfg, instructions, fields, data)
      post()
    end)
  end)
end

return M
