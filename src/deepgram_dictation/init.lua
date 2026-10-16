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
local screen = require("deepgram_dictation.screen")
local overlay = require("deepgram_dictation.screen_overlay")
local screenFill = require("deepgram_dictation.screen_fill")
local voice = require("deepgram_dictation.voice")
local badge = require("deepgram_dictation.badge")
local sounds = require("deepgram_dictation.sounds")
local tasks = require("deepgram_dictation.tasks")
local screenMemory = require("deepgram_dictation.screen_memory")

local M = { core = core, meeting = meeting }

local cfg, dictPath, recBinary
local audioPath = (os.getenv("TMPDIR") or "/tmp/") .. "deepgram-dictation.wav"
local enabled = true
local handoverAt
local recorder, startedAt, releasedAt, micReadyAt, cancelled, sendOnExit, tailTimer, slowTimer
local standby -- { task, device, output }: a recorder with the mic set up but off, see prepareStandby
local usedStandby -- whether the current dictation started from the standby recorder
local holding = false -- the key is down for the current recording (it can't be cancelled after)
-- The current dictation. A screen question keeps its state here (asked, shot, error) so that a
-- dictation started while grandma is still answering can't mix with it.
local session
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

-- Words that stay on screen until replaced, for the few states that need saying (see badge.lua).
local GRANDMA_BADGE = {
  textSize = 16, radius = 10, strokeWidth = 1.5,
  fillColor = { red = 0.11, green = 0.10, blue = 0.11, alpha = 0.92 },
  strokeColor = { red = 0.98, green = 0.60, blue = 0.64, alpha = 0.9 },
  textColor = { red = 1, green = 0.90, blue = 0.92 },
}

-- Shows what is happening: a badge kind ("listening", "thinking", ...; `n` is the fill step)
-- animates in the badge, anything else is shown as words; nil hides it. Her needles are heard
-- for as long as she is thinking.
local function setIndicator(what, n, fade)
  if indicator then hs.alert.closeSpecific(indicator, fade) indicator = nil end
  if what == "thinking" then
    if badge.kind() ~= "thinking" then sounds.startThinking() end
  else
    sounds.stopThinking()
  end
  if badge.KINDS[what] then return badge.show(what, n) end
  badge.hide(fade == 0) -- at once before a screen capture, otherwise it fades
  if what then indicator = hs.alert.show(what, GRANDMA_BADGE, "infinite") end
end

local function pasteText(text)
  local saved = cfg.restoreClipboard and hs.pasteboard.readAllData() or nil
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  if saved then
    hs.timer.doAfter(0.5, function() hs.pasteboard.writeAllData(saved) end)
  end
end

local function inputDeviceName()
  local d = hs.audiodevice.defaultInputDevice()
  return d and d:name()
end

-- Moves the recording off audioPath, so a dictation started meanwhile can't clobber it.
local function moveRecording()
  delivered = delivered + 1
  local recording = audioPath:gsub("%.wav$", "-" .. delivered .. ".wav")
  return os.rename(audioPath, recording) and recording or audioPath
end

-- The recording (moved off audioPath unless `recording` already is) and its history record.
local function takeRecording(via, recording)
  local transcribedAt = hs.timer.secondsSinceEpoch()
  recording = recording or moveRecording()
  return recording, {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"), via = via, model = cfg.model, language = cfg.language,
    seconds = releasedAt and startedAt and math.floor((releasedAt - startedAt) * 100 + 0.5) / 100,
    deepgramMs = releasedAt and math.floor((transcribedAt - releasedAt) * 1000 + 0.5),
    -- Time from pressing the key to the first audio from the mic: speech before that is lost.
    micMs = micReadyAt and startedAt and math.floor((micReadyAt - startedAt) * 1000 + 0.5),
    -- With a Bluetooth mic: when it took over from the built-in mic (nil: no bridge, or it never did).
    handoverMs = handoverAt and startedAt and math.floor((handoverAt - startedAt) * 1000 + 0.5),
    tailSeconds = cfg.tailSeconds,
    standby = usedStandby,
    device = inputDeviceName(),
  }
end

-- Ends a screen question's glow, unless a newer screen question has taken it over. A capture
-- still running for `s` won't show it afterwards.
local function endGlow(s)
  s.discarded = true
  if session == s or not (session and session.asked) then overlay.hideGlow() end
end

-- Clears the badge once `s` is done, unless a newer dictation or question is still showing its own.
local function clearBadge(s)
  if not recorder and (session == s or not session or not session.asked) then setIndicator(nil) end
end

-- Saves a screen question once its outcome is final, and logs it for grandma to learn from.
local function saveScreen(recording, record)
  history.save(recording, record)
  voice.screen(record)
end

-- The fill plan as the user sees it before saying yes.
local function planText(answer)
  local lines = { answer.text ~= "" and answer.text or "Grandma will fill in:", "" }
  for _, f in ipairs(answer.fields) do
    table.insert(lines, f.skip and string.format("%s: not in your memory, will skip", f.label)
      or f.file and string.format("%s: upload %s (shown below)", f.label, f.file.name)
      or string.format("%s: %s", f.label, f.value))
  end
  table.insert(lines, "")
  table.insert(lines, "Return to fill it in, Esc to cancel. She never clicks Save or Submit.")
  return table.concat(lines, "\n")
end

-- Grandma fills the form on the screen she looked at, once the user said yes or told her to.
local function fillForm(answer, s, recording, record)
  local scr = s.shot.screen
  overlay.showGlow(scr)
  setIndicator("filling", 0)
  sounds.play("fill")
  screenFill.run(answer.fields, scr, function(n)
    if recorder then return end
    setIndicator("filling", n)
  end, function(summary, info)
    overlay.hideGlow()
    if not recorder then setIndicator(nil) end
    local sound = ({ done = "done", error = "error" })[info.status] -- a stopped fill stays quiet
    if sound then sounds.play(sound) end
    if info.status == "done" then
      local skipped = {}
      for _, f in ipairs(answer.fields) do if f.skip then table.insert(skipped, f.label) end end
      if #skipped > 0 then
        summary = summary .. "\n\nLeft empty, not in your memory: " .. table.concat(skipped, "; ")
      end
      overlay.showPanel({ gist = core.fillGist(answer.fields), body = summary }, "Filled")
    else
      overlay.showPanel((info.status == "stopped" and "Stopped: " or "Couldn't fill it: ") .. tostring(info.reason)
        .. ". Anything already typed is still there.", info.status == "stopped" and "Stopped" or "Couldn't fill", true)
    end
    record.screen.fill = { status = info.status, reason = info.reason, ms = info.ms, actions = info.actions,
                           summary = summary }
    saveScreen(recording, record)
  end)
end

-- The memory a screen question was answered with (sent or opened), read again whole for a page
-- grandma works on: done({ blocks = { { name, text } }, images }).
local WORK_MEMORY_CHARS = 240000
local function workMemory(info, done)
  local names, seen = {}, {}
  for _, list in ipairs({ info.memory or {}, info.opened or {} }) do
    for _, n in ipairs(list) do
      if not seen[n] then seen[n] = true table.insert(names, n) end
    end
  end
  local out = { blocks = {}, images = {} }
  local function nextName(i)
    local name = names[i]
    if not name then return done(out) end
    screenMemory.open(name, WORK_MEMORY_CHARS / #names, function(block)
      if block then
        table.insert(out.blocks, { name = block.name, text = block.text })
        for _, img in ipairs(block.images or {}) do table.insert(out.images, img) end
      end
      nextName(i + 1)
    end)
  end
  nextName(1)
end

-- Grandma works on the page on screen: she looks through it, proposes every change, and makes them
-- once the user says yes, or straight away when they told her outright to make them.
local function workOnPage(answer, s, recording, record, info)
  local scr = s.shot.screen
  local function ended(summary, result, title, gist)
    overlay.hideGlow()
    if not recorder then setIndicator(nil) end
    local sound = ({ done = "done", error = "error" })[result.status]
    if sound then sounds.play(sound) end
    if result.status == "done" then
      overlay.showPanel({ gist = gist, body = summary or "Done." }, title)
    else
      overlay.showPanel((result.status == "stopped" and "Stopped: " or "Couldn't do it: ") .. tostring(result.reason)
        .. ". Anything already changed is still there.", result.status == "stopped" and "Stopped" or "Couldn't do it",
        true)
    end
  end
  local function make(fields)
    overlay.showGlow(scr)
    setIndicator("filling", 0)
    sounds.play("fill")
    screenFill.run(fields, scr, function(n)
      if not recorder then setIndicator("filling", n) end
    end, function(summary, result)
      ended(summary, result, "Done", core.fillGist(fields, "work"))
      record.screen.work = { status = result.status, reason = result.reason, ms = result.ms,
                             actions = result.actions, summary = summary }
      saveScreen(recording, record)
    end, { mode = "work", goal = answer.text })
  end
  setIndicator("looking")
  workMemory(info, function(mem)
    if recorder then return end -- a new dictation started meanwhile
    overlay.showGlow(scr)
    setIndicator("looking")
    screenFill.run({}, scr, function()
      if not recorder then setIndicator("looking") end
    end, function(proposal, result)
      record.screen.survey = { status = result.status, reason = result.reason, ms = result.ms,
                               actions = result.actions }
      if result.status ~= "proposed" then
        ended(type(proposal) == "string" and proposal or nil, result, "Looked through it")
        return saveScreen(recording, record)
      end
      overlay.hideGlow()
      if not recorder then setIndicator(nil) end
      local fields, summary = core.parseProposal(proposal, mem.images)
      record.screen.proposal = { summary = summary, fields = fields }
      local changes = 0
      for _, f in ipairs(fields) do if not f.skip then changes = changes + 1 end end
      if changes == 0 then
        sounds.play("answer")
        overlay.showPanel(summary ~= "" and summary or "She found nothing to change.", "Nothing to change")
        return saveScreen(recording, record)
      end
      if answer.asked then
        -- They told her to make the changes: she does, without a card in between.
        record.screen.confirmed = "asked"
        return make(fields)
      end
      sounds.play("answer")
      local pictures = {}
      for _, f in ipairs(fields) do
        if f.file and not f.skip then table.insert(pictures, { path = f.file.path, caption = f.label }) end
      end
      overlay.showPanel(core.proposalText(fields, summary), "Make these changes?", false, {
        onReturn = function()
          record.screen.closedBy = "return"
          record.screen.confirmed = true
          make(fields)
        end,
        onEscape = function(how)
          record.screen.closedBy = how
          record.screen.confirmed = false
          saveScreen(recording, record)
        end,
      }, pictures)
    end, { mode = "survey", goal = answer.text, memory = mem })
  end)
end

-- Asks grandma the transcribed question about the captured screen. Text she writes is pasted;
-- an answer is shown in a panel. Both end up on the clipboard, and so does the question when
-- she can't answer, so nothing said is lost.
local function answerScreen(raw, recording, record, s)
  local function finish(answer, info)
    endGlow(s)
    clearBadge(s)
    record.screen = { status = info.status, ms = info.ms, reason = info.reason, captureMs = s.shot and s.shot.ms,
                      kind = answer and answer.kind, answer = answer and answer.text,
                      fields = answer and answer.fields, memory = info.memory, opened = info.opened }
    if answer and answer.kind == "work" then return workOnPage(answer, s, recording, record, info) end
    if answer and answer.kind == "task" and tasks.enabled() then
      record.screen.task = answer.task
      local function begin()
        tasks.start(answer.task, raw, function(err)
          record.screen.started = err == nil
          if err then
            sounds.play("error")
            hs.pasteboard.setContents(raw)
            overlay.showPanel("Couldn't start it: " .. err .. "\n\nYour question is on the clipboard.",
              "Couldn't start", true)
          else
            sounds.play("fill")
            overlay.showPanel(answer.task.goal .. "\n\nShe'll tell you when it's done, or if she needs you.",
              "On it, in the background")
          end
          saveScreen(recording, record)
        end)
      end
      if not core.taskNeedsConfirm(answer.task) then return begin() end
      sounds.play("answer")
      return overlay.showPanel(core.taskPlanText(answer.task), "Start this task?", false, {
        onReturn = function()
          record.screen.closedBy = "return"
          record.screen.confirmed = true
          begin()
        end,
        onEscape = function(how)
          record.screen.closedBy = how
          record.screen.confirmed = false
          saveScreen(recording, record)
        end,
      })
    end
    if answer and answer.kind == "task" then
      -- Background tasks are off: say what she would have done instead.
      answer = { kind = "answer", text = (answer.text ~= "" and answer.text or answer.task.goal)
        .. "\n\n(Background tasks are off: backgroundTasks = false.)" }
    end
    if answer and answer.kind == "fill" and answer.asked then
      -- They told her to fill it: she does, and shows what she filled when she's done.
      record.screen.confirmed = "asked"
      return fillForm(answer, s, recording, record)
    end
    sounds.play(not answer and "error" or answer.kind == "insert" and "insert" or "answer")
    if answer and answer.kind == "fill" then
      -- Not asked outright: nothing is touched until the user has seen the plan and said yes.
      local pictures = {}
      for _, f in ipairs(answer.fields) do
        if f.file and not f.skip then table.insert(pictures, { path = f.file.path, caption = f.label }) end
      end
      return overlay.showPanel(planText(answer), "Fill this form?", false, {
        onReturn = function()
          record.screen.closedBy = "return"
          record.screen.confirmed = true
          fillForm(answer, s, recording, record)
        end,
        onEscape = function(how)
          record.screen.closedBy = how
          record.screen.confirmed = false
          saveScreen(recording, record)
        end,
      }, pictures)
    end
    if answer and answer.kind == "insert" and answer.replaces then
      -- A fix of text already on screen: select the original so the paste replaces it. When it
      -- can't be found in the field, nothing is pasted; the fix is on the clipboard.
      return screenFill.selectText(answer.replaces, function(selected)
        record.screen.replaced = selected
        if selected then
          pasteText(answer.text)
        else
          hs.pasteboard.setContents(answer.text)
          overlay.showPanel(answer.text .. "\n\nI couldn't select the original text in this field, so nothing was"
            .. " pasted. Select it and press Cmd+V.", "Fixed text copied")
        end
        saveScreen(recording, record)
      end)
    end
    if answer and answer.kind == "insert" then
      pasteText(answer.text)
    elseif answer then
      hs.pasteboard.setContents(core.unmark(answer.text))
      overlay.showPanel({ gist = answer.gist, body = answer.text }, "Copied")
    else
      hs.pasteboard.setContents(raw)
      overlay.showPanel(tostring(info.reason) .. "\n\nYour question is on the clipboard.", "Couldn't answer", true)
    end
    saveScreen(recording, record)
  end
  -- "Grandma, remember ..." is noted as a memory proposal, not asked about the screen.
  local remember = voice.enabled() and core.rememberText(raw)
  if remember then
    endGlow(s)
    setIndicator("noting")
    return voice.remember(remember, function(result, err)
      clearBadge(s)
      sounds.play(result and "noted" or "error")
      record.screen = { kind = "remember", status = err and "error" or "ok", reason = err,
                        answer = result and result.line, memory = result and { result.scope } or nil }
      if result then
        -- global isn't a sweater, so `grandma review global` doesn't list it: plain review does.
        local review = result.scope == "global" and "grandma review" or ("grandma review " .. result.scope)
        overlay.showPanel(string.format("%s\n\nFor %s, in %s. Review it with: %s", result.line,
          result.scope, result.target, review), "Noted for review")
      else
        hs.pasteboard.setContents(remember)
        overlay.showPanel("Couldn't note that: " .. tostring(err) .. "\n\nWhat you said is on the clipboard.",
          "Couldn't note it", true)
      end
      history.save(recording, record)
    end)
  end
  if s.error then return finish(nil, { status = "error", reason = s.error }) end
  if not s.shot then
    s.waiting = function() answerScreen(raw, recording, record, s) end -- the capture is still running
    return
  end
  setIndicator("thinking")
  screen.ask(raw, s.shot, finish)
end

-- Cleans the transcript, pastes it and records the dictation (or asks grandma, see answerScreen).
local function deliver(raw, dict, via, moved, s)
  local recording, record = takeRecording(via, moved)
  record.raw = raw
  if s and s.copyOnly then
    -- A question retried from the menu: its screenshot is gone, so it can't be asked again.
    record.via = via .. "+screen"
    clearBadge(s)
    if raw ~= "" then
      hs.pasteboard.setContents(raw)
      hs.alert.show("Your question is on the clipboard. Ask again with Fn+Control to send the screen.", 3)
    end
    return history.save(recording, record)
  end
  if s and s.reply then
    record.via = via .. "+task"
    clearBadge(s)
    if raw == "" then return history.save(recording, record) end
    return tasks.reply(s.reply, raw, function(err)
      record.task = { reply = s.reply, status = err and "error" or "ok", reason = err }
      if err then
        sounds.play("error")
        hs.pasteboard.setContents(raw)
        overlay.showPanel("Couldn't send that: " .. err .. "\n\nWhat you said is on the clipboard.",
          "Couldn't reply", true)
      else
        sounds.play("fill")
        overlay.showPanel(raw, "Sent. She's back on it")
      end
      history.save(recording, record)
    end)
  end
  if s and s.asked then
    record.via = via .. "+screen"
    if raw == "" then
      endGlow(s)
      return history.save(recording, record)
    end
    return answerScreen(raw, recording, record, s)
  end
  if raw == "" then return history.save(recording, record) end
  local names = cleanup.namesFor(dict)
  cleanup.run(raw, names, function(text, info)
    local pasted = core.applyReplacements(text, dict.replacements)
    clearBadge(s) -- keeps the badge of a dictation started meanwhile
    pasteText(pasted)
    sounds.play("tick")
    voice.dictation(pasted)
    record.cleanup = info
    record.cleaned = info.status == "ok" and text or nil
    record.pasted = pasted
    history.save(recording, record)
  end)
end

-- Deepgram couldn't be reached at all. The recording is kept in the dictation history, so
-- nothing said is lost: "Retry last dictation" in the menu transcribes it again.
local function keepFailed(reason, recording, s)
  setIndicator(nil)
  if s then endGlow(s) end
  sounds.play("error")
  log("transcription failed: %s", reason)
  if not history.enabled() then
    os.remove(recording)
    hs.alert.show("Deepgram error, see Hammerspoon console")
    return
  end
  local _, record = takeRecording(s and (s.asked or s.copyOnly) and "upload+screen" or "upload", recording)
  record.error = reason
  history.save(recording, record)
  hs.alert.show("Couldn't reach Deepgram. The recording is saved:\n🎙 menu → Retry last dictation", 5)
end

local function transcribe(label, s)
  local key = getApiKey()
  if not key then
    setIndicator(nil)
    if s then endGlow(s) end
    hs.alert.show("Deepgram API key not found in Keychain ('" .. cfg.keychainName .. "')")
    return
  end
  local recording = moveRecording()
  local f = io.open(recording, "rb")
  if not f then
    setIndicator(nil)
    if s then endGlow(s) end
    return
  end
  local audio = f:read("a")
  f:close()

  local dict = loadDictionary()
  local _, keyterms = cleanup.namesFor(dict)
  setIndicator(label or (s and s.asked and "thinking" or "transcribing"))
  hs.http.asyncPost(core.buildListenUrl(cfg, keyterms), audio, {
    ["Authorization"] = "Token " .. key,
    ["Content-Type"] = "audio/wav",
  }, function(status, body)
    if status ~= 200 then
      if status == 401 or status == 403 then apiKey = nil end
      return keepFailed("HTTP " .. tostring(status) .. ": " .. tostring(body), recording, s)
    end
    local ok, resp = pcall(hs.json.decode, body)
    local text, err = core.extractTranscript(ok and resp or nil)
    if not text then return keepFailed("bad response: " .. tostring(err), recording, s) end
    if text == "" then
      setIndicator(nil)
      hs.alert.show("No speech detected", 1)
    end
    deliver(text, dict, "upload", recording, s)
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

local function finishStreaming(stdout, dict, s)
  local result = core.parseStreamOutput(stdout, hs.json.decode) or {}
  if not sendOnExit then
    os.remove(audioPath)
    setIndicator(nil)
    if s then endGlow(s) end
    -- Discarded on purpose (a tap, or cancelled) prints nothing. An error means the recorder died
    -- while the key was still held: say so rather than let the user keep talking to nothing.
    if result.error then
      holding = false
      log("recorder stopped: %s", tostring(result.error))
      hs.alert.show("Recording stopped, see Hammerspoon console", 3)
    end
    return
  end
  if type(result.transcript) == "string" then
    if result.transcript == "" then
      setIndicator(nil)
      alertNoSpeech()
    end
    deliver(result.transcript, dict, "stream", nil, s)
  else
    -- The stream failed or fell behind (a slow connection): the recorder never hands back a
    -- partial transcript, so upload the whole recording instead.
    log("streaming failed (%s); falling back to upload", tostring(result.error or stdout))
    transcribe("slow", s)
  end
end

local function recorderHelper() return meeting.recorderApp() .. "/Contents/MacOS/DeepgramRecorder" end

local prepareStandby -- defined below

-- Starts DeepgramRecorder in stream mode. The same callbacks serve a standby recorder, which
-- only becomes `recorder` once the key is pressed.
local function spawnRecorder(args)
  local key = getApiKey()
  if not key then return nil end
  local proc = { output = "" }
  proc.task = hs.task.new(recorderHelper(), function(_, stdout)
    proc.output = proc.output .. (stdout or "")
    if standby == proc then standby = nil end
    if recorder == proc.task then
      recorder = nil
      if slowTimer then slowTimer:stop() slowTimer = nil end
      finishStreaming(proc.output, proc.dict, proc.session)
      prepareStandby()
    end
  end, function(_, stdout)
    proc.output = proc.output .. (stdout or "")
    -- When the mic actually started delivering audio (recorded to measure lost first words).
    if recorder == proc.task and not micReadyAt and proc.output:find('"event":"listening"', 1, true) then
      micReadyAt = hs.timer.secondsSinceEpoch()
    end
    -- When a Bluetooth mic took over from the built-in one that covered its start-up.
    if recorder == proc.task and not handoverAt and proc.output:find('"event":"handover"', 1, true) then
      handoverAt = hs.timer.secondsSinceEpoch()
    end
    return true
  end, args)
  proc.task:setEnvironment({
    DEEPGRAM_API_KEY = key, HOME = os.getenv("HOME"), TMPDIR = os.getenv("TMPDIR"), PATH = "/usr/bin:/bin",
  })
  if not proc.task:start() then return nil end
  return proc
end

-- Keeps one recorder waiting with the mic set up but switched off (no recording indicator), so
-- pressing the key only has to switch the mic on: about 150 ms instead of 400 ms, and instead of
-- up to 2 s when the Mac has been idle. Speech in that gap is lost, so this saves first words.
-- Recorder arguments that cover a Bluetooth mic's start-up (AirPods take 1 to 3 s to send audio)
-- with the built-in mic: core.bridgeMic.
local function bridgeArgs(args)
  local default = hs.audiodevice.defaultInputDevice()
  local inputs = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    table.insert(inputs, { uid = d:uid(), transport = d:transportType() })
  end
  local uid = core.bridgeMic(cfg, default and default:transportType(), inputs)
  if uid then
    table.insert(args, "--bridge-uid")
    table.insert(args, uid)
  end
  return args
end

prepareStandby = function()
  if standby or not (cfg.streaming and enabled) or not hs.fs.attributes(recorderHelper()) then return end
  standby = spawnRecorder(bridgeArgs({ "--stream", "--standby", "--save", audioPath }))
  if standby then standby.device = inputDeviceName() end
end

local function dropStandby()
  local proc = standby
  standby = nil
  if proc and proc.task:isRunning() then proc.task:terminate() end
end

-- Streams audio to Deepgram while the key is held (much faster than uploading afterwards).
local function startStreaming()
  if not getApiKey() then
    hs.alert.show("Deepgram API key not found in Keychain ('" .. cfg.keychainName .. "')")
    return
  end
  local dict = loadDictionary()
  local _, keyterms = cleanup.namesFor(dict)
  local url = core.buildStreamUrl(cfg, keyterms)
  local proc = standby
  standby = nil
  -- A standby set up for another mic (AirPods connected since) would record the wrong one.
  usedStandby = proc ~= nil and proc.task:isRunning() and proc.device == inputDeviceName()
  if usedStandby then
    proc.task:setInput("start " .. url .. "\n")
  else
    if proc and proc.task:isRunning() then proc.task:terminate() end
    proc = spawnRecorder(bridgeArgs({ "--stream", "--url", url, "--save", audioPath }))
    if not proc then
      hs.alert.show("Could not start recording, see Hammerspoon console")
      return
    end
  end
  proc.dict = dict
  proc.session = session
  recorder = proc.task
  setIndicator("listening")
  sounds.play("tick")
end

local function startRecording()
  screenFill.stop("you started a dictation")
  -- A task's panel open as this starts: Fn+Control now replies to her (closing it forgets that).
  local replyTo = tasks.awaiting()
  overlay.closePanel(0) -- at once: with Control already down, the screen is captured next
  os.remove(audioPath)
  cancelled, sendOnExit, micReadyAt, usedStandby, holding, handoverAt = false, false, nil, nil, true, nil
  session = { replyTo = replyTo }
  local s = session
  startedAt = hs.timer.secondsSinceEpoch()
  if cfg.streaming and hs.fs.attributes(recorderHelper()) then return startStreaming() end
  if not recBinary then
    hs.alert.show("deepgram-dictation: sox not found. Run `brew install sox`.")
    return
  end
  recorder = hs.task.new(recBinary, function()
    recorder = nil
    if sendOnExit then
      transcribe(nil, s)
    else
      os.remove(audioPath)
      setIndicator(nil)
      endGlow(s)
    end
  end, { "-q", "-c", "1", "-r", "16000", "-b", "16", audioPath })
  if not recorder:start() then
    recorder = nil
    hs.alert.show("Could not start recording, see Hammerspoon console")
    return
  end
  setIndicator("listening")
  sounds.play("tick")
end

local function stopRecording()
  -- Only the press that started this recording can end it: a press while it is still finishing
  -- (the tail, or waiting for Deepgram) must never discard it.
  if not recorder or not holding then return end
  holding = false
  releasedAt = hs.timer.secondsSinceEpoch()
  local duration = releasedAt - startedAt
  sendOnExit = core.shouldTranscribe(duration, cancelled, cfg.minSeconds)
  if sendOnExit then
    setIndicator(session and session.asked and "thinking" or "transcribing")
    -- Keep recording a moment after the key comes up: people let go while the last word is still
    -- being spoken, and the mic delivers audio slightly late.
    local task = recorder
    tailTimer = hs.timer.doAfter(cfg.tailSeconds, function()
      tailTimer = nil
      if recorder ~= task then return end
      task:interrupt() -- SIGINT: finalise the WAV / flush Deepgram's results
      -- Results normally arrive within half a second; say why when they don't.
      slowTimer = hs.timer.doAfter(2, function()
        slowTimer = nil
        if recorder == task then setIndicator("slow") end
      end)
    end)
  else
    recorder:terminate() -- SIGTERM: discard
  end
end

-- Control went down while the hotkey is held: this dictation is a question about the screen.
-- The badge is hidden for the capture so it isn't in the screenshot; the glow then shows that
-- grandma has seen the screen.
local function askScreen(s)
  s.asked = true
  if s.replyTo then
    -- A reply to a background task: what is said goes to her, the screen isn't needed.
    s.reply = s.replyTo
    sounds.play("ask")
    return
  end
  if not screen.permitted() then
    screen.permitted(true) -- macOS shows its permission prompt (once)
    s.error = "Grandma can't see the screen yet. Allow Hammerspoon in System Settings → Privacy & Security"
      .. " → Screen & System Audio Recording, then reload Hammerspoon."
    setIndicator("🧶 Grandma can't see the screen yet")
    sounds.play("error")
    return
  end
  setIndicator(nil, nil, 0)
  sounds.play("ask")
  overlay.hideGlow(0) -- an older question's glow mustn't end up in this screenshot
  screen.capture(function(shot, err)
    if err then
      log("%s", err)
      s.error = "Couldn't capture the screen (" .. err .. ")."
    else
      s.shot = shot
      if not s.discarded then
        overlay.showGlow(shot.screen)
        if session == s then
          setIndicator(holding and "looking" or "thinking")
        end
      end
    end
    if s.waiting then
      local continue = s.waiting
      s.waiting = nil
      continue()
    end
  end)
end

local function updateMenubar()
  if not menubar then return end
  menubar:setTitle(meeting.menubarTitle() or (enabled and "🎙" or "🎙✕"))
end

-- Built on every click so meeting items reflect the current state.
local function buildMenu()
  local status = "Dictation: " .. (enabled and "on" or "off") .. " (hold " .. cfg.hotkey
    .. (screen.enabled() and ", add control to ask grandma about the screen" or "") .. ")"
  local items = {
    { title = status, disabled = true },
    { title = enabled and "Disable dictation" or "Enable dictation",
      fn = function()
        enabled = not enabled
        if enabled then prepareStandby() else dropStandby() end
        updateMenubar()
      end },
    { title = "-" },
  }
  if history.enabled() then
    table.insert(items, { title = "Flag last dictation as wrong", fn = function()
      local record = history.flagLast()
      voice.flag(record)
      hs.alert.show(record and "Flagged. Find it in the dictation history." or "No saved dictation yet", 2)
    end })
    table.insert(items, { title = "Retry last dictation", fn = function()
      local wav, last = history.lastAudio()
      if not wav or recorder then
        hs.alert.show(wav and "Finish the current dictation first" or "No saved recording to retry", 2)
        return
      end
      local src, dst = io.open(wav, "rb"), io.open(audioPath, "wb")
      if src and dst then dst:write(src:read("a")) end
      if src then src:close() end
      if dst then dst:close() end
      startedAt, releasedAt, micReadyAt = nil, nil, nil
      -- A failed screen question comes back to the clipboard, never pasted as dictation.
      local via = last and tostring(last.via) or ""
      transcribe(nil, via:find("+screen", 1, true) and { copyOnly = true } or nil)
    end })
    table.insert(items, { title = "Open dictation history", fn = function()
      hs.fs.mkdir(history.dir())
      hs.open(history.dir())
    end })
    table.insert(items, { title = "-" })
  end
  local taskItems = tasks.menuItems()
  for _, item in ipairs(taskItems) do table.insert(items, item) end
  if #taskItems > 0 then table.insert(items, { title = "-" }) end
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
    if holding and recorder and session and not session.asked and screen.enabled()
        and core.wantsScreen(cfg, e:getFlags()) then
      askScreen(session)
    end
    return false
  end):start()

  -- Hotkey used as a modifier for another key (e.g. Fn+F5): cancel this dictation.
  -- Keystrokes Hammerspoon posts itself (the ⌘V that pastes a previous dictation) don't count.
  local ownPid = hs.processInfo.processID
  local sourcePid = hs.eventtap.event.properties.eventSourceUnixProcessID
  M.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if recorder and holding and e:getProperty(sourcePid) ~= ownPid then cancelled = true end
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
  screen.setup(cfg)
  screenFill.setup(cfg)
  voice.setup(cfg)
  tasks.setup(cfg)
  badge.setup()
  sounds.setup(cfg, function() return core.inCall(meeting.online(), detector.callers()) end)
  meeting.setup(cfg, dictPath, updateMenubar)
  detector.setup(cfg, meeting)
  updateMenubar()
  prepareStandby()
  log("ready (hotkey=%s, model=%s, language=%s, cleanup=%s, screen=%s)", cfg.hotkey, cfg.model, cfg.language,
    tostring(cfg.cleanup), tostring(screen.enabled()))
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
  if tailTimer then tailTimer:stop() tailTimer = nil end
  if slowTimer then slowTimer:stop() slowTimer = nil end
  dropStandby()
  screenFill.stop("Hammerspoon reloaded")
  overlay.teardown()
  screen.teardown()
  voice.teardown()
  tasks.teardown()
  if recorder then sendOnExit = false recorder:terminate() recorder = nil end
  if menubar then menubar:delete() menubar = nil end
  setIndicator(nil)
  badge.teardown()
  sounds.teardown()
end

return M
