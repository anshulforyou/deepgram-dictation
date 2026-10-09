-- Meeting transcription: drives DeepgramRecorder.app (records mic and, for online meetings,
-- computer audio), then meeting_transcribe.py (Deepgram + Markdown). The finished transcript is
-- copied to the clipboard and saved under transcriptsDir.
--
-- State lives on disk (one session dir per recording, with the recorder's status.json), so a
-- Hammerspoon reload during a meeting picks the recording back up.

local core = require("deepgram_dictation.core")

local M = {}

local SUPPORT_DIR = os.getenv("HOME") .. "/Library/Application Support/deepgram-dictation"
local SESSIONS_DIR = SUPPORT_DIR .. "/meetings"
local SCRIPT = hs.configdir .. "/deepgram_dictation/meeting_transcribe.py"

local cfg, dictPath, onChange
local state = "idle" -- idle | starting | recording | stopping | transcribing
local session, pollTimer, tickTimer, transcriber
local lastTranscript

local function log(fmt, ...) print("[deepgram-dictation] meeting: " .. string.format(fmt, ...)) end
local function changed() if onChange then onChange() end end

local function exists(path) return hs.fs.attributes(path) ~= nil end

local function readStatus(dir)
  local f = io.open(dir .. "/status.json", "r")
  if not f then return nil end
  local raw = f:read("a")
  f:close()
  local ok, data = pcall(hs.json.decode, raw)
  return ok and data or nil
end

local function processAlive(pid)
  local _, ok = hs.execute("/bin/kill -0 " .. math.floor(tonumber(pid) or 0) .. " 2>/dev/null")
  return ok == true
end

local function stopTimers()
  if pollTimer then pollTimer:stop() pollTimer = nil end
  if tickTimer then tickTimer:stop() tickTimer = nil end
end

local function notify(title, text, path)
  hs.notify.new(path and function() hs.execute("/usr/bin/open " .. string.format("%q", path)) end or nil, {
    title = title, informativeText = text, withdrawAfter = 10,
  }):send()
end

local function setState(new)
  state = new
  changed()
end

-- Polls `check()` every 0.5 s until it returns true or `timeout` seconds pass.
local function pollUntil(check, timeout, onTimeout)
  if pollTimer then pollTimer:stop() end
  local deadline = hs.timer.secondsSinceEpoch() + timeout
  pollTimer = hs.timer.doEvery(0.5, function()
    if check() then
      pollTimer:stop() pollTimer = nil
    elseif hs.timer.secondsSinceEpoch() > deadline then
      pollTimer:stop() pollTimer = nil
      onTimeout()
    end
  end)
end

local function beginRecordingState(dir, startedAt, online)
  session = { dir = dir, startedAt = startedAt, online = online }
  tickTimer = hs.timer.doEvery(1, changed)
  setState("recording")
end

local function transcribe(dir)
  local python = cfg.python
    or core.findExecutable(exists, core.PYTHON_CANDIDATES)
  if not python then
    hs.alert.show("python3 not found. Install the Xcode Command Line Tools.")
    setState("idle")
    return
  end
  setState("transcribing")
  local args = core.transcribeArgs(cfg, SCRIPT, dir, M.transcriptsDir(), dictPath)
  transcriber = hs.task.new(python, function(_, stdout, stderr)
    transcriber = nil
    local result, err = core.parseResultLine(stdout, hs.json.decode)
    if not result then
      log("transcription failed: %s %s", tostring(err), tostring(stderr))
      notify("Meeting transcription failed", tostring(err) .. "\nUse the 🎙 menu to retry.")
      setState("idle")
      return
    end
    local f = io.open(result.path, "r")
    if f then
      hs.pasteboard.setContents(f:read("a"))
      f:close()
    end
    lastTranscript = result.path
    notify("Meeting transcript copied",
      string.format("%d words · %s\nPaste it anywhere, or click to open.", result.words or 0,
        table.concat(result.speakers or {}, ", ")),
      result.path)
    log("saved %s", result.path)
    setState("idle")
  end, args)
  transcriber:start()
end

function M.start(mode)
  if state ~= "idle" then return end
  local online = (mode or cfg.meetingMode) == "online"
  local app = M.recorderApp()
  if not exists(app) then
    hs.alert.show("DeepgramRecorder.app not found. Re-run install.sh.")
    return
  end

  local dir = SESSIONS_DIR .. "/" .. core.sessionName(os.date("*t"))
  hs.fs.mkdir(SUPPORT_DIR)
  hs.fs.mkdir(SESSIONS_DIR)
  hs.fs.mkdir(dir)
  local args = { "-n", "-a", app, "--args", "--out", dir }
  if online then table.insert(args, "--system") end
  hs.task.new("/usr/bin/open", nil, args):start()
  setState("starting")

  pollUntil(function()
    local status = readStatus(dir)
    if not status then return false end
    if status.state == "recording" then
      beginRecordingState(dir, hs.timer.secondsSinceEpoch(), online)
      hs.alert.show(online and "🔴 Recording meeting (mic + computer audio)" or "🔴 Recording meeting (mic)", 2)
      for _, w in ipairs(status.warnings or {}) do hs.alert.show(w, 6) end
      return true
    elseif status.state == "error" then
      hs.alert.show("Couldn't start recording: " .. tostring(status.error), 6)
      setState("idle")
      return true
    end
    return false
  end, 90, function()
    hs.alert.show("Recorder didn't start. Check Microphone permission for DeepgramRecorder.", 6)
    setState("idle")
  end)
end

local function signalRecorder(dir, sig)
  local f = io.open(dir .. "/recorder.pid", "r")
  if not f then return false end
  local pid = tonumber(f:read("l"))
  f:close()
  if not pid then return false end
  hs.execute("/bin/kill -" .. sig .. " " .. math.floor(pid))
  return true
end

local function finishStopping(dir, andThen)
  setState("stopping")
  stopTimers()
  pollUntil(function()
    local status = readStatus(dir)
    if status and status.state == "stopped" then andThen() return true end
    return false
  end, 20, function()
    log("recorder did not report stop; continuing anyway")
    andThen()
  end)
end

function M.stop()
  if state ~= "recording" or not session then return end
  local dir = session.dir
  session = nil
  signalRecorder(dir, "INT")
  finishStopping(dir, function() transcribe(dir) end)
end

function M.discard()
  if state ~= "recording" or not session then return end
  local dir = session.dir
  session = nil
  signalRecorder(dir, "INT")
  finishStopping(dir, function()
    hs.execute("/bin/rm -rf " .. string.format("%q", dir))
    hs.alert.show("Recording discarded", 2)
    setState("idle")
  end)
end

function M.toggle()
  if state == "idle" then M.start() elseif state == "recording" then M.stop() end
end

-- Session dirs left from earlier (failed transcription, or Hammerspoon restarted mid-pipeline).
function M.pendingSessions()
  local pending = {}
  if not exists(SESSIONS_DIR) then return pending end
  for name in hs.fs.dir(SESSIONS_DIR) do
    local dir = SESSIONS_DIR .. "/" .. name
    if name:sub(1, 1) ~= "." and (not session or session.dir ~= dir) then
      local status = readStatus(dir)
      if status and status.state == "stopped" and not exists(dir .. "/transcript.txt") then
        table.insert(pending, { name = name, dir = dir })
      end
    end
  end
  table.sort(pending, function(a, b) return a.name > b.name end)
  return pending
end

-- Picks up a recording that was running before Hammerspoon reloaded.
local function adoptRunningSession()
  if not exists(SESSIONS_DIR) then return end
  for name in hs.fs.dir(SESSIONS_DIR) do
    local dir = SESSIONS_DIR .. "/" .. name
    local status = name:sub(1, 1) ~= "." and readStatus(dir)
    if status and status.state == "recording" and processAlive(status.pid) then
      local elapsed = 0
      local attrs = hs.fs.attributes(dir .. "/status.json")
      if attrs then elapsed = os.time() - attrs.modification end
      beginRecordingState(dir, hs.timer.secondsSinceEpoch() - elapsed, status.captureSystem)
      log("resumed tracking recording %s", name)
      return
    end
  end
end

function M.recorderApp() return cfg.recorderApp or (SUPPORT_DIR .. "/DeepgramRecorder.app") end
function M.transcriptsDir() return cfg.transcriptsDir or (os.getenv("HOME") .. "/Documents/Meeting Transcripts") end
function M.state() return state end

function M.elapsed()
  return session and (hs.timer.secondsSinceEpoch() - session.startedAt) or 0
end

function M.menubarTitle()
  if state == "recording" then return "🔴 " .. core.formatElapsed(M.elapsed()) end
  if state == "starting" or state == "stopping" or state == "transcribing" then return "⏳" end
  return nil
end

function M.menuItems()
  local items = {}
  if state == "idle" then
    table.insert(items, { title = "Transcribe online meeting (mic + computer audio)",
                          fn = function() M.start("online") end })
    table.insert(items, { title = "Transcribe in-person meeting (mic only)",
                          fn = function() M.start("inPerson") end })
  elseif state == "recording" then
    table.insert(items, { title = "Stop & transcribe (" .. core.formatElapsed(M.elapsed()) .. ")", fn = M.stop })
    table.insert(items, { title = "Discard recording", fn = M.discard })
  else
    local label = ({ starting = "Starting recorder…", stopping = "Finishing recording…",
                     transcribing = "Transcribing meeting…" })[state]
    table.insert(items, { title = label, disabled = true })
  end
  if lastTranscript then
    table.insert(items, { title = "Copy last transcript", fn = function()
      local f = io.open(lastTranscript, "r")
      if f then hs.pasteboard.setContents(f:read("a")) f:close() hs.alert.show("Transcript copied", 1) end
    end })
  end
  table.insert(items, { title = "Open transcripts folder", fn = function()
    hs.fs.mkdir(M.transcriptsDir())
    hs.execute("/usr/bin/open " .. string.format("%q", M.transcriptsDir()))
  end })
  if state == "idle" then
    for _, p in ipairs(M.pendingSessions()) do
      table.insert(items, { title = "Retry transcription: " .. p.name, fn = function() transcribe(p.dir) end })
    end
  end
  return items
end

function M.setup(config, dictionaryPath, changeCallback)
  cfg, dictPath, onChange = config, dictionaryPath, changeCallback
  if cfg.meetingHotkey then
    M.hotkey = hs.hotkey.bind(cfg.meetingHotkey.mods, cfg.meetingHotkey.key, M.toggle)
  end
  adoptRunningSession()
end

-- Releases hotkeys and timers. A running recording keeps going and is re-adopted on next setup.
function M.teardown()
  if M.hotkey then M.hotkey:delete() M.hotkey = nil end
  stopTimers()
  session = nil
  state = "idle"
end

return M
