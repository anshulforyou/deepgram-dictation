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
}

core.OPTIONS = {
  recBinary = true, dictionary = true, meetingLanguage = true, transcriptsDir = true,
  recorderApp = true, python = true, claudePath = true, claudeModel = true, grandmaHome = true,
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

-- Whether a flagsChanged event while the hotkey is held asks about the screen. Control can go
-- down before or after the hotkey, and the dictation stays a screen question once it has.
function core.wantsScreen(cfg, flags)
  return cfg.screenAssist == true and flags[core.SCREEN_FLAG] == true
end

-- What grandma returns for a screen question: text to paste where the user is typing, or an
-- answer to show them.
core.SCREEN_SCHEMA = {
  type = "object",
  properties = {
    kind = { type = "string", enum = { "insert", "answer" } },
    text = { type = "string" },
  },
  required = { "kind", "text" },
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
    table.insert(content, { type = "tool_result", tool_use_id = r.id, content = r.text, is_error = r.isError or nil })
  end
  table.insert(body.messages, { role = "assistant", content = resp.content })
  table.insert(body.messages, { role = "user", content = content })
  return body
end

-- { kind, text } from a decoded Messages API response, or nil plus what went wrong. A reply
-- that isn't the expected JSON is still shown, as an answer, rather than thrown away.
function core.parseScreenAnswer(resp, decode)
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
  if ok and type(value) == "table" and (value.kind == "insert" or value.kind == "answer")
      and type(value.text) == "string" and value.text:match("%S") then
    return { kind = value.kind, text = value.text:match("^%s*(.-)%s*$") }
  end
  return { kind = "answer", text = raw }
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

return core
