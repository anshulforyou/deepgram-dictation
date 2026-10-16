-- Filling in a form on screen for the user, after they confirmed the fields and values grandma
-- planned. Claude drives the screen through the computer-use toolset; every action is run here
-- one at a time and checked first (core.checkFillAction, core.fillClickAllowed):
--
--   - only the confirmed values can be typed, so text on the page can't make her type anything else
--   - Return/Enter is never pressed, and buttons, links, checkboxes and menu items are never
--     clicked, nor typed into or pressed with Space when they have the focus (checked through
--     macOS Accessibility before each action), so nothing gets submitted
--   - password fields are never typed into
--   - Esc, or any mouse or keyboard input from the user, stops her at once, and so does switching
--     to another app; at most the actions and seconds core.fillLimits allows for the plan
--
-- The same engine works on a whole page (opts.mode): "survey" looks through it with screenshots and
-- scrolling only and ends by proposing every change; "work" makes the changes the user confirmed,
-- and may click what fill can't (core.workClickAllowed: never publish, send, pay or delete) and
-- save a draft. Typing stays limited to the confirmed text in every mode.
--
-- Screenshots go to Anthropic's API and are never saved. Grandma's badge is hidden while each one
-- is taken, so it never covers what she needs to see.

local core = require("deepgram_dictation.core")
local screen = require("deepgram_dictation.screen")
local badge = require("deepgram_dictation.badge")

local M = {}

local API_URL = "https://api.anthropic.com/v1/messages"
local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local SETTLE = 0.15 -- seconds for the page to react after a click or typing
local NOT_EXECUTED = "Not executed: an earlier computer action in this turn failed."
-- hs.json turns an empty Lua table into [], but a tool_use input must go back as {}.
local EMPTY_OBJECT = "__deepgram_dictation_empty_object__"

local cfg, instructions, workInstructions, active
local DRAG_BIN = core.supportDir() .. "/GrandmaDrag"
-- Drag helpers in flight (an hs.task nothing refers to can be collected before it ends).
local draggers = {} -- luacheck: ignore 241

local openDialog -- defined below
local OPEN_BUTTONS = { Open = true, Choose = true, Upload = true, Select = true }

-- A macOS open dialog, when one is in front, with an Open-like button. Browsers show it as a sheet,
-- and then the focused window is the sheet itself (seen with Brave). Returns its element or nil.
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

-- Accessibility calls on a busy dialog can block for seconds; these give up quickly instead.
local function quick(el)
  if el then pcall(function() el:setTimeout(0.5) end) end
  return el
end

-- Whether a sheet or dialog is in front. Inside a file dialog we opened, this is that dialog,
-- or its "Go to folder" sheet (Go and Cancel, no Open button).
local function dialogInFront()
  local win = hs.window.focusedWindow()
  if not win then return false end
  local el = quick(hs.axuielement.windowElement(win))
  local ok, role = pcall(function() return el:attributeValue("AXRole") end)
  local oks, sub = pcall(function() return el:attributeValue("AXSubrole") end)
  local okt, sheets = pcall(function() return el:attributeValue("AXSheets") end)
  return (ok and role == "AXSheet") or (oks and (sub == "AXDialog" or sub == "AXSystemDialog"))
    or (okt and type(sheets) == "table" and #sheets > 0)
end

-- Closes whatever dialog was left open, so it can't cover the page.
local function closeDialogs()
  for _ = 1, 3 do
    if not dialogInFront() then return end
    hs.eventtap.keyStroke({}, "escape", 0)
    hs.timer.usleep(300000)
  end
end

openDialog = function()
  local win = hs.window.focusedWindow()
  if not win then return nil end
  local el = quick(hs.axuielement.windowElement(win))
  local candidates = {}
  local function get(e, name)
    local ok, value = pcall(function() return e:attributeValue(name) end)
    return ok and value or nil
  end
  local sub = get(el, "AXSubrole")
  if get(el, "AXRole") == "AXSheet" or sub == "AXDialog" or sub == "AXSystemDialog" then
    table.insert(candidates, el)
  end
  for _, sheet in ipairs(get(el, "AXSheets") or {}) do table.insert(candidates, sheet) end
  for _, child in ipairs(get(el, "AXChildren") or {}) do
    if get(child, "AXRole") == "AXSheet" then table.insert(candidates, child) end
  end
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
  local w = io.open(MODULE_DIR .. "/work_prompt.txt", "r")
  workInstructions = w and w:read("a")
  if w then w:close() end
  if not workInstructions then log("work_prompt.txt not found") end
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

-- The element at `point` and up to four of its ancestors, as { { role, label } } for
-- core.clickTarget.
local function chainAt(point)
  local chain, el = {}, element(point)
  while el and #chain < 5 do
    local label
    for _, name in ipairs({ "AXTitle", "AXDescription", "AXValue" }) do
      local v = attr(el, name)
      if not label and type(v) == "string" and v:match("%S") then label = v end
    end
    local role = attr(el, "AXRole")
    table.insert(chain, { role = role, label = label })
    if role == "AXWebArea" or role == "AXWindow" then break end
    el = attr(el, "AXParent")
  end
  return chain
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

-- A single click goes through hs.eventtap.leftClick: Chrome only opens a file picker for a click it
-- treats as a real gesture, and hand-built down/up events didn't count (make test-fill).
local function click(point, count)
  if count == 1 then return hs.eventtap.leftClick(point) end
  local types = hs.eventtap.event.types
  local state = hs.eventtap.event.properties.mouseEventClickState
  for n = 1, count do
    hs.eventtap.event.newMouseEvent(types.leftMouseDown, point):setProperty(state, n):post()
    hs.eventtap.event.newMouseEvent(types.leftMouseUp, point):setProperty(state, n):post()
  end
end

local KEY_NAMES = { backspace = "delete", delete = "forwarddelete" }

-- Selects `span` (an Accessibility range) in the focused box `el` holding `value`, with the keyboard:
-- Brave ignores selection set through Accessibility (it says yes and nothing moves). The whole box
-- is Cmd+A; part of it is Cmd+Up to its start, then arrows. `done(true)` once Accessibility reads
-- back exactly that selection.
local function selectSpan(el, value, span, done)
  local whole = core.wholeRange(value)
  local lead = #value:match("^%s*")
  local trail = #value:match("%s*$")
  if span.location <= lead and span.location + span.length >= whole.length - trail then
    span = whole
    hs.eventtap.keyStroke({ "cmd" }, "a", 0)
  else
    hs.eventtap.keyStroke({ "cmd" }, "up", 0)
    for _ = 1, span.location do hs.eventtap.keyStroke({}, "right", 0) end
    for _ = 1, span.length do hs.eventtap.keyStroke({ "shift" }, "right", 0) end
  end
  hs.timer.doAfter(0.2, function()
    local now = attr(el, "AXSelectedTextRange")
    done(type(now) == "table" and now.location == span.location and now.length == span.length)
  end)
end

-- Gets the box the user is typing in ready for grandma's `text`: selects `original` (text she read
-- off the screen and is replacing) when it is in there, or else the box's whole text when `text`
-- is a reworking of it (core.reworks), so the paste replaces it instead of landing next to it.
-- `done(how)`: "span", "all", or nil when nothing was selected (an empty box, other text, a box
-- that doesn't show its text, or a selection that didn't land).
function M.selectForPaste(original, text, done)
  -- nil when the box shows no text yet (maybe not exposed), else el, value, span or nil, how
  local function look()
    local el = focused()
    local value = el and attr(el, "AXValue")
    if type(value) ~= "string" or value == "" then return nil end
    local span = original and core.findSpan(value, original)
    if span then return el, value, span, "span" end
    if core.reworks(value, text) then return el, value, core.wholeRange(value), "all" end
    return el, value
  end
  local function go(el, value, span, how)
    if not span then return done(nil) end
    selectSpan(el, value, span, function(ok) done(ok and how or nil) end)
  end
  local el, value, span, how = look()
  if el then return go(el, value, span, how) end
  local app = hs.application.frontmostApplication()
  local wait = app and exposePage(app) or 0
  if wait == 0 then return done(nil) end
  hs.timer.doAfter(wait, function()
    local e, v, sp, h = look()
    if not e then return done(nil) end
    go(e, v, sp, h)
  end)
end

-- Fills `fields` ({ { label, value, skip } }, as confirmed) on `scr`. `progress(n)` is called before
-- each action; `done(summary, info)` exactly once, with info = { status = "done" | "stopped" |
-- "error" | "proposed", reason, ms, actions = { "left_click", ... } }.
-- `opts` (optional): { mode = "fill" | "survey" | "work", goal = what the user asked for, memory =
-- { blocks = { { name, text } }, images } for a survey }. A survey ends "proposed", with the
-- propose_changes input as `summary`.
function M.run(fields, scr, progress, done, opts)
  opts = opts or {}
  local mode = opts.mode or "fill"
  if mode ~= "fill" and not workInstructions then
    return done(nil, { status = "error", reason = "work_prompt.txt is missing", actions = {} })
  end
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

  local maxActions, maxSeconds
  if mode == "fill" then maxActions, maxSeconds = core.fillLimits(fields)
  else maxActions, maxSeconds = core.workLimits(mode) end
  local started = hs.timer.secondsSinceEpoch()
  local finished, body, menuOpen, uploading = false, nil, false, false
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
    -- Stopped in the middle of an upload: don't leave its file dialog over the page. Only while
    -- the page's app is still in front, so Esc can't go to an app the user switched to. After
    -- this returns, as it may be running inside the event watcher.
    if uploading then
      hs.timer.doAfter(0, function()
        local front = hs.application.frontmostApplication()
        if bundle and front and front:bundleID() == bundle and openDialog() then closeDialogs() end
      end)
    end
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
  deadline = hs.timer.doAfter(maxSeconds, function()
    finish(nil, "stopped", "it took longer than " .. maxSeconds .. " seconds")
  end)

  local function shoot(cb)
    badge.suspend()
    screen.capture(function(shot, err)
      badge.resume()
      cb(shot and shot.data, err)
    end, { screen = scr, size = size })
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
    local function fail(why)
      closeDialogs()
      cb(false, why)
    end
    hs.eventtap.keyStroke({ "cmd", "shift" }, "g", 0)
    hs.timer.doAfter(0.7, function()
      if finished then return end
      if not dialogInFront() then return fail("the file dialog closed") end
      hs.eventtap.keyStrokes(path)
      hs.timer.doAfter(0.5, function()
        if finished then return end
        if not dialogInFront() then return fail("the file dialog closed") end
        hs.eventtap.keyStroke({}, "return", 0) -- go to the file
        hs.timer.doAfter(0.9, function()
          if finished then return end
          if not dialogInFront() then return fail("the file dialog closed") end
          hs.eventtap.keyStroke({}, "return", 0) -- open it
          waitFor(function() return not dialogInFront() end, 3, function(closed)
            if closed then return cb(true) end
            fail("the file dialog didn't accept the file")
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
      if finished then
        finishDrag(false, "stopped")
        return true
      end
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
        -- Stopped while dragging: let go over the helper itself, which drops nothing.
        local drop = finished and start or target
        move(types.leftMouseDragged, drop)
        move(types.leftMouseUp, drop)
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
    local role, label = core.clickTarget(chainAt(target))
    local allowed, why = core.uploadClickAllowed(role, label)
    log("upload %s at %d,%d: %s %q, %s", file.name, target.x, target.y, tostring(role), tostring(label),
      allowed and "allowed" or why)
    if not allowed then return cb(res("Refused: " .. why, true), true) end
    uploading = true
    local function reply(result, failed)
      uploading = false
      cb(result, failed)
    end
    click(target, 1)
    local function waitForDialog(retry, after)
      waitFor(openDialog, 3, function(dialog)
        if finished then return end
        -- The first click on an upload button sometimes only focuses the page.
        if not dialog and retry and not core.dropTarget(role) then
          click(target, 1)
          return waitForDialog(false, after)
        end
        after(dialog)
      end)
    end
    waitForDialog(true, function(dialog)
      log("upload %s: %s", file.name, dialog and "file dialog open" or "no file dialog")
      -- A button that opened no dialog isn't a drop zone: dropping a file on it would make the
      -- browser open the file itself, possibly in place of the form.
      if not dialog and not core.dropTarget(role) then
        return reply(res("Error: that didn't open a file dialog, and it isn't a drop zone", true), true)
      end
      if dialog then
        return chooseInDialog(file.path, function(ok, err)
          log("upload %s: dialog %s", file.name, ok and "accepted the file" or tostring(err))
          if ok then return reply(res("OK: " .. file.name .. " chosen in the file dialog")) end
          reply(res("Error: " .. tostring(err), true), true)
        end)
      end
      dragOnto(file.path, target, function(ok, err)
        log("upload %s: drag %s", file.name, ok and "dropped" or tostring(err))
        if ok then return reply(res("OK: " .. file.name .. " dropped onto the drop zone")) end
        if openDialog() then hs.eventtap.keyStroke({}, "escape", 0) end -- never leave a picker open
        reply(res("Error: " .. tostring(err) .. ". Take a screenshot to see what the page shows.", true), true)
      end)
    end)
  end

  -- Runs one action, then calls cb(result, failed).
  local function runAction(a, cb)
    local function res(content, isError)
      return a.computer and core.fillResult(a.id, content, isError) or core.toolResult(a.id, content, isError)
    end
    if mode == "survey" and a.name == "propose_changes" then
      return finish(a.input, "proposed")
    end
    local ok, why
    if mode == "fill" then ok, why = core.checkFillAction(a.name, a.input, fields, uploaded)
    else ok, why = core.checkWorkAction(mode, a.name, a.input, fields, uploaded) end
    if not ok then return cb(res("Refused: " .. why, true), true) end
    if #actions >= maxActions then
      return finish(nil, "stopped", "it reached " .. maxActions .. " actions")
    end
    local front = hs.application.frontmostApplication()
    if bundle and (not front or front:bundleID() ~= bundle) then
      return finish(nil, "stopped", (front and front:name() or "another app") .. " came to the front")
    end
    table.insert(actions, a.name)
    progress(#actions)
    local detail = a.input.coordinate and string.format(" at %s,%s", tostring(a.input.coordinate[1]),
      tostring(a.input.coordinate[2])) or a.input.text and string.format(" %q", tostring(a.input.text):sub(1, 30)) or ""
    log("%d %s%s", #actions, a.name, detail)
    local input = a.input
    if not a.computer and (a.name ~= "upload_file" or mode == "survey") then
      return cb(res("Refused: unknown tool", true), true)
    end
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
      badge.suspend()
      return screen.capture(function(shot, err)
        badge.resume()
        if shot then return cb(core.fillImage(a.id, shot.data)) end
        cb(res("Error: " .. tostring(err), true), true)
      end, { screen = scr, rect = { x = p0.x, y = p0.y, w = p1.x - p0.x, h = p1.y - p0.y } })
    elseif a.name == "left_click" or a.name == "triple_click" or a.name == "double_click" then
      local point = input.coordinate and core.fillPoint(input.coordinate, frame, scale) or hs.mouse.absolutePosition()
      if not point then return cb(res("Error: coordinate outside the screen", true), true) end
      local el = element(point)
      local role, subrole = attr(el, "AXRole"), attr(el, "AXSubrole")
      local allowed, reason
      if mode == "work" then
        local target, label = core.clickTarget(chainAt(point))
        local unchecked
        allowed, reason, unchecked = core.workClickAllowed(target, subrole, label)
        if unchecked then log("click on an unlabelled %s: its name can't be checked", tostring(target)) end
      else
        allowed, reason = core.fillClickAllowed(role, subrole, menuOpen)
      end
      if not allowed then return cb(res("Refused: " .. reason, true), true) end
      menuOpen = role == "AXPopUpButton" or role == "AXComboBox"
      click(point, a.name == "triple_click" and 3 or a.name == "double_click" and 2 or 1)
      return after(res("OK"))
    end
    -- Typing and keys go to whatever has the focus, so that is checked too.
    local f
    if a.name == "type" or a.name == "key" then
      f = focused()
      local allowed, reason = core.fillFocusAllowed(a.name, input, attr(f, "AXRole"), attr(f, "AXSubrole"))
      if not allowed then return cb(res("Refused: " .. reason, true), true) end
      if a.name == "key" and core.NEWLINE_KEYS[core.keyCombo(input.text)] and attr(f, "AXRole") ~= "AXTextArea" then
        return cb(res("Refused: Return only goes into a multi-line text box", true), true)
      end
    end

    if a.name == "type" then
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
      if resp.stop_reason == "refusal" then return finish(nil, "error", "Claude declined to do this") end
      if resp.stop_reason == "max_tokens" then return finish(nil, "error", "Claude's reply was cut off") end
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
      if mode == "fill" then body = core.fillRequest(cfg, instructions, fields, data)
      else body = core.workRequest(cfg, workInstructions, mode, opts.goal or "", fields, data, opts.memory) end
      post()
    end)
  end)
end

return M
