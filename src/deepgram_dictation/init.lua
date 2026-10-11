-- deepgram-dictation: hold a key, speak, release, and the Deepgram transcript is pasted at
-- the cursor. Hammerspoon glue around the pure logic in core.lua.
--
-- Usage in ~/.hammerspoon/init.lua:
--   deepgramDictation = require("deepgram_dictation")
--   deepgramDictation.start({ language = "en" })

local core = require("deepgram_dictation.core")
local meeting = require("deepgram_dictation.meeting")
local detector = require("deepgram_dictation.detector")
local cleanup = require("deepgram_dictation.cleanup")
local history = require("deepgram_dictation.history")

local M = { core = core, meeting = meeting }

local cfg, dictPath, recBinary
local audioPath = (os.getenv("TMPDIR") or "/tmp/") .. "deepgram-dictation.wav"
local enabled = true
local recorder, startedAt, releasedAt, cancelled, sendOnExit
local delivered = 0
local indicator, menubar, apiKey

local function log(fmt, ...) print("[deepgram-dictation] " .. string.format(fmt, ...)) end

local function getApiKey()
  if apiKey then return apiKey end
  local out, ok = hs.execute("/usr/bin/security find-generic-password -s '" .. cfg.keychainName .. "' -w")
  if ok and out and out:match("%S") then apiKey = out:gsub("%s+$", "") end
  return apiKey
end

local function loadDictionary()
  local f = io.open(dictPath, "r")
  if not f then return core.normalizeDictionary(nil) end
  local raw = f:read("a")
  f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if not ok then log("could not parse %s", dictPath) end
  return core.normalizeDictionary(ok and data or nil)
end

local function setIndicator(label)
  if indicator then hs.alert.closeSpecific(indicator) indicator = nil end
  if label then indicator = hs.alert.show(label, { textSize = 16, radius = 10 }, "infinite") end
end

local function pasteText(text)
  local saved = cfg.restoreClipboard and hs.pasteboard.readAllData() or nil
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  if saved then
    hs.timer.doAfter(0.5, function() hs.pasteboard.writeAllData(saved) end)
  end
end

-- Cleans the transcript, pastes it and records the dictation. The recording is moved off
-- audioPath first, so a dictation started while this one is still being cleaned can't clobber it.
local function deliver(raw, dict, via)
  local transcribedAt = hs.timer.secondsSinceEpoch()
  delivered = delivered + 1
  local recording = audioPath:gsub("%.wav$", "-" .. delivered .. ".wav")
  if not os.rename(audioPath, recording) then recording = audioPath end
  local record = {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"), via = via, model = cfg.model, language = cfg.language,
    seconds = releasedAt and startedAt and math.floor((releasedAt - startedAt) * 100 + 0.5) / 100,
    deepgramMs = releasedAt and math.floor((transcribedAt - releasedAt) * 1000 + 0.5),
    raw = raw,
  }
  if raw == "" then return history.save(recording, record) end
  local names = cleanup.namesFor(dict)
  cleanup.run(raw, names, function(text, info)
    local pasted = core.applyReplacements(text, dict.replacements)
    setIndicator(nil)
    pasteText(pasted)
    record.cleanup = info
    record.cleaned = info.status == "ok" and text or nil
    record.pasted = pasted
    history.save(recording, record)
  end)
end

local function transcribe()
  local key = getApiKey()
  if not key then
    setIndicator(nil)
    hs.alert.show("Deepgram API key not found in Keychain ('" .. cfg.keychainName .. "')")
    return
  end
  local f = io.open(audioPath, "rb")
  if not f then setIndicator(nil) return end
  local audio = f:read("a")
  f:close()

  local dict = loadDictionary()
  local _, keyterms = cleanup.namesFor(dict)
  setIndicator("⏳ Transcribing…")
  hs.http.asyncPost(core.buildListenUrl(cfg, keyterms), audio, {
    ["Authorization"] = "Token " .. key,
    ["Content-Type"] = "audio/wav",
  }, function(status, body)
    if status ~= 200 then
      setIndicator(nil)
      os.remove(audioPath)
      log("HTTP %s: %s", tostring(status), tostring(body))
      if status == 401 or status == 403 then apiKey = nil end
      hs.alert.show("Deepgram error (" .. tostring(status) .. "), see Hammerspoon console")
      return
    end
    local ok, resp = pcall(hs.json.decode, body)
    local text, err = core.extractTranscript(ok and resp or nil)
    if not text then
      setIndicator(nil)
      os.remove(audioPath)
      log("bad response: %s", err)
      hs.alert.show("Deepgram returned an unexpected response")
      return
    end
    if text == "" then
      setIndicator(nil)
      hs.alert.show("No speech detected", 1)
    end
    deliver(text, dict, "upload")
  end)
end

-- "No speech detected", plus a hint when the recording was nearly silent (e.g. a quiet AirPods mic).
local function alertNoSpeech()
  local f = io.open(audioPath, "rb")
  local peak = f and core.wavPeak(f:read("a"))
  if f then f:close() end
  local device = hs.audiodevice.defaultInputDevice()
  local hint = core.noSpeechHint(device and device:name(), device and device:inputVolume(), peak)
  if hint then log("no speech: %s (peak %.4f)", hint, peak) end
  hs.alert.show("No speech detected" .. (hint and ("\n" .. hint) or ""), hint and 5 or 1)
end

local function finishStreaming(stdout, dict)
  if not sendOnExit then
    os.remove(audioPath)
    setIndicator(nil)
    return
  end
  local result = core.parseStreamOutput(stdout, hs.json.decode) or {}
  if type(result.transcript) == "string" then
    if result.transcript == "" then
      setIndicator(nil)
      alertNoSpeech()
    end
    deliver(result.transcript, dict, "stream")
  else
    -- Streaming failed (e.g. network blip): upload the saved recording instead.
    log("streaming failed (%s); falling back to upload", tostring(result.error or stdout))
    transcribe()
  end
end

-- Streams audio to Deepgram while the key is held (much faster than uploading afterwards).
local function startStreaming(helper)
  local key = getApiKey()
  if not key then
    hs.alert.show("Deepgram API key not found in Keychain ('" .. cfg.keychainName .. "')")
    return
  end
  local dict = loadDictionary()
  local _, keyterms = cleanup.namesFor(dict)
  local output, live = "", false
  recorder = hs.task.new(helper, function(_, stdout)
    recorder = nil
    finishStreaming(output .. (stdout or ""), dict)
  end, function(_, stdout)
    output = output .. (stdout or "")
    -- Bluetooth mics (AirPods) take a moment to switch on; say when they're actually live.
    if not live and recorder and not sendOnExit and output:find('"event":"listening"', 1, true) then
      live = true
      setIndicator("🎙 Listening…")
    end
    return true
  end, { "--stream", "--url", core.buildStreamUrl(cfg, keyterms), "--save", audioPath })
  recorder:setEnvironment({
    DEEPGRAM_API_KEY = key, HOME = os.getenv("HOME"), TMPDIR = os.getenv("TMPDIR"), PATH = "/usr/bin:/bin",
  })
  if not recorder:start() then
    recorder = nil
    hs.alert.show("Could not start recording, see Hammerspoon console")
    return
  end
  setIndicator("🎧 Connecting mic…")
end

local function startRecording()
  os.remove(audioPath)
  cancelled, sendOnExit = false, false
  startedAt = hs.timer.secondsSinceEpoch()
  local helper = meeting.recorderApp() .. "/Contents/MacOS/DeepgramRecorder"
  if cfg.streaming and hs.fs.attributes(helper) then return startStreaming(helper) end
  if not recBinary then
    hs.alert.show("deepgram-dictation: sox not found. Run `brew install sox`.")
    return
  end
  recorder = hs.task.new(recBinary, function()
    recorder = nil
    if sendOnExit then
      transcribe()
    else
      os.remove(audioPath)
      setIndicator(nil)
    end
  end, { "-q", "-c", "1", "-r", "16000", "-b", "16", audioPath })
  if not recorder:start() then
    recorder = nil
    hs.alert.show("Could not start recording, see Hammerspoon console")
    return
  end
  setIndicator("🎙 Listening…")
end

local function stopRecording()
  if not recorder then return end
  releasedAt = hs.timer.secondsSinceEpoch()
  local duration = releasedAt - startedAt
  sendOnExit = core.shouldTranscribe(duration, cancelled, cfg.minSeconds)
  if sendOnExit then
    setIndicator("⏳ Transcribing…")
    recorder:interrupt() -- SIGINT: sox finalises the WAV / the streamer flushes Deepgram's results
  else
    recorder:terminate() -- SIGTERM: discard
  end
end

local function updateMenubar()
  if not menubar then return end
  menubar:setTitle(meeting.menubarTitle() or (enabled and "🎙" or "🎙✕"))
end

-- Built on every click so meeting items reflect the current state.
local function buildMenu()
  local status = "Dictation: " .. (enabled and "on" or "off") .. " (hold " .. cfg.hotkey .. ")"
  local items = {
    { title = status, disabled = true },
    { title = enabled and "Disable dictation" or "Enable dictation",
      fn = function() enabled = not enabled updateMenubar() end },
    { title = "-" },
  }
  if history.enabled() then
    table.insert(items, { title = "Flag last dictation as wrong", fn = function()
      local record = history.flagLast()
      hs.alert.show(record and "Flagged. Find it in the dictation history." or "No saved dictation yet", 2)
    end })
    table.insert(items, { title = "Open dictation history", fn = function()
      hs.fs.mkdir(history.dir())
      hs.open(history.dir())
    end })
    table.insert(items, { title = "-" })
  end
  for _, item in ipairs(meeting.menuItems()) do table.insert(items, item) end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Reload Hammerspoon config", fn = hs.reload })
  return items
end

function M.start(overrides)
  M.stop()
  cfg = core.mergeConfig(overrides)
  dictPath = cfg.dictionary or (hs.configdir .. "/deepgram-dictionary.json")
  -- sox is only needed when streaming is off or DeepgramRecorder.app isn't built.
  recBinary = cfg.recBinary
    or core.findExecutable(function(p) return hs.fs.attributes(p) ~= nil end, core.REC_CANDIDATES)

  M.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
    if not enabled then return false end
    local transition = core.hotkeyTransition(cfg.hotkey, e:getKeyCode(), e:getFlags(), recorder ~= nil)
    if transition == "press" then startRecording()
    elseif transition == "release" then stopRecording() end
    return false
  end):start()

  -- Hotkey used as a modifier for another key (e.g. Fn+F5): cancel this dictation.
  M.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
    if recorder then cancelled = true end
    return false
  end):start()

  if cfg.showMenubar then
    -- The autosave name keeps the icon where you ⌘-drag it across reloads.
    menubar = hs.menubar.new(true, "deepgram-dictation")
    menubar:setMenu(buildMenu)
  end
  -- Opens the same menu at the mouse pointer, for when the menu bar icon is hidden (e.g. by the notch).
  if cfg.menuHotkey then
    M.popup = hs.menubar.new(false)
    M.menuHotkey = hs.hotkey.bind(cfg.menuHotkey.mods, cfg.menuHotkey.key, function()
      M.popup:setMenu(buildMenu())
      M.popup:popupMenu(hs.mouse.absolutePosition(), true)
    end)
  end
  cleanup.setup(cfg)
  history.setup(cfg)
  meeting.setup(cfg, dictPath, updateMenubar)
  detector.setup(cfg, meeting)
  updateMenubar()
  log("ready (hotkey=%s, model=%s, language=%s, cleanup=%s)", cfg.hotkey, cfg.model, cfg.language,
    tostring(cfg.cleanup))
  return M
end

function M.stop()
  if M.flagsTap then M.flagsTap:stop() M.flagsTap = nil end
  if M.keyTap then M.keyTap:stop() M.keyTap = nil end
  detector.teardown()
  meeting.teardown()
  cleanup.teardown()
  if M.menuHotkey then M.menuHotkey:delete() M.menuHotkey = nil end
  if M.popup then M.popup:delete() M.popup = nil end
  if recorder then sendOnExit = false recorder:terminate() recorder = nil end
  if menubar then menubar:delete() menubar = nil end
  setIndicator(nil)
end

return M
