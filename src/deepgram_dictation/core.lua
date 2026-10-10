-- Pure logic for deepgram-dictation. No Hammerspoon dependencies, so it can be unit tested
-- with plain Lua (see spec/).

local core = {}

core.DEFAULTS = {
  hotkey       = "fn",        -- see core.HOTKEYS
  language     = "en",        -- Deepgram language code, or "multi" for mixed-language speech
  model        = "nova-3",
  smartFormat  = true,
  streaming    = true,        -- stream audio while the key is held (needs DeepgramRecorder.app)
  minSeconds   = 0.3,         -- releases shorter than this are treated as accidental taps
  recBinary    = nil,         -- path to sox's `rec`; auto-detected when nil
  dictionary   = nil,         -- path to dictionary JSON; defaults to <hs.configdir>/deepgram-dictionary.json
  keychainName = "deepgram-api-key",
  restoreClipboard = true,
  showMenubar  = true,

  -- Meeting transcription
  menuHotkey       = { mods = { "ctrl", "alt", "cmd" }, key = "d" }, -- shows the menu at the mouse; false disables
  meetingHotkey    = { mods = { "ctrl", "alt", "cmd" }, key = "m" }, -- toggles a meeting; false disables
  meetingMode      = "inPerson", -- what the hotkey records: "inPerson" (mic) or "online" (mic + computer audio)
  detectMeetings   = true,      -- offer to transcribe when Zoom/Meet/Teams/... start using the mic
  autoStopMeetings = true,      -- stop and transcribe when a detected meeting ends
  meetingLanguage  = nil,       -- defaults to `language`
  transcriptsDir   = nil,       -- defaults to ~/Documents/Meeting Transcripts
  keepMeetingAudio = false,     -- keep recordings after a successful transcription
  showMeetingIndicator = true,  -- floating pill with pause/stop buttons while a meeting is recorded
  recorderApp      = nil,       -- defaults to ~/Library/Application Support/deepgram-dictation/DeepgramRecorder.app
  python           = nil,       -- python3 path; auto-detected when nil

  -- Organizing transcripts with Claude (sends the transcript to Anthropic via the Claude Code CLI)
  organizeWithClaude = false,   -- file each transcript into a topic folder with title, summary, action items
  claudePath       = nil,       -- `claude` CLI path; auto-detected when nil
  claudeModel      = nil,       -- e.g. "opus"; nil uses the CLI's default model
}

core.OPTIONS = {
  recBinary = true, dictionary = true, meetingLanguage = true, transcriptsDir = true,
  recorderApp = true, python = true, claudePath = true, claudeModel = true,
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

-- Paths relative to $HOME are prefixed with "~/".
core.CLAUDE_CANDIDATES = { "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude" }

-- Desktop apps that only use the microphone during a call.
core.MEETING_APPS = {
  ["us.zoom.xos"]                   = "Zoom",
  ["com.microsoft.teams2"]          = "Microsoft Teams",
  ["com.microsoft.teams"]           = "Microsoft Teams",
  ["com.tinyspeck.slackmacgap"]     = "Slack huddle",
  ["com.cisco.webexmeetingsapp"]    = "Webex",
  ["Cisco-Systems.Spark"]           = "Webex",
  ["com.hnc.Discord"]               = "Discord",
  ["com.apple.FaceTime"]            = "FaceTime",
  ["com.apple.avconferenced"]       = "FaceTime",
  ["com.skype.skype"]               = "Skype",
}

-- Browsers, matched by bundle ID prefix (capture often runs in a helper such as
-- com.google.Chrome.helper). `script` is how to read tab URLs: "chromium", "safari" or nil.
core.BROWSERS = {
  { prefix = "com.google.Chrome", name = "Google Chrome", app = "com.google.Chrome", script = "chromium" },
  { prefix = "com.brave.Browser", name = "Brave Browser", app = "com.brave.Browser", script = "chromium" },
  { prefix = "com.microsoft.edgemac", name = "Microsoft Edge", app = "com.microsoft.edgemac", script = "chromium" },
  { prefix = "company.thebrowser.Browser", name = "Arc", app = "company.thebrowser.Browser", script = "chromium" },
  { prefix = "com.vivaldi.Vivaldi", name = "Vivaldi", app = "com.vivaldi.Vivaldi", script = "chromium" },
  { prefix = "com.operasoftware.Opera", name = "Opera", app = "com.operasoftware.Opera", script = "chromium" },
  { prefix = "com.apple.WebKit.GPU", name = "Safari", app = "com.apple.Safari", script = "safari" },
  { prefix = "com.apple.Safari", name = "Safari", app = "com.apple.Safari", script = "safari" },
  { prefix = "org.mozilla.firefox", name = "Firefox", app = "org.mozilla.firefox" },
}

-- Web meeting URLs (Lua patterns, matched against lowercased URLs).
core.MEETING_URLS = {
  { pattern = "^https://meet%.google%.com/%l%l%l%-%l%l%l%l%-%l%l%l", name = "Google Meet" },
  { pattern = "^https://[%w%.]*zoom%.us/wc/",                         name = "Zoom" },
  { pattern = "^https://[%w%.]*zoom%.us/j/",                          name = "Zoom" },
  { pattern = "^https://teams%.microsoft%.com/",                      name = "Microsoft Teams" },
  { pattern = "^https://teams%.live%.com/",                           name = "Microsoft Teams" },
  { pattern = "^https://app%.slack%.com/huddle/",                     name = "Slack huddle" },
  { pattern = "^https://whereby%.com/",                               name = "Whereby" },
  { pattern = "^https://[%w%-]+%.whereby%.com/",                      name = "Whereby" },
}

-- Window titles that mean a meeting is open (for browsers without tab scripting).
core.MEETING_TITLES = {
  { pattern = "^Meet %- %l%l%l%-%l%l%l%l%-%l%l%l", name = "Google Meet" },
  { pattern = "^Meet: ",                           name = "Google Meet" },
  { pattern = "Zoom Meeting",                      name = "Zoom" },
}

core.API_URL = "https://api.deepgram.com/v1/listen"
core.STREAM_URL = "wss://api.deepgram.com/v1/listen"

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
  for _, name in ipairs({ "meetingHotkey", "menuHotkey" }) do
    local hk = cfg[name]
    if hk ~= false and (type(hk) ~= "table" or type(hk.mods) ~= "table" or type(hk.key) ~= "string") then
      error("deepgram-dictation: " .. name .. " must be false or { mods = {...}, key = \"m\" }", 2)
    end
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

function core.buildListenUrl(cfg, keyterms, base, extra)
  local params = {
    "model=" .. core.urlEncode(cfg.model),
    "language=" .. core.urlEncode(cfg.language),
    "punctuate=true",
  }
  if cfg.smartFormat then table.insert(params, "smart_format=true") end
  for _, p in ipairs(extra or {}) do table.insert(params, p) end
  for _, term in ipairs(keyterms or {}) do
    table.insert(params, "keyterm=" .. core.urlEncode(term))
  end
  return (base or core.API_URL) .. "?" .. table.concat(params, "&")
end

-- Live-streaming URL for the raw 16 kHz mono 16-bit PCM that DeepgramRecorder --stream sends.
function core.buildStreamUrl(cfg, keyterms)
  return core.buildListenUrl(cfg, keyterms, core.STREAM_URL,
    { "encoding=linear16", "sample_rate=16000", "channels=1" })
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

-- Result of `DeepgramRecorder --stream`: the last JSON line that isn't a progress event
-- (e.g. {"event":"listening"}). Returns the decoded table or nil.
function core.parseStreamOutput(text, decode)
  local result
  for line in (text or ""):gmatch("[^\n]+") do
    local ok, value = pcall(decode, line)
    if ok and type(value) == "table" and value.event == nil then result = value end
  end
  return result
end

-- Peak level (0..1) of 16-bit little-endian PCM WAV data with a 44-byte header, or nil.
function core.wavPeak(data)
  if type(data) ~= "string" or #data < 46 or data:sub(1, 4) ~= "RIFF" then return nil end
  local peak = 0
  for i = 45, #data - 1, 2 do
    local sample = math.abs(string.unpack("<i2", data, i))
    if sample > peak then peak = sample end
  end
  return peak / 32768
end

-- Explains a "No speech detected" result when the microphone looks like the cause.
-- `peak` is 0..1 (or nil), `volume` the input volume in percent (or nil).
function core.noSpeechHint(deviceName, volume, peak)
  if peak == 0 then
    return string.format("%s delivered no sound at all. Another app may be blocking it.", deviceName or "The mic")
  end
  local quiet = peak and peak < 0.03
  if not quiet then return nil end
  local hint = string.format("Mic level very low (%s", deviceName or "input")
  if volume and volume < 60 then hint = hint .. string.format(", input volume %d%%", math.floor(volume + 0.5)) end
  return hint .. "). Check System Settings → Sound → Input."
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

-- Classifies a process using the microphone (from DeepgramRecorder --mic-users).
-- Returns { kind = "app", key, name } for meeting apps, { kind = "browser", key, name, browser }
-- for browsers (whose tabs still need checking), or nil.
function core.classifyMicUser(bundleID)
  if type(bundleID) ~= "string" then return nil end
  local app = core.MEETING_APPS[bundleID]
  if app then return { kind = "app", key = bundleID, name = app } end
  for _, b in ipairs(core.BROWSERS) do
    if bundleID == b.prefix or bundleID:sub(1, #b.prefix + 1) == b.prefix .. "." then
      return { kind = "browser", key = b.app, name = b.name, browser = b }
    end
  end
  return nil
end

-- Name of the first meeting service among `urls`, or nil.
function core.meetingFromUrls(urls)
  for _, url in ipairs(urls or {}) do
    local lower = tostring(url):lower()
    for _, m in ipairs(core.MEETING_URLS) do
      if lower:match(m.pattern) then return m.name end
    end
  end
  return nil
end

function core.meetingFromTitles(titles)
  for _, title in ipairs(titles or {}) do
    for _, m in ipairs(core.MEETING_TITLES) do
      if tostring(title):match(m.pattern) then return m.name end
    end
  end
  return nil
end

-- Flattens AppleScript's `URL of every tab of every window` result (a list of lists).
function core.flattenUrls(value)
  local out = {}
  local function walk(v)
    if type(v) == "table" then
      for _, x in ipairs(v) do walk(x) end
    elseif type(v) == "string" then
      table.insert(out, v)
    end
  end
  walk(value)
  return out
end

-- Tracks how long a detected meeting has been gone. Returns true once it has been absent for
-- at least `grace` seconds; any sighting resets the clock.
function core.newEndTracker(grace)
  local goneSince
  return function(present, now)
    if present then goneSince = nil return false end
    goneSince = goneSince or now
    return now - goneSince >= grace
  end
end

-- "4:05" or "1:02:03" for an elapsed number of seconds.
function core.formatElapsed(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- Recorded (unpaused) seconds of a meeting. `pausedTotal` is the time spent in finished pauses;
-- `pausedAt` is when the current pause began, or nil while recording.
function core.activeSeconds(startedAt, now, pausedTotal, pausedAt)
  local paused = (pausedTotal or 0) + (pausedAt and math.max(0, now - pausedAt) or 0)
  return math.max(0, now - startedAt - paused)
end

-- Text for the floating meeting indicator: (headline, detail).
function core.indicatorText(state, paused, elapsed, name)
  if state == "recording" then
    local headline = paused and "Paused" or "Transcribing"
    return headline, (name and (name .. " · ") or "") .. core.formatElapsed(elapsed)
  elseif state == "starting" then
    return "Starting…", name or ""
  elseif state == "stopping" or state == "transcribing" then
    return "Saving transcript…", "You'll get a notification"
  end
  return nil
end

-- Session directory name for a recording started at `t` (an os.date("*t") table).
function core.sessionName(t)
  return string.format("%04d-%02d-%02d_%02d-%02d-%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- Arguments for meeting_transcribe.py.
-- `claudePath` is set only when organizing with Claude is enabled and the CLI was found.
function core.transcribeArgs(cfg, script, sessionDir, transcriptsDir, dictionary, claudePath)
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
  if claudePath then
    table.insert(args, "--organize-with-claude")
    table.insert(args, claudePath)
    if cfg.claudeModel then
      table.insert(args, "--claude-model")
      table.insert(args, cfg.claudeModel)
    end
  end
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
