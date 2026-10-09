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

local function readSource(dir)
  local f = io.open(dir .. "/source.json", "r")
  if not f then return nil end
  local raw = f:read("a")
  f:close()
  local ok, data = pcall(hs.json.decode, raw)
  return ok and type(data) == "table" and data or nil
end

local function beginRecordingState(dir, startedAt, online, source)
  session = { dir = dir, startedAt = startedAt, online = online, source = source }
  tickTimer = hs.timer.doEvery(1, changed)
  setState("recording")
end

local function claudePath()
  if not cfg.organizeWithClaude then return nil end
  if cfg.claudePath then return cfg.claudePath end
  local home = os.getenv("HOME")
  local candidates = {}
  for _, p in ipairs(core.CLAUDE_CANDIDATES) do table.insert(candidates, (p:gsub("^~", home))) end
  local found = core.findExecutable(exists, candidates)
  if not found then log("organizeWithClaude is on but the claude CLI was not found") end
  return found
end

local onTranscribed -- defined below

local function transcribe(dir)
  local python = cfg.python
    or core.findExecutable(exists, core.PYTHON_CANDIDATES)
  if not python then
    hs.alert.show("python3 not found. Install the Xcode Command Line Tools.")
    setState("idle")
    return
  end
  setState("transcribing")
  local args = core.transcribeArgs(cfg, SCRIPT, dir, M.transcriptsDir(), dictPath, claudePath())
  transcriber = hs.task.new(python, function(_, stdout, stderr)
    transcriber = nil
    -- Never leave the menu stuck on "Transcribing…", whatever goes wrong below.
    local ok, err = xpcall(onTranscribed, debug.traceback, stdout, stderr)
    if not ok then
      pcall(log, "unexpected error: %s", tostring(err))
      notify("Meeting transcription failed", "Unexpected error, see the Hammerspoon console. Use the 🎙 menu to retry.")
      setState("idle")
    end
  end, args)
  transcriber:start()
end

onTranscribed = function(stdout, stderr)
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
  local where = result.folder and ("Filed in " .. result.folder .. " · ") or ""
  if result.organizeError then
    log("organizing failed: %s", result.organizeError)
    where = "Not filed (" .. result.organizeError .. ") · "
  end
  notify(result.title and ("Copied: " .. result.title) or "Meeting transcript copied",
    string.format("%s%d words · %s\nPaste it anywhere, or click to open.", where, result.words or 0,
      table.concat(result.speakers or {}, ", ")),
    result.path)
  log("saved %s", result.path)
  setState("idle")
end

-- `source` (optional) describes a detected meeting, e.g. { key = "us.zoom.xos", name = "Zoom",
-- kind = "app" }; the detector uses it to stop recording when that meeting ends.
function M.start(mode, source)
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
  if source then hs.json.write(source, dir .. "/source.json", false, true) end
  local args = { "-n", "-a", app, "--args", "--out", dir }
  if online then table.insert(args, "--system") end
  hs.task.new("/usr/bin/open", nil, args):start()
  setState("starting")

  pollUntil(function()
    local status = readStatus(dir)
    if not status then return false end
    if status.state == "recording" then
      beginRecordingState(dir, hs.timer.secondsSinceEpoch(), online, source)
      local what = source and source.name or (online and "meeting (mic + computer audio)" or "meeting (mic)")
      hs.alert.show("🔴 Recording " .. what, 2)
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

-- `reason` (optional) is shown as a notification, e.g. when a detected meeting ended.
function M.stop(reason)
  if state ~= "recording" or not session then return end
  if reason then notify(reason, "Transcribing the meeting…") end
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

-- Transcripts saved at the top of transcriptsDir, i.e. not yet filed into a topic folder
-- (Claude was unavailable or organizing was off when they were made).
function M.unfiledTranscripts()
  local list, root = {}, M.transcriptsDir()
  if not exists(root) then return list end
  for name in hs.fs.dir(root) do
    if name:match("%.md$") and name ~= "meetings.md" and name:sub(1, 1) ~= "." then
      table.insert(list, root .. "/" .. name)
    end
  end
  table.sort(list)
  return list
end

-- Files the given transcripts one after another with Claude.
local function refileAll(paths)
  local python = cfg.python or core.findExecutable(exists, core.PYTHON_CANDIDATES)
  local claude = claudePath()
  if not (python and claude) then
    hs.alert.show("Filing needs python3 and the claude CLI")
    return
  end
  local filed, failed = {}, {}
  local function nextOne(i)
    if i > #paths then
      notify(string.format("Filed %d transcript%s", #filed, #filed == 1 and "" or "s"),
        (#filed > 0 and ("Into: " .. table.concat(filed, ", ")) or "")
          .. (#failed > 0 and ("\nNot filed: " .. failed[1]) or ""))
      setState("idle")
      return
    end
    local args = { SCRIPT, "--refile", paths[i], "--output-dir", M.transcriptsDir(), "--organize-with-claude", claude }
    if cfg.claudeModel then table.insert(args, "--claude-model") table.insert(args, cfg.claudeModel) end
    hs.task.new(python, function(_, stdout)
      local ok, result = pcall(hs.json.decode, (stdout or ""):match("([^\n]+)%s*$") or "{}")
      if ok and type(result) == "table" and result.folder then
        table.insert(filed, result.folder)
        log("filed %s into %s", paths[i], result.folder)
      else
        local err = ok and type(result) == "table" and result.error or "unexpected output"
        table.insert(failed, tostring(err))
        log("could not file %s: %s", paths[i], tostring(err))
      end
      nextOne(i + 1)
    end, args):start()
  end
  setState("transcribing")
  nextOne(1)
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
      beginRecordingState(dir, hs.timer.secondsSinceEpoch() - elapsed, status.captureSystem, readSource(dir))
      log("resumed tracking recording %s", name)
      return
    end
  end
end

function M.recorderApp() return cfg.recorderApp or (SUPPORT_DIR .. "/DeepgramRecorder.app") end
function M.transcriptsDir() return cfg.transcriptsDir or (os.getenv("HOME") .. "/Documents/Meeting Transcripts") end
function M.state() return state end
function M.source() return session and session.source or nil end

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
    local what = session.source and (session.source.name .. " ") or ""
    table.insert(items, { title = "Stop & transcribe " .. what .. "(" .. core.formatElapsed(M.elapsed()) .. ")",
                          fn = function() M.stop() end })
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
  if state == "idle" and cfg.organizeWithClaude then
    local unfiled = M.unfiledTranscripts()
    if #unfiled > 0 then
      table.insert(items, { title = string.format("File %d unfiled transcript%s with Claude", #unfiled,
        #unfiled == 1 and "" or "s"), fn = function() refileAll(unfiled) end })
    end
  end
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
