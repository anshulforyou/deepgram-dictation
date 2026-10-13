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
local DRAG_BIN = core.supportDir() .. "/GrandmaDrag"
-- Drag helpers in flight (an hs.task nothing refers to can be collected before it ends).
local draggers = {} -- luacheck: ignore 241

local openDialog -- defined below
local OPEN_BUTTONS = { Open = true, Choose = true, Upload = true, Select = true }

-- A macOS open dialog, when one is in front: the focused window or a sheet on it, with an
-- Open-like button. Returns the dialog's element or nil.
local function findButton(el, depth)
  if depth > 6 or not el then return false end
  local ok, role = pcall(function() return el:attributeValue("AXRole") end)
  if ok and role == "AXButton" then
    local title = el:attributeValue("AXTitle")
    if OPEN_BUTTONS[title] then return true end
  end
  local okc, children = pcall(function() return el:attributeValue("AXChildren") end)
  for i, child in ipairs(okc and children or {}) do
    if i > 60 then break end
    if findButton(child, depth + 1) then return true end
  end
  return false
end

openDialog = function()
  local win = hs.window.focusedWindow()
  if not win then return nil end
  local el = hs.axuielement.windowElement(win)
  local candidates = {}
  local ok, sheets = pcall(function() return el:attributeValue("AXSheets") end)
  for _, sheet in ipairs(ok and sheets or {}) do table.insert(candidates, sheet) end
  local okr, sub = pcall(function() return el:attributeValue("AXSubrole") end)
  if okr and (sub == "AXDialog" or sub == "AXSystemDialog") then table.insert(candidates, el) end
  for _, c in ipairs(candidates) do
    if findButton(c, 0) then return c end
  end
  return nil
end

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
  local uploaded = {} -- file id: upload attempts
  local upload -- defined below
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

  -- Waits up to `seconds` for test() to be true, checking every 0.2 s, then calls cb(result).
  local function waitFor(test, seconds, cb)
    local deadlineAt = hs.timer.secondsSinceEpoch() + seconds
    local function check()
      if finished then return end
      local value = test()
      if value or hs.timer.secondsSinceEpoch() >= deadlineAt then return cb(value) end
      hs.timer.doAfter(0.2, check)
    end
    check()
  end

  -- Types the path into a macOS open dialog (Go to folder) and opens it. Only ever presses Return
  -- while that dialog is the one in front.
  local function chooseInDialog(path, cb)
    hs.eventtap.keyStroke({ "cmd", "shift" }, "g", 0)
    hs.timer.doAfter(0.7, function()
      if finished then return end
      if not openDialog() then return cb(false, "the file dialog closed") end
      hs.eventtap.keyStrokes(path)
      hs.timer.doAfter(0.5, function()
        if finished or not openDialog() then return cb(false, "the file dialog closed") end
        hs.eventtap.keyStroke({}, "return", 0) -- go to the file
        hs.timer.doAfter(0.9, function()
          if finished or not openDialog() then return cb(false, "the file dialog closed") end
          hs.eventtap.keyStroke({}, "return", 0) -- open it
          waitFor(function() return not openDialog() end, 3, function(closed)
            if closed then return cb(true) end
            hs.eventtap.keyStroke({}, "escape", 0)
            cb(false, "the file dialog didn't accept the file")
          end)
        end)
      end)
    end)
  end

  -- Drags the file onto `target` the way Finder would, through GrandmaDrag.
  local function dragOnto(path, target, cb)
    if not hs.fs.attributes(DRAG_BIN) then return cb(false, "GrandmaDrag isn't installed (run ./install.sh)") end
    local start = { x = math.max(frame.x + 30, target.x - 120), y = math.max(frame.y + 30, target.y - 90) }
    local ended, posted, helper = false, false, nil
    local function finishDrag(ok, why)
      if ended then return end
      ended = true
      draggers[helper] = nil
      if helper and helper:isRunning() then helper:terminate() end
      cb(ok, why)
    end
    local function move(kind, p) hs.eventtap.event.newMouseEvent(kind, p):post() end
    helper = hs.task.new(DRAG_BIN, function(code)
      finishDrag(code == 0, code == 0 and nil or "the drop zone didn't take the file")
    end, function(_, stdout)
      if posted or not tostring(stdout):find("ready", 1, true) then return true end
      posted = true
      move(types.leftMouseDown, start)
      local steps = 24
      for i = 1, steps do
        hs.timer.doAfter(0.03 * i, function()
          local t = i / steps
          move(types.leftMouseDragged,
            { x = start.x + (target.x - start.x) * t, y = start.y + (target.y - start.y) * t })
        end)
      end
      hs.timer.doAfter(0.03 * steps + 0.3, function()
        move(types.leftMouseDragged, target)
        move(types.leftMouseUp, target)
      end)
      return true
    end, { path, tostring(math.floor(start.x)), tostring(math.floor(start.y)) })
    draggers[helper] = true
    if not helper:start() then return finishDrag(false, "couldn't start GrandmaDrag") end
    hs.timer.doAfter(6, function() finishDrag(false, "the drag didn't finish") end)
  end

  -- upload_file: click to browse and use the file dialog, or, for a drop-only zone, drag the
  -- file onto it. Claude only says where; this code does the uploading.
  upload = function(a, res, cb)
    local file = core.fillUploads(fields)[a.input.file]
    uploaded[file.id] = (uploaded[file.id] or 0) + 1
    local target = core.fillPoint(a.input.coordinate, frame, scale)
    if not target then return cb(res("Error: coordinate outside the screen", true), true) end
    local el = element(target)
    local role = attr(el, "AXRole")
    local label = attr(el, "AXTitle") or attr(el, "AXDescription") or attr(el, "AXValue")
    local allowed, why = core.uploadClickAllowed(role, type(label) == "string" and label or nil)
    if not allowed then return cb(res("Refused: " .. why, true), true) end
    click(target, 1)
    waitFor(openDialog, 2, function(dialog)
      if finished then return end
      if dialog then
        return chooseInDialog(file.path, function(ok, err)
          if ok then return cb(res("OK: " .. file.name .. " chosen in the file dialog")) end
          cb(res("Error: " .. tostring(err), true), true)
        end)
      end
      dragOnto(file.path, target, function(ok, err)
        if ok then return cb(res("OK: " .. file.name .. " dropped onto the drop zone")) end
        cb(res("Error: " .. tostring(err) .. ". Take a screenshot to see what the page shows.", true), true)
      end)
    end)
  end

  -- Runs one action, then calls cb(result, failed).
  local function runAction(a, cb)
    local function res(content, isError)
      return a.computer and core.fillResult(a.id, content, isError) or core.toolResult(a.id, content, isError)
    end
    local ok, why = core.checkFillAction(a.name, a.input, fields, uploaded)
    if not ok then return cb(res("Refused: " .. why, true), true) end
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
    if not a.computer and a.name ~= "upload_file" then return cb(res("Refused: unknown tool", true), true) end
    local function after(result, failed)
      hs.timer.doAfter(SETTLE, function() if not finished then cb(result, failed) end end)
    end

    if a.name == "screenshot" then
      return shoot(function(data, err)
        if data then return cb(core.fillImage(a.id, data)) end
        cb(res("Error: " .. tostring(err), true), true)
      end)
    elseif a.name == "zoom" then
      local r = type(input.region) == "table" and input.region or {}
      local p0, p1 = core.fillPoint({ r[1], r[2] }, frame, scale), core.fillPoint({ r[3], r[4] }, frame, scale)
      if not p0 or not p1 or p1.x <= p0.x or p1.y <= p0.y then
        return cb(res("Error: region outside the screen", true), true)
      end
      return screen.capture(function(shot, err)
        if shot then return cb(core.fillImage(a.id, shot.data)) end
        cb(res("Error: " .. tostring(err), true), true)
      end, { screen = scr, rect = { x = p0.x, y = p0.y, w = p1.x - p0.x, h = p1.y - p0.y } })
    elseif a.name == "left_click" or a.name == "triple_click" then
      local point = input.coordinate and core.fillPoint(input.coordinate, frame, scale) or hs.mouse.absolutePosition()
      if not point then return cb(res("Error: coordinate outside the screen", true), true) end
      local el = element(point)
      local role, subrole = attr(el, "AXRole"), attr(el, "AXSubrole")
      local allowed, reason = core.fillClickAllowed(role, subrole, menuOpen)
      if not allowed then return cb(res("Refused: " .. reason, true), true) end
      menuOpen = role == "AXPopUpButton" or role == "AXComboBox"
      click(point, a.name == "triple_click" and 3 or 1)
      return after(res("OK"))
    elseif a.name == "type" then
      local f = focused()
      if attr(f, "AXSubrole") == "AXSecureTextField" then
        return cb(res("Refused: password fields are never filled", true), true)
      end
      if input.text:find("[\r\n]") and attr(f, "AXRole") ~= "AXTextArea" then
        return cb(res("Refused: a new line would submit this field", true), true)
      end
      hs.eventtap.keyStrokes(input.text)
      return after(res("OK"))
    elseif a.name == "key" then
      local mods, name = core.fillKey(input.text)
      for _ = 1, math.max(1, math.floor(tonumber(input["repeat"]) or 1)) do
        hs.eventtap.keyStroke(mods, KEY_NAMES[name] or name, 0)
      end
      return after(res("OK"))
    elseif a.name == "scroll" then
      local point = input.coordinate and core.fillPoint(input.coordinate, frame, scale)
      if point then hs.mouse.absolutePosition(point) end
      local n = math.min(20, math.max(1, math.floor(tonumber(input.scroll_amount) or 3))) * 3
      local dir = input.scroll_direction
      local offsets = { up = { 0, n }, down = { 0, -n }, left = { n, 0 }, right = { -n, 0 } }
      hs.eventtap.scrollWheel(offsets[dir] or { 0, -n }, {}, "line")
      return after(res("OK"))
    elseif a.name == "wait" then
      local seconds = math.min(5, math.max(0, tonumber(input.duration) or 1))
      return hs.timer.doAfter(seconds, function() if not finished then cb(res("OK")) end end)
    elseif a.name == "cursor_position" then
      local p = hs.mouse.absolutePosition()
      return cb(res(string.format("X=%d, Y=%d", math.floor((p.x - frame.x) * scale),
        math.floor((p.y - frame.y) * scale))))
    end
    if a.name == "upload_file" then return upload(a, res, cb) end
    if a.name == "upload_file" then return upload(a, res, cb) end
    cb(res("Refused: unknown action", true), true)
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
        table.insert(results, a.computer and core.fillResult(a.id, NOT_EXECUTED, true)
          or core.toolResult(a.id, NOT_EXECUTED, true))
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
