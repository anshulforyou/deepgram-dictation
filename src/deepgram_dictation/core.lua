-- Pure logic for deepgram-dictation. No Hammerspoon dependencies, so it can be unit tested
-- with plain Lua (see spec/).

local core = {}

core.DEFAULTS = {
  hotkey       = "fn",        -- see core.HOTKEYS
  language     = "en",        -- Deepgram language code, or "multi" for mixed-language speech
  model        = "nova-3",
  smartFormat  = true,
  minSeconds   = 0.3,         -- releases shorter than this are treated as accidental taps
  recBinary    = nil,         -- path to sox's `rec`; auto-detected when nil
  dictionary   = nil,         -- path to dictionary JSON; defaults to <hs.configdir>/deepgram-dictionary.json
  keychainName = "deepgram-api-key",
  restoreClipboard = true,
  showMenubar  = true,

  -- Meeting transcription
  meetingHotkey    = { mods = { "ctrl", "alt", "cmd" }, key = "m" }, -- toggles a meeting; false disables
  meetingMode      = "online",  -- what the hotkey records: "online" (mic + computer audio) or "inPerson"
  meetingLanguage  = nil,       -- defaults to `language`
  transcriptsDir   = nil,       -- defaults to ~/Documents/Meeting Transcripts
  keepMeetingAudio = false,     -- keep recordings after a successful transcription
  recorderApp      = nil,       -- defaults to ~/Library/Application Support/deepgram-dictation/DeepgramRecorder.app
  python           = nil,       -- python3 path; auto-detected when nil
}

core.OPTIONS = {
  recBinary = true, dictionary = true, meetingLanguage = true, transcriptsDir = true,
  recorderApp = true, python = true,
}
for k in pairs(core.DEFAULTS) do core.OPTIONS[k] = true end

-- Hold-to-talk keys. `keyCode` is the macOS virtual key code; `flag` is the modifier flag
-- that is set while the key is held.
core.HOTKEYS = {
  fn           = { keyCode = 63, flag = "fn" },
  rightCommand = { keyCode = 54, flag = "cmd" },
  rightOption  = { keyCode = 61, flag = "alt" },
  rightControl = { keyCode = 62, flag = "ctrl" },
  rightShift   = { keyCode = 60, flag = "shift" },
}

core.MEETING_MODES = { online = true, inPerson = true }

core.REC_CANDIDATES = { "/opt/homebrew/bin/rec", "/usr/local/bin/rec" }
core.PYTHON_CANDIDATES = { "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3" }

core.API_URL = "https://api.deepgram.com/v1/listen"

-- Returns a new config table: defaults overlaid with `overrides`. Errors on unknown keys or
-- invalid values so typos in a user's init.lua fail loudly.
function core.mergeConfig(overrides)
  local cfg = {}
  for k, v in pairs(core.DEFAULTS) do cfg[k] = v end
  for k, v in pairs(overrides or {}) do
    if not core.OPTIONS[k] then
      error("deepgram-dictation: unknown config option '" .. tostring(k) .. "'", 2)
    end
    cfg[k] = v
  end
  if not core.HOTKEYS[cfg.hotkey] then
    error("deepgram-dictation: unsupported hotkey '" .. tostring(cfg.hotkey) .. "'", 2)
  end
  if type(cfg.language) ~= "string" or cfg.language == "" then
    error("deepgram-dictation: language must be a non-empty string", 2)
  end
  if type(cfg.model) ~= "string" or cfg.model == "" then
    error("deepgram-dictation: model must be a non-empty string", 2)
  end
  if type(cfg.minSeconds) ~= "number" or cfg.minSeconds < 0 then
    error("deepgram-dictation: minSeconds must be a non-negative number", 2)
  end
  if not core.MEETING_MODES[cfg.meetingMode] then
    error("deepgram-dictation: meetingMode must be \"online\" or \"inPerson\"", 2)
  end
  local mh = cfg.meetingHotkey
  if mh ~= false and (type(mh) ~= "table" or type(mh.mods) ~= "table" or type(mh.key) ~= "string") then
    error("deepgram-dictation: meetingHotkey must be false or { mods = {...}, key = \"m\" }", 2)
  end
  return cfg
end

-- First existing path from `candidates`, using the injected `exists(path)` predicate.
function core.findExecutable(exists, candidates)
  for _, path in ipairs(candidates) do
    if exists(path) then return path end
  end
  return nil
end

-- RFC 3986 percent-encoding for query values.
function core.urlEncode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function core.buildListenUrl(cfg, keyterms)
  local params = {
    "model=" .. core.urlEncode(cfg.model),
    "language=" .. core.urlEncode(cfg.language),
    "punctuate=true",
  }
  if cfg.smartFormat then table.insert(params, "smart_format=true") end
  for _, term in ipairs(keyterms or {}) do
    table.insert(params, "keyterm=" .. core.urlEncode(term))
  end
  return core.API_URL .. "?" .. table.concat(params, "&")
end

-- Normalises a decoded dictionary JSON value into { keyterms = {...}, replacements = {...} },
-- dropping malformed entries.
function core.normalizeDictionary(data)
  local dict = { keyterms = {}, replacements = {} }
  if type(data) ~= "table" then return dict end
  for _, term in ipairs(data.keyterms or {}) do
    if type(term) == "string" and term:match("%S") then table.insert(dict.keyterms, term) end
  end
  for _, r in ipairs(data.replacements or {}) do
    if type(r) == "table" and type(r.from) == "string" and r.from:match("%S")
        and type(r.to) == "string" then
      table.insert(dict.replacements, { from = r.from, to = r.to })
    end
  end
  -- Longest phrases first so "my email address" wins over "my email".
  table.sort(dict.replacements, function(a, b) return #a.from > #b.from end)
  return dict
end

-- Case-insensitive Lua pattern matching `phrase` literally, anchored on word boundaries
-- where the phrase starts/ends with an alphanumeric character.
function core.phrasePattern(phrase)
  local body = phrase:gsub("%p", "%%%0"):gsub("%a", function(c)
    return "[" .. c:lower() .. c:upper() .. "]"
  end)
  local head = phrase:match("^%w") and "%f[%w]" or ""
  local tail = phrase:match("%w$") and "%f[%W]" or ""
  return head .. body .. tail
end

function core.applyReplacements(text, replacements)
  for _, r in ipairs(replacements or {}) do
    text = text:gsub(core.phrasePattern(r.from), (r.to:gsub("%%", "%%%%")))
  end
  return text
end

-- Extracts the transcript from a decoded Deepgram /v1/listen response.
-- Returns text, or nil plus an error message.
function core.extractTranscript(resp)
  local ok, text = pcall(function()
    return resp.results.channels[1].alternatives[1].transcript
  end)
  if not ok or type(text) ~= "string" then
    return nil, "unexpected response shape"
  end
  return text
end

-- Whether a recording that lasted `duration` seconds should be sent for transcription.
function core.shouldTranscribe(duration, cancelled, minSeconds)
  return not cancelled and duration >= minSeconds
end

-- Interprets a flagsChanged event for the configured hotkey.
-- Returns "press", "release", or nil when the event is unrelated. Any event for the hotkey's
-- own key code while active counts as a release, so holding e.g. the left Option key does not
-- keep a right-Option recording open.
function core.hotkeyTransition(hotkey, keyCode, flags, active)
  local spec = core.HOTKEYS[hotkey]
  if not spec or keyCode ~= spec.keyCode then return nil end
  if active then return "release" end
  return flags[spec.flag] and "press" or nil
end

-- "4:05" or "1:02:03" for an elapsed number of seconds.
function core.formatElapsed(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- Session directory name for a recording started at `t` (an os.date("*t") table).
function core.sessionName(t)
  return string.format("%04d-%02d-%02d_%02d-%02d-%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- Arguments for meeting_transcribe.py.
function core.transcribeArgs(cfg, script, sessionDir, transcriptsDir, dictionary)
  local args = {
    script, sessionDir,
    "--output-dir", transcriptsDir,
    "--model", cfg.model,
    "--language", cfg.meetingLanguage or cfg.language,
    "--keychain-name", cfg.keychainName,
  }
  if dictionary then
    table.insert(args, "--dictionary")
    table.insert(args, dictionary)
  end
  if cfg.keepMeetingAudio then table.insert(args, "--keep-audio") end
  return args
end

-- Decodes the JSON result line printed last by meeting_transcribe.py.
-- Returns the decoded table, or nil plus an error message.
function core.parseResultLine(stdout, decode)
  local last
  for line in (stdout or ""):gmatch("[^\n]+") do
    if line:match("%S") then last = line end
  end
  if not last then return nil, "transcriber produced no output" end
  local ok, result = pcall(decode, last)
  if not ok or type(result) ~= "table" then return nil, "could not parse transcriber output" end
  if result.error then return nil, result.error end
  if type(result.path) ~= "string" then return nil, "transcriber did not return a file path" end
  return result
end

return core
