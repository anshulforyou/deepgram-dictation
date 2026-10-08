-- deepgram-dictation: hold a key, speak, release, and the Deepgram transcript is pasted at
-- the cursor. Hammerspoon glue around the pure logic in core.lua.
--
-- Usage in ~/.hammerspoon/init.lua:
--   deepgramDictation = require("deepgram_dictation")
--   deepgramDictation.start({ language = "en" })

local core = require("deepgram_dictation.core")

local M = { core = core }

local cfg, dictPath, recBinary
local audioPath = (os.getenv("TMPDIR") or "/tmp/") .. "deepgram-dictation.wav"
local enabled = true
local recorder, startedAt, cancelled, sendOnExit
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
  os.remove(audioPath)

  local dict = loadDictionary()
  setIndicator("⏳ Transcribing…")
  hs.http.asyncPost(core.buildListenUrl(cfg, dict.keyterms), audio, {
    ["Authorization"] = "Token " .. key,
    ["Content-Type"] = "audio/wav",
  }, function(status, body)
    setIndicator(nil)
    if status ~= 200 then
      log("HTTP %s: %s", tostring(status), tostring(body))
      if status == 401 or status == 403 then apiKey = nil end
      hs.alert.show("Deepgram error (" .. tostring(status) .. "), see Hammerspoon console")
      return
    end
    local ok, resp = pcall(hs.json.decode, body)
    local text, err = core.extractTranscript(ok and resp or nil)
    if not text then
      log("bad response: %s", err)
      hs.alert.show("Deepgram returned an unexpected response")
    elseif text == "" then
      hs.alert.show("No speech detected", 1)
    else
      pasteText(core.applyReplacements(text, dict.replacements))
    end
  end)
end

local function startRecording()
  os.remove(audioPath)
  cancelled, sendOnExit = false, false
  startedAt = hs.timer.secondsSinceEpoch()
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
  local duration = hs.timer.secondsSinceEpoch() - startedAt
  sendOnExit = core.shouldTranscribe(duration, cancelled, cfg.minSeconds)
  recorder:interrupt() -- SIGINT lets sox finalise the WAV header before exiting
end

local function updateMenubar()
  if not menubar then return end
  menubar:setTitle(enabled and "🎙" or "🎙✕")
  local status = "Deepgram dictation: " .. (enabled and "on" or "off") .. " (hold " .. cfg.hotkey .. ")"
  menubar:setMenu({
    { title = status, disabled = true },
    { title = enabled and "Disable" or "Enable", fn = function() enabled = not enabled updateMenubar() end },
    { title = "Reload Hammerspoon config", fn = hs.reload },
  })
end

function M.start(overrides)
  M.stop()
  cfg = core.mergeConfig(overrides)
  dictPath = cfg.dictionary or (hs.configdir .. "/deepgram-dictionary.json")
  recBinary = cfg.recBinary or core.findRecBinary(function(p) return hs.fs.attributes(p) ~= nil end)
  if not recBinary then
    hs.alert.show("deepgram-dictation: sox not found. Run `brew install sox`.")
    return M
  end

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
    menubar = hs.menubar.new()
    updateMenubar()
  end
  log("ready (hotkey=%s, model=%s, language=%s)", cfg.hotkey, cfg.model, cfg.language)
  return M
end

function M.stop()
  if M.flagsTap then M.flagsTap:stop() M.flagsTap = nil end
  if M.keyTap then M.keyTap:stop() M.keyTap = nil end
  if recorder then sendOnExit = false recorder:terminate() recorder = nil end
  if menubar then menubar:delete() menubar = nil end
  setIndicator(nil)
end

return M
