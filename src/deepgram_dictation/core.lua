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
  tailSeconds  = 0.5,         -- keep recording this long after the key is released
  bridgeBluetoothMic = true,  -- with AirPods or another Bluetooth mic, record the built-in mic until it is live
  recBinary    = nil,         -- path to sox's `rec`; auto-detected when nil
  dictionary   = nil,         -- path to dictionary JSON; defaults to <hs.configdir>/deepgram-dictionary.json
  keychainName = "deepgram-api-key",
  restoreClipboard = false,   -- true puts your previous clipboard back after pasting (the dictation is then
                              -- lost if the paste missed, e.g. focus moved while you spoke)
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
  grandmaHome      = nil,       -- e.g. "~/.grandma": file into grandma sweaters + write memory proposals

  -- Cleaning up dictation with Claude (sends each dictation's text to Anthropic's API)
  cleanup          = false,     -- remove repeats and false starts, apply self-corrections, fix misheard words
  cleanupModel     = "claude-haiku-5-5",
  cleanupTimeout   = 2.5,       -- seconds; when Claude is slower the raw transcript is pasted
  anthropicKeychainName = "anthropic-api-key",
  keytermNames     = 50,        -- names (most mentioned first) Deepgram is primed with; all go to Claude
  keepDictations   = 0,         -- keep the last N dictations (audio + text) for review and replay

  -- Asking about the screen: hold Control as well as the hotkey (sends a screenshot to Anthropic's API)
  screenAssist     = false,     -- Fn+Control: ask grandma about the screen, or have her write something
  screenModel      = "claude-sonnet-5-5",
  screenEffort     = "low",     -- how hard Claude thinks: "low", "medium" or "high"
  screenTimeout    = 20,        -- seconds to wait for an answer

  -- Learning from what you say to grandma (needs grandmaHome; writes proposals for `grandma review`)
  learnFromVoice   = true,      -- distill each day's screen questions, fills and corrections; "remember ..."
  learnStyle       = false,     -- also learn how you write from your dictations (patterns, never content)

  -- Sounds: soft notes and needle taps for grandma's moments. Silent while a call could hear them.
  sounds           = true,
  soundVolume      = 0.5,       -- 0 to 1, on top of the system volume
  dictationSounds  = false,     -- also a faint tick when a plain dictation starts and is pasted
  soundsOff        = nil,       -- e.g. { think = true }: names in src/deepgram_dictation/sounds/

  -- Background tasks: "review this PR" starts a Claude Code session in the background (needs screenAssist)
  backgroundTasks  = true,
  taskWorkspace    = "~/Documents/grandma-tasks", -- where a task with no project folder runs
  taskModel        = nil,       -- e.g. "opus"; nil uses the CLI's default model
  taskMinutes      = 45,        -- a task still working after this long is stopped
  maxTasks         = 3,         -- running at once
}

core.OPTIONS = {
  recBinary = true, dictionary = true, meetingLanguage = true, transcriptsDir = true,
  recorderApp = true, python = true, claudePath = true, claudeModel = true, grandmaHome = true,
  soundsOff = true, taskModel = true,
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

-- Held together with the hotkey, this modifier turns a dictation into a question about the screen.
core.SCREEN_FLAG = "ctrl"
core.SCREEN_EFFORTS = { low = true, medium = true, high = true }

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

-- Where the recorder app, meeting sessions, saved dictations and extracted names live.
function core.supportDir()
  return os.getenv("HOME") .. "/Library/Application Support/deepgram-dictation"
end

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
  for _, name in ipairs({ "minSeconds", "tailSeconds" }) do
    if type(cfg[name]) ~= "number" or cfg[name] < 0 then
      error("deepgram-dictation: " .. name .. " must be a non-negative number", 2)
    end
  end
  if not core.MEETING_MODES[cfg.meetingMode] then
    error("deepgram-dictation: meetingMode must be \"online\" or \"inPerson\"", 2)
  end
  for _, name in ipairs({ "cleanupTimeout", "screenTimeout" }) do
    if type(cfg[name]) ~= "number" or cfg[name] <= 0 then
      error("deepgram-dictation: " .. name .. " must be a positive number of seconds", 2)
    end
  end
  if not core.SCREEN_EFFORTS[cfg.screenEffort] then
    error("deepgram-dictation: screenEffort must be \"low\", \"medium\" or \"high\"", 2)
  end
  if cfg.screenAssist and core.HOTKEYS[cfg.hotkey].flag == core.SCREEN_FLAG then
    error("deepgram-dictation: screenAssist uses Control, so the hotkey can't be a Control key", 2)
  end
  for _, name in ipairs({ "taskMinutes", "maxTasks" }) do
    if math.type(cfg[name]) ~= "integer" or cfg[name] < 1 then
      error("deepgram-dictation: " .. name .. " must be a positive integer", 2)
    end
  end
  if type(cfg.taskWorkspace) ~= "string" or cfg.taskWorkspace == "" then
    error("deepgram-dictation: taskWorkspace must be a folder path", 2)
  end
  for _, name in ipairs({ "keepDictations", "keytermNames" }) do
    local n = cfg[name]
    if math.type(n) ~= "integer" or n < 0 then
      error("deepgram-dictation: " .. name .. " must be a non-negative integer", 2)
    end
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

-- Normalises a decoded dictionary JSON value into { keyterms = {...}, names = {...},
-- replacements = {...} }, dropping malformed entries.
function core.normalizeDictionary(data)
  local dict = { keyterms = {}, names = {}, replacements = {} }
  if type(data) ~= "table" then return dict end
  for _, field in ipairs({ "keyterms", "names" }) do
    for _, term in ipairs(type(data[field]) == "table" and data[field] or {}) do
      if type(term) == "string" and term:match("%S") then table.insert(dict[field], term) end
    end
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

-- Names for cleanup: the dictionary's own `names` first, then `extracted.names` (e.g. from
-- grandma memory, most mentioned first), without case-insensitive duplicates. Returns all names,
-- and the Deepgram keyterms: the dictionary's keyterms and names, then the first `limit` of
-- `extracted.keyterms` (extracted names minus common words).
function core.mergeNames(dict, extracted, limit)
  extracted = extracted or {}
  local names, seen = {}, {}
  local function add(list, name)
    local key = type(name) == "string" and name:match("^%s*(.-)%s*$"):lower()
    if key and key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(list, (name:match("^%s*(.-)%s*$")))
    end
  end
  for _, n in ipairs(dict.names or {}) do add(names, n) end
  for _, n in ipairs(extracted.names or {}) do add(names, n) end
  local keyterms = {}
  seen = {}
  for _, t in ipairs(dict.keyterms or {}) do add(keyterms, t) end
  for _, t in ipairs(dict.names or {}) do add(keyterms, t) end
  local extra = extracted.keyterms or {}
  for i = 1, math.min(limit or 0, #extra) do add(keyterms, extra[i]) end
  return names, keyterms
end

-- System prompt for cleanup: the instructions plus the names to spell correctly.
function core.cleanupSystemPrompt(instructions, names)
  if not names or #names == 0 then return instructions end
  return instructions:gsub("%s+$", "") .. "\n\nNames list:\n" .. table.concat(names, ", ") .. "\n"
end

-- Messages API request body for cleaning `text`. The system prompt is the same on every
-- dictation, so it is cached; thinking is off because the edit is mechanical and latency matters.
function core.cleanupRequest(cfg, systemPrompt, text)
  return {
    model = cfg.cleanupModel,
    max_tokens = 64 + math.ceil(#text / 2), -- English runs about 4 characters a token
    thinking = { type = "disabled" },
    output_config = { effort = "low" },
    system = { { type = "text", text = systemPrompt, cache_control = { type = "ephemeral" } } },
    messages = { { role = "user", content = "<transcript>" .. text .. "</transcript>" } },
  }
end

-- Swear words, as Lua patterns matched against lowercased whole words.
core.SWEARS = { "^fuck", "^shit", "^bullshit", "^damn", "^hell$", "^bitch", "^crap", "^bloody$", "^ass$", "^asshole" }

-- How many swear words `text` contains.
function core.swearCount(text)
  local n = 0
  for word in tostring(text):lower():gmatch("%a+") do
    for _, pattern in ipairs(core.SWEARS) do
      if word:match(pattern) then n = n + 1 break end
    end
  end
  return n
end

function core.wordCount(text)
  local n = 0
  for _ in tostring(text):gmatch("%S+") do n = n + 1 end
  return n
end

-- The cleaned text from a decoded Messages API response, or nil plus why it was rejected.
-- Cleanup only ever removes or swaps words, so an answer that grew (Claude replying to the
-- dictation) or shrank drastically (a summary) is rejected and the raw text pasted instead.
function core.parseCleanup(resp, raw)
  if type(resp) ~= "table" then return nil, "unexpected response" end
  if resp.type == "error" then
    return nil, "api error: " .. tostring(type(resp.error) == "table" and resp.error.message or resp.error)
  end
  if resp.stop_reason ~= "end_turn" then return nil, "stopped: " .. tostring(resp.stop_reason) end
  local parts = {}
  for _, block in ipairs(type(resp.content) == "table" and resp.content or {}) do
    if type(block) == "table" and block.type == "text" then table.insert(parts, block.text) end
  end
  local text = table.concat(parts):gsub("</?transcript>", ""):match("^%s*(.-)%s*$")
  if text == "" then return nil, "empty answer" end
  local before, after = core.wordCount(raw), core.wordCount(text)
  if after > before + 2 then return nil, string.format("answer grew from %d to %d words", before, after) end
  if before >= 6 and after < before * 0.4 then
    return nil, string.format("answer shrank from %d to %d words", before, after)
  end
  -- Cleanup swaps the odd misheard word; an answer is made of words the speaker never said.
  local said = {}
  for w in raw:lower():gmatch("[%w']+") do said[w] = true end
  local new = 0
  for w in text:lower():gmatch("[%w']+") do if not said[w] then new = new + 1 end end
  if new > 2 + after * 0.3 then return nil, string.format("%d of %d words were never said", new, after) end
  -- Swearing is how the speaker talks, never something to clean up. Repeats ("fuck fuck") are
  -- rare enough that losing those fixes is the right trade for a guarantee.
  if core.swearCount(text) < core.swearCount(raw) then return nil, "removed swearing" end
  return text
end

-- Stems of saved dictations to delete so that only the newest `keep` remain. Stems are
-- timestamps, so they sort oldest first.
function core.dictationsToPrune(stems, keep)
  local sorted = {}
  for _, s in ipairs(stems) do table.insert(sorted, s) end
  table.sort(sorted)
  local out = {}
  for i = 1, #sorted - keep do table.insert(out, sorted[i]) end
  return out
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

-- "Grandma, remember ..." asked with Fn+Control: what to remember, or nil when the question is
-- something else. Speech-to-text punctuates freely, so commas and a leading "hey" or "grandma"
-- are allowed. A question ("Remember which tab had the invoice?") is still a question.
core.REMEMBER_PATTERNS = { "^remember%s+(.+)$", "^note%s+that%s+(.+)$", "^make%s+a%s+note%s+(.+)$" }
local REMEMBER_NOT = { "what", "which", "where", "when", "who", "whose", "why", "how", "if", "whether" }

function core.rememberText(question)
  if tostring(question or ""):match("%?%s*$") then return nil end
  local q = tostring(question or ""):gsub("[,.:;!]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
  local lower = q:lower():gsub("^hey%s+", ""):gsub("^grandma%s+", "")
  local offset = #q - #lower
  for i, pattern in ipairs(core.REMEMBER_PATTERNS) do
    local rest = lower:match(pattern)
    if rest then
      local first = rest:match("^(%a+)")
      for _, word in ipairs(i == 1 and REMEMBER_NOT or {}) do
        if first == word then return nil end -- "remember which tab ..." asks, unpunctuated
      end
      local start = offset + #lower - #rest + 1
      return (q:sub(start):gsub("^[Tt]hat%s+", ""))
    end
  end
  return nil
end

-- Dictations worth learning style from: long enough to show how someone writes.
function core.styleWorthy(text)
  return core.wordCount(text) >= 8
end

-- Whether a flagsChanged event while the hotkey is held asks about the screen. Control can go
-- down before or after the hotkey, and the dictation stays a screen question once it has.
function core.wantsScreen(cfg, flags)
  return cfg.screenAssist == true and flags[core.SCREEN_FLAG] == true
end

-- What grandma returns for a screen question: text to paste where the user is typing, an answer
-- to show them, fields she will fill in on screen once the user confirms, or a task she hands to
-- a background agent.
core.SCREEN_SCHEMA = {
  type = "object",
  properties = {
    kind = { type = "string", enum = { "insert", "answer", "fill", "task", "work" } },
    text = { type = "string" },
    asked = { type = "boolean" },    -- they told her outright to do it: a fill or work starts without asking
    replaces = { type = "string" },  -- for insert: the text on screen it replaces, exactly, else ""
    gist = { type = "string" },      -- for answer: the whole answer in one short line, shown bold on top
    fields = {
      type = "array",
      items = {
        type = "object",
        properties = {
          label = { type = "string" },
          value = { type = "string" },
          upload = { type = "string" }, -- id of a memory image for an upload field, else ""
          skip = { type = "boolean" },
        },
        required = { "label", "value", "upload", "skip" },
        additionalProperties = false,
      },
    },
    task = {
      type = "object",
      properties = {
        title = { type = "string" },   -- a few words, shown in notifications and the menu
        goal = { type = "string" },    -- the task restated, complete enough to work from alone
        target = { type = "string" },  -- what on screen it is about: a URL, a PR, a file; "" if none
        memory = { type = "string" },  -- the sweater or project from the catalog it belongs to, or ""
        edits = { type = "boolean" },  -- whether it may change code or files
        minutes = { type = "integer" }, -- a rough guess of how long it takes
      },
      required = { "title", "goal", "target", "memory", "edits", "minutes" },
      additionalProperties = false,
    },
  },
  required = { "kind", "text", "gist", "asked", "replaces", "fields", "task" },
  additionalProperties = false,
}

-- Lets Claude read a sweater or project from the user's grandma memory when the screen turns out
-- to be about one the question didn't name.
function core.openMemoryTool(names)
  return {
    name = "open_memory",
    description = "Read the user's memory for one of their sweaters or projects from the catalog. "
      .. "Use it when the screen or question is about one whose memory isn't included yet.",
    input_schema = {
      type = "object",
      properties = { name = { type = "string", enum = names } },
      required = { "name" },
      additionalProperties = false,
    },
  }
end

-- Messages API request body for a spoken `question` about a screenshot (base64 `image`).
-- Thinking is adaptive (Sonnet 5.5 can't turn it off) and kept short with a low effort.
-- `memory` (optional, from grandma_context.py) adds what grandma knows: the profile and the
-- catalog in the system prompt, memory the question named before the screenshot, and the
-- open_memory tool. The unchanging parts are cached.
function core.screenRequest(cfg, systemPrompt, question, image, mediaType, memory)
  local system = { { type = "text", text = systemPrompt } }
  local content = {}
  local tools
  if memory then
    local about = {}
    if memory.profile and memory.profile ~= "" then
      table.insert(about, "<profile>\n" .. memory.profile .. "\n</profile>")
    end
    if memory.catalog and memory.catalog ~= "" then
      table.insert(about, "<memory_catalog>\n" .. memory.catalog .. "\n</memory_catalog>")
    end
    if #about > 0 then table.insert(system, { type = "text", text = table.concat(about, "\n\n") }) end
    for _, m in ipairs(memory.memory or {}) do
      table.insert(content, { type = "text", text = string.format('<memory name="%s" kind="%s">\n%s\n</memory>',
        m.name, m.kind, m.text) })
    end
    for _, block in ipairs(core.imageBlocks(memory.images)) do table.insert(content, block) end
    if #content > 0 then content[#content].cache_control = { type = "ephemeral" } end
    if memory.openable and #memory.openable > 0 then tools = { core.openMemoryTool(memory.openable) } end
  end
  system[#system].cache_control = { type = "ephemeral" }
  table.insert(content, { type = "image",
    source = { type = "base64", media_type = mediaType or "image/jpeg", data = image } })
  table.insert(content, { type = "text", text = "<question>" .. question .. "</question>" })
  return {
    model = cfg.screenModel,
    max_tokens = 4096,
    thinking = { type = "adaptive" },
    output_config = { effort = cfg.screenEffort, format = { type = "json_schema", schema = core.SCREEN_SCHEMA } },
    system = system,
    tools = tools,
    messages = { { role = "user", content = content } },
  }
end

-- Memory images as content: for each, what memory says about it, then a small thumbnail, so
-- Claude can choose which one an upload field wants by what it shows.
function core.imageBlocks(images)
  local out = {}
  for _, img in ipairs(images or {}) do
    if type(img.thumb) == "string" and img.thumb ~= "" then
      table.insert(out, { type = "text", text = string.format(
        '<memory_image id="%s" file="%s" size="%dx%d">%s</memory_image>', img.id, img.name,
        tonumber(img.width) or 0, tonumber(img.height) or 0, img.note or "") })
      table.insert(out, { type = "image", source = { type = "base64", media_type = "image/jpeg", data = img.thumb } })
    end
  end
  return out
end

-- The open_memory calls in a response that stopped to use tools: { { id, name } }.
function core.memoryRequests(resp)
  local out = {}
  if type(resp) ~= "table" or resp.stop_reason ~= "tool_use" then return out end
  for _, block in ipairs(type(resp.content) == "table" and resp.content or {}) do
    if type(block) == "table" and block.type == "tool_use" then
      local input = type(block.input) == "table" and block.input or {}
      table.insert(out, { id = block.id, name = input.name, tool = block.name })
    end
  end
  return out
end

-- Continues `body` after `resp` used tools: Claude's turn as it came (thinking blocks included,
-- which must go back unchanged), then a result for each call: { id, text, isError }.
function core.continueWithResults(body, resp, results)
  local content = {}
  for _, r in ipairs(results) do
    local value = r.text
    local pictures = core.imageBlocks(r.images)
    if #pictures > 0 then
      value = { { type = "text", text = r.text } }
      for _, block in ipairs(pictures) do table.insert(value, block) end
    end
    table.insert(content, { type = "tool_result", tool_use_id = r.id, content = value, is_error = r.isError or nil })
  end
  table.insert(body.messages, { role = "assistant", content = resp.content })
  table.insert(body.messages, { role = "user", content = content })
  return body
end

-- { kind, text } from a decoded Messages API response, or nil plus what went wrong. A reply
-- that isn't the expected JSON is still shown, as an answer, rather than thrown away.
function core.parseScreenAnswer(resp, decode, images)
  if type(resp) ~= "table" then return nil, "unexpected response" end
  if resp.type == "error" then
    return nil, "api error: " .. tostring(type(resp.error) == "table" and resp.error.message or resp.error)
  end
  if resp.stop_reason == "refusal" then return nil, "Claude declined to answer" end
  if resp.stop_reason ~= "end_turn" then return nil, "stopped: " .. tostring(resp.stop_reason) end
  local parts = {}
  for _, block in ipairs(type(resp.content) == "table" and resp.content or {}) do
    if type(block) == "table" and block.type == "text" then table.insert(parts, block.text) end
  end
  local raw = table.concat(parts):match("^%s*(.-)%s*$")
  if raw == "" then return nil, "empty answer" end
  local ok, value = pcall(decode, raw)
  if ok and type(value) == "table" and value.kind == "fill" then
    local fields = core.fillFields(value.fields, images)
    if #fields > 0 then
      return { kind = "fill", text = type(value.text) == "string" and value.text:match("^%s*(.-)%s*$") or "",
               fields = fields, asked = value.asked == true or nil }
    end
  end
  if ok and type(value) == "table" and value.kind == "work" and type(value.text) == "string"
      and value.text:match("%S") then
    return { kind = "work", text = value.text:match("^%s*(.-)%s*$"), asked = value.asked == true or nil }
  end
  if ok and type(value) == "table" and value.kind == "task" then
    local task = core.taskFrom(value.task)
    if task then return { kind = "task", text = type(value.text) == "string" and value.text or "", task = task } end
  end
  if ok and type(value) == "table" and (value.kind == "insert" or value.kind == "answer")
      and type(value.text) == "string" and value.text:match("%S") then
    local replaces = value.kind == "insert" and type(value.replaces) == "string"
      and value.replaces:match("^%s*(.-)%s*$") or ""
    local gist = value.kind == "answer" and type(value.gist) == "string" and value.gist:match("^%s*(.-)%s*$") or ""
    return { kind = value.kind, text = value.text:match("^%s*(.-)%s*$"), replaces = replaces ~= "" and replaces or nil,
             gist = gist ~= "" and gist or nil }
  end
  return { kind = "answer", text = raw }
end

-- Text folded for matching what Claude read off a screenshot against a field's real value: runs
-- of whitespace become one space and curly quotes straight ones. Returns the folded text and, for
-- each of its bytes, the byte in `s` it came from.
local FOLD = { ["\u{2018}"] = "'", ["\u{2019}"] = "'", ["\u{201C}"] = '"', ["\u{201D}"] = '"', ["\u{A0}"] = " " }
local function fold(s)
  local out, from = {}, {}
  for pos, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    ch = FOLD[ch] or ch
    if ch:match("^%s$") then
      if #out > 0 and out[#out] ~= " " then table.insert(out, " ") table.insert(from, pos) end
    else
      for i = 1, #ch do table.insert(out, ch:sub(i, i)) table.insert(from, pos) end
    end
  end
  if out[#out] == " " then table.remove(out) table.remove(from) end
  return table.concat(out), from
end

-- UTF-16 code units in `s` (what Accessibility text ranges count).
local function utf16Len(s)
  local n = 0
  for _, cp in utf8.codes(s) do n = n + (cp > 0xFFFF and 2 or 1) end
  return n
end

-- Where `original` (as read off the screen) sits in `value` (the field's text), as an
-- Accessibility range { location, length }, or nil. Exact first, then ignoring whitespace and
-- quote style, then by its first and last words when a few letters in the middle were misread.
function core.findSpan(value, original)
  if type(value) ~= "string" or type(original) ~= "string" or not original:match("%S") then return nil end
  if not utf8.len(value) or not utf8.len(original) then return nil end
  local function range(first, last) -- byte positions in value, inclusive
    return { location = utf16Len(value:sub(1, first - 1)), length = utf16Len(value:sub(first, last)) }
  end
  local a, b = value:find(original, 1, true)
  if a then return range(a, b) end
  local fv, from = fold(value)
  local fo = fold(original)
  local function lastByte(i) -- the last byte of the character folded byte i came from
    local start = from[i]
    local nextStart = #value + 1
    for j = i + 1, #from do if from[j] ~= start then nextStart = from[j] break end end
    return nextStart - 1
  end
  a, b = fv:find(fo, 1, true)
  if a then return range(from[a], lastByte(b)) end
  local edge = math.min(40, math.floor(#fo / 3))
  if edge < 12 then return nil end
  local head, tail = fo:sub(1, edge), fo:sub(-edge)
  a = fv:find(head, 1, true)
  if not a or fv:find(head, a + 1, true) then return nil end -- missing, or not one place
  local t = fv:find(tail, a, true)
  if not t then return nil end
  b = t + #tail - 1
  local span = b - a + 1
  if span < #fo * 0.8 or span > #fo * 1.25 then return nil end
  return range(from[a], lastByte(b))
end

-- The well-formed fields of a fill plan: { { label, value, skip, file } }. An upload field names
-- one of `images` (memory images offered with the question, by id) and gets its `file`
-- ({ id, path, name }); one naming anything else, or a field with no value, is skipped.
function core.fillFields(list, images)
  local byId = {}
  for _, img in ipairs(images or {}) do byId[img.id] = img end
  local out = {}
  for _, f in ipairs(type(list) == "table" and list or {}) do
    if type(f) == "table" and type(f.label) == "string" and f.label:match("%S") then
      local value = type(f.value) == "string" and f.value or ""
      local img = type(f.upload) == "string" and f.upload ~= "" and byId[f.upload]
      local field = { label = f.label:match("^%s*(.-)%s*$"), value = img and "" or value,
                      skip = f.skip == true or not (img or value:match("%S")) }
      if img then field.file = { id = img.id, path = img.path, name = img.name } end
      table.insert(out, field)
    end
  end
  return out
end

-- Filling a form on screen with Claude's computer-use toolset ---------------------------------

-- The toolset members grandma may use. Everything else is switched off in the request and
-- refused here too: no right or middle clicks, drags, raw mouse buttons or held keys.
core.FILL_ACTIONS = {
  screenshot = true, zoom = true, left_click = true, triple_click = true, type = true, key = true,
  scroll = true, wait = true, cursor_position = true,
}
core.FILL_DISABLED = {
  "right_click", "middle_click", "double_click", "left_click_drag", "mouse_move", "left_mouse_down",
  "left_mouse_up", "hold_key",
}
-- Keys she may press. Return and Enter are left out on purpose: they submit forms.
core.FILL_KEYS = {
  tab = true, ["shift+tab"] = true, backspace = true, delete = true, up = true, down = true,
  left = true, right = true, escape = true, ["cmd+a"] = true, space = true,
}
-- Hard caps on a fill, scaled to the plan: a 5-field form gets about the 40 actions and 90 s it
-- needs, uploads and bigger forms more, never past 80 actions or 3 minutes.
function core.fillLimits(fields)
  local n = 0
  for _, f in ipairs(fields or {}) do
    if not f.skip then n = n + (f.file and 2 or 1) end
  end
  return math.min(80, 15 + 5 * n), math.min(180, 30 + 12 * n)
end
-- Sonnet 5.5's limits for an image in a tool result.
core.FILL_MAX_EDGE = 2576
core.FILL_MAX_PIXELS = 3600000

function core.fillToolset()
  local configs = {}
  for _, name in ipairs(core.FILL_DISABLED) do configs[name] = { enabled = false } end
  return { type = "computer_toolset_20260801", configs = configs }
end

-- Scale from screen points to screenshot pixels: 1 unless the screen is too big to send whole.
function core.fillScale(w, h)
  return math.min(1, core.FILL_MAX_EDGE / math.max(w, h), math.sqrt(core.FILL_MAX_PIXELS / (w * h)))
end

-- A screenshot coordinate as a global screen point, for a display with `frame` (points).
function core.fillPoint(coordinate, frame, scale)
  if type(coordinate) ~= "table" or type(coordinate[1]) ~= "number" or type(coordinate[2]) ~= "number" then
    return nil
  end
  local x, y = coordinate[1] / scale, coordinate[2] / scale
  if x < 0 or y < 0 or x > frame.w or y > frame.h then return nil end
  return { x = frame.x + x, y = frame.y + y }
end

-- "shift+tab" as Hammerspoon mods and key: { "shift" }, "tab".
function core.fillKey(text)
  local parts = {}
  for part in tostring(text):lower():gmatch("[^+]+") do table.insert(parts, (part:gsub("%s", ""))) end
  local key = table.remove(parts)
  local mods = {}
  for _, m in ipairs(parts) do table.insert(mods, (m == "super" or m == "command") and "cmd" or m) end
  return mods, key
end

-- Whether grandma may run this computer action, given the plan the user confirmed. Returns true,
-- or false and why. Typing is limited to the confirmed values, so nothing on screen can make her
-- type anything else.
function core.checkFillAction(name, input, fields, uploaded)
  input = type(input) == "table" and input or {}
  if name == "upload_file" then
    local file = core.fillUploads(fields)[input.file]
    if not file then return false, "only the files the user confirmed can be uploaded" end
    if ((uploaded or {})[input.file] or 0) >= 2 then return false, "that file was already tried twice" end
    return true
  end
  if not core.FILL_ACTIONS[name] then return false, name .. " isn't allowed while filling" end
  if name == "type" then
    local text = type(input.text) == "string" and input.text or ""
    for _, f in ipairs(fields or {}) do
      if not f.skip and f.value == text then return true end
    end
    return false, "only the values the user confirmed can be typed"
  end
  if name == "key" then
    local mods, key = core.fillKey(input.text)
    local combo = (#mods > 0 and (table.concat(mods, "+") .. "+") or "") .. tostring(key)
    if not core.FILL_KEYS[combo] then return false, "the " .. tostring(input.text) .. " key isn't allowed" end
    if input["repeat"] ~= nil and (type(input["repeat"]) ~= "number" or input["repeat"] > 30) then
      return false, "too many repeats"
    end
  end
  return true
end

-- Accessibility roles grandma may click. Buttons, links, checkboxes (consent) and menu items
-- are refused, so she can't save, submit, delete, publish or agree to anything. A menu item is
-- allowed only in a menu she just opened from a pop-up or combo box (choosing an option).
core.FILL_CLICK_ROLES = {
  AXTextField = true, AXTextArea = true, AXComboBox = true, AXPopUpButton = true, AXSearchField = true,
  AXRadioButton = true,
}

function core.fillClickAllowed(role, subrole, menuOpen)
  if subrole == "AXSecureTextField" then return false, "password fields are never filled" end
  if core.FILL_CLICK_ROLES[role] then return true end
  if role == "AXMenuItem" and menuOpen then return true end
  return false, "clicking " .. tostring(role or "an unknown element") .. " isn't allowed"
end

-- A tool_result for a computer action (every one must name the toolset).
function core.fillResult(id, content, isError)
  return { type = "tool_result", tool_use_id = id, toolset_name = "computer", content = content,
           is_error = isError or nil }
end

-- A tool_result for grandma's own tools (upload_file), which don't belong to the toolset.
function core.toolResult(id, content, isError)
  return { type = "tool_result", tool_use_id = id, content = content, is_error = isError or nil }
end

function core.fillImage(id, data)
  return core.fillResult(id, {
    { type = "image", source = { type = "base64", media_type = "image/jpeg", data = data } },
  })
end

-- The actions in a response: { { id, name, input, computer } }, computer actions and uploads.
function core.fillActions(resp)
  local out = {}
  for _, block in ipairs(type(resp) == "table" and type(resp.content) == "table" and resp.content or {}) do
    if type(block) == "table" and block.type == "tool_use" then
      local input = type(block.input) == "table" and block.input or {}
      table.insert(out, { id = block.id, name = block.name, input = input,
                          computer = block.toolset_name == "computer" })
    end
  end
  return out
end

-- The confirmed plan as the user message that starts the fill.
function core.fillPlanText(fields)
  local lines = { "Fill in these fields on screen. Type each value exactly as written:" }
  for _, f in ipairs(fields) do
    if not f.skip and f.file then
      table.insert(lines, string.format("- %s: upload file %s (%s) with upload_file", f.label, f.file.id, f.file.name))
    elseif not f.skip then
      table.insert(lines, string.format("- %s: %s", f.label, f.value))
    end
  end
  return table.concat(lines, "\n")
end

-- The confirmed uploads: { [id] = { id, path, name } }.
function core.fillUploads(fields)
  local out = {}
  for _, f in ipairs(fields or {}) do
    if not f.skip and f.file then out[f.file.id] = f.file end
  end
  return out
end

-- Puts a confirmed file into an upload field or drop zone. The upload itself is done by
-- screen_fill.lua (a file dialog, or a real drag), never by typing or clicking through Claude.
function core.uploadTool(ids)
  return {
    name = "upload_file",
    description = "Upload one of the confirmed files into the upload button or drop zone at `coordinate` "
      .. "(screenshot pixels). Point at the upload button, or at the middle of the drop zone.",
    input_schema = {
      type = "object",
      properties = {
        file = { type = "string", enum = ids },
        coordinate = { type = "array", items = { type = "number" } },
      },
      required = { "file", "coordinate" },
      additionalProperties = false,
    },
  }
end

-- Words on an upload control. A button is clicked to upload only when its label reads like one
-- of these and none of the refused ones: "Upload & publish" is refused.
core.UPLOAD_WORDS = { "upload", "choose", "browse", "select", "add", "replace", "change", "attach", "drop", "drag" }
core.UPLOAD_REFUSED = { "save", "submit", "publish", "send", "pay", "delete", "remove", "post", "confirm",
                        "buy", "order", "checkout", "cart", "sign", "agree", "accept", "next", "continue", "done" }

-- Roles a drop zone shows up as (Brave: a plain text element reading "Drop your logo here").
-- Files are only ever dragged onto these, never onto buttons or links.
core.DROP_ROLES = { AXGroup = true, AXStaticText = true, AXImage = true, AXWebArea = true, AXUnknown = true }

function core.dropTarget(role) return core.DROP_ROLES[role] == true end

-- Whether the upload click may go to an element with this role and label. Drop zones are plain
-- page areas (groups, text, images); buttons and links need an upload label.
function core.uploadClickAllowed(role, label)
  local text = tostring(label or ""):lower()
  for _, word in ipairs(core.UPLOAD_REFUSED) do
    if text:find("%f[%a]" .. word) then return false, "the upload target reads \"" .. tostring(label) .. "\"" end
  end
  if role == "AXButton" or role == "AXLink" then
    for _, word in ipairs(core.UPLOAD_WORDS) do
      if text:find("%f[%a]" .. word) then return true end
    end
    return false, "that button isn't an upload button"
  end
  if core.dropTarget(role) then return true end
  return false, "can't upload into " .. tostring(role or "an unknown element")
end

-- Roles that act when clicked or when Space is pressed on them.
core.FILL_PRESSABLE = {
  AXButton = true, AXLink = true, AXCheckBox = true, AXMenuItem = true, AXMenuButton = true,
  AXDisclosureTriangle = true,
}

-- What a click at a point really lands on, from the element under it and its ancestors
-- ({ { role, label } }, innermost first). Text and images inside a button or link (Chromium
-- reports those first) count as that button or link, so its label is the one checked.
function core.clickTarget(chain)
  for _, el in ipairs(chain or {}) do
    if core.FILL_PRESSABLE[el.role] then return el.role, el.label end
  end
  local first = (chain or {})[1] or {}
  return first.role, first.label
end

-- Whether grandma may type (`name` "type") or press a key into the focused element. Typing a
-- space or pressing Space on a button, link or checkbox would press it, so neither goes to one.
function core.fillFocusAllowed(name, input, role, subrole)
  if subrole == "AXSecureTextField" then return false, "password fields are never filled" end
  if not core.FILL_PRESSABLE[role] then return true end
  local text = type(input) == "table" and input.text
  if name == "key" and select(2, core.fillKey(text)) ~= "space" then return true end
  return false, "the focus is on " .. role .. ", which typing would press"
end

function core.fillTools(fields)
  local ids = {}
  for id in pairs(core.fillUploads(fields)) do table.insert(ids, id) end
  table.sort(ids)
  local tools = { core.fillToolset() }
  if #ids > 0 then table.insert(tools, core.uploadTool(ids)) end
  return tools
end

function core.fillRequest(cfg, systemPrompt, fields, image)
  return {
    model = cfg.screenModel,
    max_tokens = 4096,
    thinking = { type = "adaptive" },
    output_config = { effort = cfg.screenEffort },
    system = { { type = "text", text = systemPrompt, cache_control = { type = "ephemeral" } } },
    tools = core.fillTools(fields),
    messages = { { role = "user", content = {
      { type = "text", text = core.fillPlanText(fields) },
      { type = "image", source = { type = "base64", media_type = "image/jpeg", data = image } },
    } } },
  }
end

-- Working on a page on screen: grandma first looks through it (survey: screenshots and scrolling
-- only) and proposes every change, then, once the user confirms, makes them (work). Work can
-- click what fill can't (buttons, links, tabs, menus, to select blocks and open panels) and save
-- drafts, but never anything that publishes, sends, pays or deletes. Typing stays limited to the
-- confirmed text, as in fill.

core.SURVEY_ACTIONS = { screenshot = true, zoom = true, scroll = true, wait = true, cursor_position = true }
core.WORK_ACTIONS = {
  screenshot = true, zoom = true, left_click = true, double_click = true, triple_click = true, type = true,
  key = true, scroll = true, wait = true, cursor_position = true,
}
-- Keys beyond fill's: undo, save (a draft), and Return or Shift+Return, which screen_fill.lua only
-- lets through while a multi-line text box has the focus.
core.WORK_KEYS = { ["cmd+z"] = true, ["cmd+s"] = true, ["return"] = true, ["shift+return"] = true }
core.NEWLINE_KEYS = { ["return"] = true, ["shift+return"] = true }
-- Words on something she must never click while working: whatever goes live, goes out, costs
-- money, or can't be undone.
core.WORK_REFUSED = { "publish", "unpublish", "update", "deploy", "go live", "launch", "submit", "send", "pay",
                      "buy", "checkout", "order", "purchase", "delete", "remove", "trash", "discard", "archive",
                      "share", "invite", "sign out", "log out", "logout", "post", "schedule", "upgrade" }

function core.workLimits(mode)
  if mode == "survey" then return 40, 150 end
  return 300, 1200
end

function core.workToolset(mode)
  local allowed = mode == "survey" and core.SURVEY_ACTIONS or core.WORK_ACTIONS
  local configs = {}
  for _, name in ipairs({ "left_click", "triple_click", "double_click", "type", "key", "right_click", "middle_click",
                          "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "hold_key" }) do
    if not allowed[name] then configs[name] = { enabled = false } end
  end
  return { type = "computer_toolset_20260801", configs = configs }
end

-- The key combo `text` names, as written in FILL_KEYS ("shift+tab").
function core.keyCombo(text)
  local mods, key = core.fillKey(text)
  return (#mods > 0 and (table.concat(mods, "+") .. "+") or "") .. tostring(key)
end

-- Whether a work or survey action may run (see checkFillAction). While working, text is typed
-- whole or one line of it at a time, so a long block of copy can go in paragraph by paragraph.
function core.checkWorkAction(mode, name, input, fields, uploaded)
  input = type(input) == "table" and input or {}
  if mode == "survey" then
    if core.SURVEY_ACTIONS[name] then return true end
    return false, name .. " isn't allowed while looking through the page"
  end
  if name == "upload_file" then return core.checkFillAction(name, input, fields, uploaded) end
  if not core.WORK_ACTIONS[name] then return false, name .. " isn't allowed" end
  if name == "type" then
    local text = type(input.text) == "string" and input.text or ""
    if text == "" then return false, "nothing to type" end
    for _, f in ipairs(fields or {}) do
      if not f.skip and f.value ~= "" then
        if f.value == text then return true end
        for line in (f.value .. "\n"):gmatch("(.-)\n") do
          if line ~= "" and line == text then return true end
        end
      end
    end
    return false, "only the text the user confirmed can be typed"
  end
  if name == "key" then
    local combo = core.keyCombo(input.text)
    if not (core.FILL_KEYS[combo] or core.WORK_KEYS[combo]) then
      return false, "the " .. tostring(input.text) .. " key isn't allowed"
    end
    if input["repeat"] ~= nil and (type(input["repeat"]) ~= "number" or input["repeat"] > 30) then
      return false, "too many repeats"
    end
  end
  return true
end

-- Whether a click while working may land on an element with this role and label (core.clickTarget).
-- Anything may be clicked except password fields and what reads like WORK_REFUSED. An element with
-- no label (an editor drawn on a canvas) can't be checked: allowed, and `unchecked` says so.
function core.workClickAllowed(role, subrole, label)
  if subrole == "AXSecureTextField" then return false, "password fields are never filled" end
  local text = tostring(label or ""):lower()
  for _, word in ipairs(core.WORK_REFUSED) do
    if text:find("%f[%a]" .. word .. "%f[%A]") then
      return false, "it reads \"" .. tostring(label) .. "\", and she never publishes, sends, pays or deletes"
    end
  end
  return true, nil, text == "" and core.FILL_PRESSABLE[role] == true
end

-- The tool she ends a survey with.
function core.proposeTool(imageIds)
  local change = {
    type = "object",
    properties = {
      where = { type = "string" },  -- which block or field, as on screen
      text = { type = "string" },   -- the exact new text, or "" for an upload
      upload = { type = "string" }, -- a memory image id, or ""
    },
    required = { "where", "text", "upload" },
    additionalProperties = false,
  }
  if #imageIds > 0 then change.properties.upload = { type = "string", enum = core.withEmpty(imageIds) } end
  return {
    name = "propose_changes",
    description = "End the look-through with every change to make, in page order. The user confirms them "
      .. "before anything is touched, and only this text can be typed afterwards.",
    input_schema = {
      type = "object",
      properties = { summary = { type = "string" }, changes = { type = "array", items = change } },
      required = { "summary", "changes" },
      additionalProperties = false,
    },
  }
end

function core.withEmpty(list)
  local out = { "" }
  for _, v in ipairs(list) do table.insert(out, v) end
  return out
end

-- A proposal as fill-style fields ({ label, value, skip, file }) and its summary.
function core.parseProposal(input, images)
  input = type(input) == "table" and input or {}
  local list = {}
  for _, c in ipairs(type(input.changes) == "table" and input.changes or {}) do
    if type(c) == "table" then
      table.insert(list, { label = c.where, value = c.text, upload = c.upload, skip = false })
    end
  end
  local summary = type(input.summary) == "string" and input.summary:match("^%s*(.-)%s*$") or ""
  return core.fillFields(list, images), summary
end

-- What the confirm card shows for a proposal.
function core.proposalText(fields, summary)
  local lines = {}
  if summary ~= "" then table.insert(lines, summary) table.insert(lines, "") end
  for _, f in ipairs(fields) do
    if f.file then table.insert(lines, string.format("%s: upload %s", f.label, f.file.name))
    elseif not f.skip then table.insert(lines, string.format("%s: %s", f.label, f.value)) end
  end
  table.insert(lines, "")
  table.insert(lines, "Return to make these changes, Esc to cancel. She may save a draft, never publish.")
  return table.concat(lines, "\n")
end

-- The request that starts a survey or a work run.
function core.workRequest(cfg, systemPrompt, mode, goal, fields, image, memory)
  local content = { { type = "text", text = "<task>" .. goal .. "</task>" } }
  local tools = { core.workToolset(mode) }
  if mode == "survey" then
    for _, m in ipairs(memory and memory.blocks or {}) do
      table.insert(content, { type = "text",
        text = string.format('<memory name="%s">\n%s\n</memory>', m.name, m.text) })
    end
    local ids = {}
    for _, block in ipairs(core.imageBlocks(memory and memory.images)) do table.insert(content, block) end
    for _, img in ipairs(memory and memory.images or {}) do table.insert(ids, img.id) end
    table.insert(tools, core.proposeTool(ids))
    table.insert(content, { type = "text", text = "Look through the page, then call propose_changes." })
  else
    table.insert(content, { type = "text", text = core.fillPlanText(fields):gsub("^Fill in these fields on screen.",
      "Make these confirmed changes on screen.") })
    local uploads = {}
    for id in pairs(core.fillUploads(fields)) do table.insert(uploads, id) end
    table.sort(uploads)
    if #uploads > 0 then table.insert(tools, core.uploadTool(uploads)) end
  end
  table.insert(content, { type = "image", source = { type = "base64", media_type = "image/jpeg", data = image } })
  return {
    model = cfg.screenModel,
    max_tokens = 8192,
    thinking = { type = "adaptive" },
    output_config = { effort = cfg.screenEffort },
    system = { { type = "text", text = systemPrompt .. "\n\n" .. (mode == "survey" and "Now: look through the page."
      or "Now: make the changes."), cache_control = { type = "ephemeral" } } },
    tools = tools,
    messages = { { role = "user", content = content } },
  }
end


-- Top-left corner for a `w` x `h` panel near `point`, kept inside `frame` with a margin.
function core.panelOrigin(point, w, h, frame, margin)
  margin = margin or 16
  local x = point.x + margin
  local y = point.y + margin
  if x + w > frame.x + frame.w - margin then x = point.x - w - margin end
  if y + h > frame.y + frame.h - margin then y = frame.y + frame.h - h - margin end
  x = math.max(frame.x + margin, math.min(x, frame.x + frame.w - w - margin))
  y = math.max(frame.y + margin, y)
  return { x = x, y = y }
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
    if cfg.grandmaHome then
      table.insert(args, "--grandma-home")
      table.insert(args, cfg.grandmaHome)
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

-- Whether sound `name` may play. Never while a call could hear it (`inCall`), the tick only with
-- dictationSounds, and nothing listed in soundsOff.
function core.soundAllowed(cfg, name, inCall)
  if not cfg.sounds or inCall then return false end
  if name == "tick" and not cfg.dictationSounds then return false end
  return not (type(cfg.soundsOff) == "table" and cfg.soundsOff[name])
end

-- Whether a call could hear a sound: an online meeting is being recorded, or something the
-- detector knows as a call app (or a browser) holds the mic.
function core.inCall(onlineMeeting, micCallers)
  return onlineMeeting == true or (type(micCallers) == "table" and next(micCallers) ~= nil)
end

-- The built-in mic's UID to cover a Bluetooth mic's start-up with (the recorder's --bridge-uid),
-- or nil. `default` is the default input's transport ("Bluetooth", "Built-in", ...); `inputs` is
-- { { uid, transport } } for every input device.
function core.bridgeMic(cfg, default, inputs)
  if not cfg.bridgeBluetoothMic or not tostring(default):find("^Bluetooth") then return nil end
  for _, d in ipairs(inputs or {}) do
    if d.transport == "Built-in" and d.uid then return d.uid end
  end
  return nil
end

-- Background tasks ----------------------------------------------------------------------------

core.TASK_CONFIRM_MINUTES = 10 -- a read-only task guessed to take longer than this asks first

-- A well-formed task from the model's `task` object, or nil.
function core.taskFrom(t)
  if type(t) ~= "table" or type(t.goal) ~= "string" or not t.goal:match("%S") then return nil end
  local function str(v) return type(v) == "string" and v:match("^%s*(.-)%s*$") or "" end
  local title = str(t.title)
  return { title = title ~= "" and title or str(t.goal):sub(1, 40), goal = str(t.goal), target = str(t.target),
           memory = str(t.memory), edits = t.edits == true, minutes = tonumber(t.minutes) or 0 }
end

-- Whether a task waits for the user's yes. A minor task (read-only, a clear target, quick) starts
-- at once; one that may change code, has nothing on screen to work from, or is long asks first.
-- Decided here, not by the model: a task started without asking never gets the edit tools.
function core.taskNeedsConfirm(task)
  return task.edits or task.target == "" or task.minutes > core.TASK_CONFIRM_MINUTES
end

-- What the confirm card says.
function core.taskPlanText(task)
  local lines = { task.goal }
  if task.target ~= "" then table.insert(lines, "On: " .. task.target) end
  if task.memory ~= "" then table.insert(lines, "With grandma's memory of " .. task.memory) end
  table.insert(lines, "")
  table.insert(lines, task.edits and "She may change code, on a new branch in her own worktree. Nothing is pushed."
    or "She only reads and looks things up.")
  table.insert(lines, "Return to start it in the background, Esc to cancel.")
  return table.concat(lines, "\n")
end

-- What changed in a background session, from the state it was last seen in (`was`) and its
-- Claude Code state.json (`state`): "blocked" (she needs the user), "done", "failed", "stopped",
-- or nil when there's nothing to tell.
core.TASK_ENDS = { blocked = true, done = true, failed = true, stopped = true }
function core.taskEvent(was, state)
  local now = type(state) == "table" and state.state or nil
  if type(now) ~= "string" or now == was or not core.TASK_ENDS[now] then return nil end
  return now
end

-- What she says back, from state.json: her last message (the timeline's last text), else her result.
function core.taskReport(state, lastText)
  if type(lastText) == "string" and lastText:match("%S") then return lastText:match("^%s*(.-)%s*$") end
  local out = type(state) == "table" and type(state.output) == "table" and state.output.result
  if type(out) == "string" and out:match("%S") then return out end
  return type(state) == "table" and type(state.detail) == "string" and state.detail or ""
end


-- Text grandma marked for skimming, "**key words**", as runs { { text, hi } } plus the text with
-- the marks taken out (what gets copied). A "**" with no partner stays as it is.
function core.highlightRuns(text)
  text = tostring(text or "")
  local marks, from = {}, 1
  while true do
    local a = text:find("**", from, true)
    if not a then break end
    table.insert(marks, a)
    from = a + 2
  end
  if #marks % 2 == 1 then table.remove(marks) end
  local runs, pos = {}, 1
  for i = 1, #marks, 2 do
    local a, b = marks[i], marks[i + 1]
    if a > pos then table.insert(runs, { text = text:sub(pos, a - 1), hi = false }) end
    if b > a + 2 then table.insert(runs, { text = text:sub(a + 2, b - 1), hi = true }) end
    pos = b + 2
  end
  if pos <= #text then table.insert(runs, { text = text:sub(pos), hi = false }) end
  local plain = {}
  for _, r in ipairs(runs) do table.insert(plain, r.text) end
  return runs, table.concat(plain)
end

-- `text` with grandma's "**" marks taken out.
function core.unmark(text) return select(2, core.highlightRuns(text)) end

-- The panel's one-line gist after a fill or a page edit: what was done, and what was left.
function core.fillGist(fields, status)
  local done, left = 0, 0
  for _, f in ipairs(fields or {}) do
    if f.skip then left = left + 1 else done = done + 1 end
  end
  local verb = status == "work" and "Changed" or "Filled"
  local noun = status == "work" and "part" or "field"
  local out = string.format("%s %d %s%s", verb, done, noun, done == 1 and "" or "s")
  if left > 0 then out = out .. string.format(", %d left empty", left) end
  return out .. ". Check it, then save."
end

return core
