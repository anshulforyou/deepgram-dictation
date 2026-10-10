-- Detects online meetings: when Zoom, Teams, Slack, a browser on Google Meet, etc. starts using
-- the microphone, offers to transcribe; when a meeting started that way ends, stops and
-- transcribes it.
--
-- Which apps are using the mic comes from `DeepgramRecorder --mic-users` (Core Audio process
-- list). For browsers, the open tabs' URLs are read with AppleScript to tell a Meet call from
-- any other page that uses the mic (macOS asks once for permission to control the browser).

local core = require("deepgram_dictation.core")
local prompt = require("deepgram_dictation.prompt")

local M = {}

local POLL_SECONDS = 3
local END_GRACE = { app = 60, browser = 30 } -- seconds a meeting must be gone before auto-stop

local cfg, meeting
local pollTimer, listTask
local offered = {}  -- source key -> true while that source keeps using the mic
local endTracker

local function log(fmt, ...) print("[deepgram-dictation] detector: " .. string.format(fmt, ...)) end

local function recorderBinary()
  return meeting.recorderApp() .. "/Contents/MacOS/DeepgramRecorder"
end

local function listMicUsers(callback)
  if listTask then return end
  listTask = hs.task.new(recorderBinary(), function(_, stdout)
    listTask = nil
    local ok, list = pcall(hs.json.decode, stdout or "")
    callback(ok and type(list) == "table" and list or {})
  end, { "--mic-users" })
  if not listTask:start() then listTask = nil end
end

local TAB_URLS_SCRIPT = [[
tell application id "%s"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      set out to out & (URL of t) & linefeed
    end repeat
  end repeat
  return out
end tell]]

-- Calls back with the meeting service open in a browser ("Google Meet", ...) or nil.
local function browserMeeting(browser, callback)
  local app = hs.application.get(browser.app)
  if not app then return callback(nil) end
  local titles = {}
  for _, w in ipairs(app:allWindows()) do table.insert(titles, w:title() or "") end
  local fromTitles = core.meetingFromTitles(titles)
  if not browser.script then return callback(fromTitles) end

  hs.task.new("/usr/bin/osascript", function(code, stdout)
    local urls = {}
    if code == 0 then
      for line in (stdout or ""):gmatch("[^\n]+") do table.insert(urls, line) end
    end
    callback(core.meetingFromUrls(urls) or fromTitles)
  end, { "-e", string.format(TAB_URLS_SCRIPT, browser.app) }):start()
end

local function sourcesFrom(list)
  local sources, order = {}, {}
  for _, entry in ipairs(list) do
    local source = core.classifyMicUser(entry.bundleID)
    if source and not sources[source.key] then
      sources[source.key] = source
      table.insert(order, source)
    end
  end
  return sources, order
end

local function offer(source, service)
  log("detected %s (%s)", service, source.key)
  local title = service .. " detected" .. (source.kind == "browser" and (" in " .. source.name) or "")
  prompt.show(title, "Transcribe this meeting?", "Transcribe", function()
    local browser = source.browser or {}
    meeting.start("online", {
      key = source.key, name = service, kind = source.kind, app = browser.app, script = browser.script,
    })
  end)
end

local function checkForNewMeetings(order)
  for _, source in ipairs(order) do
    if not offered[source.key] then
      offered[source.key] = true
      if source.kind == "app" then
        offer(source, source.name)
      else
        browserMeeting(source.browser, function(service)
          if service and meeting.state() == "idle" then offer(source, service) end
        end)
      end
    end
  end
end

local function checkForMeetingEnd(sources)
  local source = meeting.source()
  if not (cfg.autoStopMeetings and source) then return end
  endTracker = endTracker or core.newEndTracker(END_GRACE[source.kind] or 60)

  local function decide(present)
    if meeting.state() ~= "recording" then return end
    if endTracker(present, hs.timer.secondsSinceEpoch()) then
      log("%s ended; stopping", source.name)
      endTracker = nil
      meeting.stop(source.name .. " ended")
    end
  end

  if sources[source.key] then return decide(true) end
  if source.kind == "browser" and source.app then
    -- Muted in Meet can release the mic; keep going while the call tab is still open.
    browserMeeting({ app = source.app, script = source.script }, function(service) decide(service ~= nil) end)
  else
    decide(false)
  end
end

local function poll()
  local state = meeting.state()
  if state == "idle" then
    endTracker = nil
    local device = hs.audiodevice.defaultInputDevice()
    if not (device and device:inUse()) then
      offered = {}
      if prompt.isShown() then prompt.hide() end
      return
    end
  elseif state ~= "recording" then
    return
  end

  listMicUsers(function(list)
    local sources, order = sourcesFrom(list)
    for key in pairs(offered) do
      if not sources[key] then offered[key] = nil end
    end
    if meeting.state() == "idle" then
      if #order == 0 and prompt.isShown() then prompt.hide() end
      checkForNewMeetings(order)
    elseif meeting.state() == "recording" then
      -- Don't offer again for the meeting being recorded.
      for key in pairs(sources) do offered[key] = true end
      checkForMeetingEnd(sources)
    end
  end)
end

function M.setup(config, meetingModule)
  cfg, meeting = config, meetingModule
  if not cfg.detectMeetings then return end
  pollTimer = hs.timer.doEvery(POLL_SECONDS, poll)
end

function M.teardown()
  if pollTimer then pollTimer:stop() pollTimer = nil end
  if listTask then listTask:terminate() listTask = nil end
  prompt.hide()
  offered, endTracker = {}, nil
end

return M
