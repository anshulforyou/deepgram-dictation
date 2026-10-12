local core = require("deepgram_dictation.core")

describe("mergeConfig", function()
  it("returns defaults when called without overrides", function()
    local cfg = core.mergeConfig()
    assert.are.equal("fn", cfg.hotkey)
    assert.are.equal("nova-3", cfg.model)
    assert.are.equal("en", cfg.language)
  end)

  it("applies overrides without mutating DEFAULTS", function()
    local cfg = core.mergeConfig({ language = "multi", hotkey = "rightOption" })
    assert.are.equal("multi", cfg.language)
    assert.are.equal("rightOption", cfg.hotkey)
    assert.are.equal("en", core.DEFAULTS.language)
  end)

  it("accepts optional path options", function()
    local cfg = core.mergeConfig({ recBinary = "/x/rec", dictionary = "/x/dict.json" })
    assert.are.equal("/x/rec", cfg.recBinary)
    assert.are.equal("/x/dict.json", cfg.dictionary)
  end)

  it("rejects unknown options", function()
    assert.has_error(function() core.mergeConfig({ langauge = "en" }) end,
      "deepgram-dictation: unknown config option 'langauge'")
  end)

  it("rejects unsupported hotkeys", function()
    assert.has_error(function() core.mergeConfig({ hotkey = "capsLock" }) end)
  end)

  it("validates cleanup options", function()
    local cfg = core.mergeConfig({ cleanup = true, keepDictations = 200 })
    assert.is_true(cfg.cleanup)
    assert.are.equal("claude-haiku-5-5", cfg.cleanupModel)
    assert.are.equal(200, cfg.keepDictations)
    assert.has_error(function() core.mergeConfig({ cleanupTimeout = 0 }) end)
    assert.has_error(function() core.mergeConfig({ keepDictations = -1 }) end)
    assert.has_error(function() core.mergeConfig({ keepDictations = 2.5 }) end)
    assert.has_error(function() core.mergeConfig({ keytermNames = "50" }) end)
  end)

  it("rejects invalid language, model and minSeconds", function()
    assert.has_error(function() core.mergeConfig({ language = "" }) end)
    assert.has_error(function() core.mergeConfig({ model = 3 }) end)
    assert.has_error(function() core.mergeConfig({ minSeconds = -1 }) end)
    assert.has_error(function() core.mergeConfig({ tailSeconds = "0.5" }) end)
  end)
end)

describe("findExecutable", function()
  it("returns the first existing candidate", function()
    local exists = function(p) return p == "/usr/local/bin/rec" end
    assert.are.equal("/usr/local/bin/rec", core.findExecutable(exists, core.REC_CANDIDATES))
  end)

  it("prefers earlier candidates", function()
    assert.are.equal("/opt/homebrew/bin/rec", core.findExecutable(function() return true end, core.REC_CANDIDATES))
  end)

  it("returns nil when nothing exists", function()
    assert.is_nil(core.findExecutable(function() return false end, core.REC_CANDIDATES))
  end)
end)

describe("urlEncode", function()
  it("leaves unreserved characters alone", function()
    assert.are.equal("abc-1.2_~", core.urlEncode("abc-1.2_~"))
  end)

  it("percent-encodes spaces, symbols and UTF-8", function()
    assert.are.equal("a%20b%26c%40d", core.urlEncode("a b&c@d"))
    assert.are.equal("caf%C3%A9", core.urlEncode("café"))
  end)
end)

describe("buildListenUrl", function()
  it("includes model, language and formatting flags", function()
    local url = core.buildListenUrl(core.mergeConfig(), {})
    assert.are.equal(
      "https://api.deepgram.com/v1/listen?model=nova-3&language=en&punctuate=true&smart_format=true", url)
  end)

  it("omits smart_format when disabled", function()
    local url = core.buildListenUrl(core.mergeConfig({ smartFormat = false }), {})
    assert.is_nil(url:find("smart_format", 1, true))
  end)

  it("adds one encoded keyterm parameter per term", function()
    local url = core.buildListenUrl(core.mergeConfig(), { "Hammerspoon", "Jane Doe" })
    local suffix = "&keyterm=Hammerspoon&keyterm=Jane%20Doe"
    assert.are.equal(suffix, url:sub(-#suffix))
  end)
end)

describe("buildStreamUrl", function()
  it("uses the websocket endpoint with raw PCM parameters and keyterms", function()
    local url = core.buildStreamUrl(core.mergeConfig(), { "Jane Doe" })
    assert.are.equal("wss://api.deepgram.com/v1/listen?model=nova-3&language=en&punctuate=true&smart_format=true"
      .. "&encoding=linear16&sample_rate=16000&channels=1&keyterm=Jane%20Doe", url)
  end)

  it("can be turned off", function()
    assert.is_false(core.mergeConfig({ streaming = false }).streaming)
  end)
end)

describe("normalizeDictionary", function()
  it("returns empty lists for non-table input", function()
    assert.are.same({ keyterms = {}, names = {}, replacements = {} }, core.normalizeDictionary(nil))
    assert.are.same({ keyterms = {}, names = {}, replacements = {} }, core.normalizeDictionary("oops"))
  end)

  it("drops malformed entries", function()
    local dict = core.normalizeDictionary({
      keyterms = { "Good", "", "   ", 42 },
      names = { "Priya", 7, "" },
      replacements = { { from = "btw", to = "by the way" }, { from = "" , to = "x" }, { from = "a" }, "bad" },
    })
    assert.are.same({ "Good" }, dict.keyterms)
    assert.are.same({ "Priya" }, dict.names)
    assert.are.same({ { from = "btw", to = "by the way" } }, dict.replacements)
  end)

  it("sorts replacements longest-first", function()
    local dict = core.normalizeDictionary({ replacements = {
      { from = "my email", to = "A" }, { from = "my email address", to = "B" },
    } })
    assert.are.equal("my email address", dict.replacements[1].from)
  end)
end)

describe("applyReplacements", function()
  local function apply(text, replacements)
    return core.applyReplacements(text, core.normalizeDictionary({ replacements = replacements }).replacements)
  end

  it("replaces whole words case-insensitively", function()
    assert.are.equal("by the way, ok by the way",
      apply("BTW, ok btw", { { from = "btw", to = "by the way" } }))
  end)

  it("does not replace inside other words", function()
    assert.are.equal("debtwise", apply("debtwise", { { from = "btw", to = "by the way" } }))
  end)

  it("matches multi-word phrases and prefers the longest", function()
    local out = apply("Send it to my email address.", {
      { from = "my email", to = "WRONG" },
      { from = "my email address", to = "me@example.com" },
    })
    assert.are.equal("Send it to me@example.com.", out)
  end)

  it("treats magic characters in the phrase and replacement literally", function()
    assert.are.equal("cost: 100%", apply("cost: (pct)", { { from = "(pct)", to = "100%" } }))
    assert.are.equal("a.b", apply("a.b", { { from = "a%b", to = "x" } }))
  end)

  it("returns text unchanged with no replacements", function()
    assert.are.equal("hello", core.applyReplacements("hello", nil))
  end)
end)

describe("extractTranscript", function()
  it("returns the first alternative's transcript", function()
    local resp = { results = { channels = { { alternatives = { { transcript = "hello world" } } } } } }
    assert.are.equal("hello world", core.extractTranscript(resp))
  end)

  it("returns an empty string for silence", function()
    local resp = { results = { channels = { { alternatives = { { transcript = "" } } } } } }
    assert.are.equal("", core.extractTranscript(resp))
  end)

  it("returns nil and an error for unexpected shapes", function()
    for _, resp in ipairs({ {}, { results = {} }, { results = { channels = {} } } }) do
      local text, err = core.extractTranscript(resp)
      assert.is_nil(text)
      assert.are.equal("unexpected response shape", err)
    end
    assert.is_nil(core.extractTranscript(nil))
  end)
end)

describe("shouldTranscribe", function()
  it("requires the minimum duration", function()
    assert.is_false(core.shouldTranscribe(0.1, false, 0.3))
    assert.is_true(core.shouldTranscribe(0.3, false, 0.3))
  end)

  it("never transcribes cancelled recordings", function()
    assert.is_false(core.shouldTranscribe(5, true, 0.3))
  end)
end)

describe("hotkeyTransition", function()
  it("detects press and release of Fn", function()
    assert.are.equal("press", core.hotkeyTransition("fn", 63, { fn = true }, false))
    assert.are.equal("release", core.hotkeyTransition("fn", 63, {}, true))
  end)

  it("ignores other keys", function()
    assert.is_nil(core.hotkeyTransition("fn", 58, { alt = true }, false))
    assert.is_nil(core.hotkeyTransition("fn", 58, { alt = true }, true))
  end)

  it("releases on the hotkey's own key even if the flag is still set", function()
    -- Right Option released while left Option is still held.
    assert.are.equal("release", core.hotkeyTransition("rightOption", 61, { alt = true }, true))
  end)

  it("ignores a stray flag-less event while idle", function()
    assert.is_nil(core.hotkeyTransition("fn", 63, {}, false))
  end)
end)

describe("meeting config", function()
  it("has meeting defaults", function()
    local cfg = core.mergeConfig()
    assert.are.equal("inPerson", cfg.meetingMode)
    assert.is_true(cfg.detectMeetings)
    assert.is_false(cfg.organizeWithClaude)
    assert.are.equal("d", cfg.menuHotkey.key)
    assert.are.same({ "ctrl", "alt", "cmd" }, cfg.meetingHotkey.mods)
    assert.is_false(cfg.keepMeetingAudio)
  end)

  it("accepts inPerson mode, a custom hotkey, or no hotkey", function()
    assert.are.equal("inPerson", core.mergeConfig({ meetingMode = "inPerson" }).meetingMode)
    assert.are.equal("t", core.mergeConfig({ meetingHotkey = { mods = { "cmd" }, key = "t" } }).meetingHotkey.key)
    assert.is_false(core.mergeConfig({ meetingHotkey = false }).meetingHotkey)
  end)

  it("accepts optional meeting paths", function()
    local cfg = core.mergeConfig({
      transcriptsDir = "/t", recorderApp = "/r.app", python = "/p", meetingLanguage = "hi",
    })
    assert.are.equal("/t", cfg.transcriptsDir)
    assert.are.equal("hi", cfg.meetingLanguage)
  end)

  it("rejects invalid meeting options", function()
    assert.has_error(function() core.mergeConfig({ meetingMode = "zoom" }) end)
    assert.has_error(function() core.mergeConfig({ meetingHotkey = "cmd+m" }) end)
    assert.has_error(function() core.mergeConfig({ meetingHotkey = { mods = { "cmd" } } }) end)
    assert.has_error(function() core.mergeConfig({ menuHotkey = true }) end)
    assert.is_false(core.mergeConfig({ menuHotkey = false }).menuHotkey)
  end)
end)

describe("formatElapsed", function()
  it("formats minutes and hours", function()
    assert.are.equal("0:00", core.formatElapsed(0))
    assert.are.equal("4:05", core.formatElapsed(245.9))
    assert.are.equal("1:02:03", core.formatElapsed(3723))
  end)

  it("clamps negatives to zero", function()
    assert.are.equal("0:00", core.formatElapsed(-3))
  end)
end)

describe("sessionName", function()
  it("is sortable and filesystem-safe", function()
    local name = core.sessionName({ year = 2026, month = 10, day = 9, hour = 7, min = 5, sec = 3 })
    assert.are.equal("2026-10-09_07-05-03", name)
  end)
end)

describe("transcribeArgs", function()
  it("passes model, language and keychain name", function()
    local args = core.transcribeArgs(core.mergeConfig(), "s.py", "/sess", "/out", nil)
    assert.are.same({ "s.py", "/sess", "--output-dir", "/out", "--model", "nova-3",
                      "--language", "en", "--keychain-name", "deepgram-api-key" }, args)
  end)

  it("adds Claude organizing flags only when a claude path is given", function()
    local cfg = core.mergeConfig({ claudeModel = "opus" })
    local args = core.transcribeArgs(cfg, "s.py", "/sess", "/out", nil, "/bin/claude")
    assert.are.same({ "--organize-with-claude", "/bin/claude", "--claude-model", "opus" },
      { args[11], args[12], args[13], args[14] })
    assert.are.equal(10, #core.transcribeArgs(cfg, "s.py", "/sess", "/out", nil, nil))
  end)

  it("files into grandma only when organizing with Claude", function()
    local cfg = core.mergeConfig({ grandmaHome = "~/.grandma" })
    local args = core.transcribeArgs(cfg, "s.py", "/sess", "/out", nil, "/bin/claude")
    assert.are.same({ "--grandma-home", "~/.grandma" }, { args[13], args[14] })
    assert.are.equal(10, #core.transcribeArgs(cfg, "s.py", "/sess", "/out", nil, nil))
  end)

  it("prefers meetingLanguage and adds dictionary and keep-audio flags", function()
    local cfg = core.mergeConfig({ language = "en", meetingLanguage = "multi", keepMeetingAudio = true })
    local args = core.transcribeArgs(cfg, "s.py", "/sess", "/out", "/d.json")
    assert.are.equal("multi", args[8])
    assert.are.same({ "--dictionary", "/d.json", "--keep-audio" }, { args[11], args[12], args[13] })
  end)
end)

describe("parseResultLine", function()
  local function decode(s)
    if s == '{"path":"/x.md"}' then return { path = "/x.md" } end
    if s == '{"error":"boom"}' then return { error = "boom" } end
    if s == "{}" then return {} end
    error("bad json")
  end

  it("returns the decoded last non-empty line", function()
    local result = core.parseResultLine('log line\n{"path":"/x.md"}\n\n', decode)
    assert.are.equal("/x.md", result.path)
  end)

  it("surfaces transcriber errors", function()
    local result, err = core.parseResultLine('{"error":"boom"}', decode)
    assert.is_nil(result)
    assert.are.equal("boom", err)
  end)

  it("handles empty, malformed and incomplete output", function()
    assert.are.equal("transcriber produced no output", select(2, core.parseResultLine("", decode)))
    assert.are.equal("could not parse transcriber output", select(2, core.parseResultLine("nope", decode)))
    assert.are.equal("transcriber did not return a file path", select(2, core.parseResultLine("{}", decode)))
  end)
end)

describe("classifyMicUser", function()
  it("recognises meeting apps", function()
    assert.are.same({ kind = "app", key = "us.zoom.xos", name = "Zoom" }, core.classifyMicUser("us.zoom.xos"))
  end)

  it("recognises browsers and their helper processes", function()
    for _, id in ipairs({ "com.brave.Browser", "com.brave.Browser.helper", "com.brave.Browser.helper.Renderer" }) do
      local c = core.classifyMicUser(id)
      assert.are.equal("browser", c.kind)
      assert.are.equal("com.brave.Browser", c.key)
    end
    assert.are.equal("com.apple.Safari", core.classifyMicUser("com.apple.WebKit.GPU").key)
  end)

  it("does not match lookalike prefixes or unrelated processes", function()
    assert.is_nil(core.classifyMicUser("com.brave.BrowserBeta"))
    assert.is_nil(core.classifyMicUser("com.apple.CoreSpeech"))
    assert.is_nil(core.classifyMicUser("io.github.anshulforyou.deepgram-recorder"))
    assert.is_nil(core.classifyMicUser(nil))
  end)
end)

describe("meetingFromUrls", function()
  it("finds Google Meet calls but not the Meet home page", function()
    local urls = { "https://mail.google.com/", "https://meet.google.com/abc-defg-hij?authuser=0" }
    assert.are.equal("Google Meet", core.meetingFromUrls(urls))
    assert.is_nil(core.meetingFromUrls({ "https://meet.google.com/landing" }))
  end)

  it("finds other services, case-insensitively", function()
    assert.are.equal("Zoom", core.meetingFromUrls({ "https://us02web.zoom.us/wc/123/join" }))
    assert.are.equal("Microsoft Teams", core.meetingFromUrls({ "https://teams.microsoft.com/v2/" }))
    assert.are.equal("Slack huddle", core.meetingFromUrls({ "HTTPS://APP.SLACK.COM/huddle/T1/C2" }))
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(core.meetingFromUrls({ "https://example.com/meet.google.com/abc-defg-hij" }))
    assert.is_nil(core.meetingFromUrls(nil))
  end)
end)

describe("meetingFromTitles", function()
  it("matches meeting window titles", function()
    assert.are.equal("Google Meet", core.meetingFromTitles({ "Inbox", "Meet - abc-defg-hij" }))
    assert.are.equal("Zoom", core.meetingFromTitles({ "Zoom Meeting" }))
    assert.is_nil(core.meetingFromTitles({ "Meeting notes - Notion" }))
  end)
end)

describe("flattenUrls", function()
  it("flattens nested AppleScript lists and skips non-strings", function()
    assert.are.same({ "a", "b", "c" }, core.flattenUrls({ { "a", "b" }, { "c", 42 } }))
    assert.are.same({}, core.flattenUrls(nil))
  end)
end)

describe("newEndTracker", function()
  it("fires only after the meeting has been gone for the grace period", function()
    local ended = core.newEndTracker(30)
    assert.is_false(ended(true, 0))
    assert.is_false(ended(false, 10))
    assert.is_false(ended(false, 39))
    assert.is_true(ended(false, 40))
  end)

  it("resets when the meeting reappears", function()
    local ended = core.newEndTracker(30)
    ended(false, 0)
    ended(true, 20)
    assert.is_false(ended(false, 45))
    assert.is_true(ended(false, 75))
  end)
end)

describe("wavPeak", function()
  local function wav(samples)
    local body = {}
    for _, v in ipairs(samples) do table.insert(body, string.pack("<i2", v)) end
    return "RIFF" .. string.rep("\0", 40) .. table.concat(body)
  end

  it("returns the loudest sample as a fraction of full scale", function()
    assert.are.equal(0.5, core.wavPeak(wav({ 100, -16384, 2000 })))
    assert.are.equal(0, core.wavPeak(wav({ 0, 0 })))
  end)

  it("rejects non-WAV input", function()
    assert.is_nil(core.wavPeak("nope"))
    assert.is_nil(core.wavPeak(nil))
  end)
end)

describe("noSpeechHint", function()
  it("mentions a low input volume when the recording was quiet", function()
    assert.are.equal("Mic level very low (AirPods Pro, input volume 27%). Check System Settings → Sound → Input.",
      core.noSpeechHint("AirPods Pro", 27.45, 0.0136))
  end)

  it("omits the volume when it is reasonable", function()
    assert.are.equal("Mic level very low (MacBook Pro Microphone). Check System Settings → Sound → Input.",
      core.noSpeechHint("MacBook Pro Microphone", 80, 0.01))
  end)

  it("says so when the mic delivered pure digital silence", function()
    assert.are.equal("AirPods Pro delivered no sound at all. Another app may be blocking it.",
      core.noSpeechHint("AirPods Pro", 80, 0))
  end)

  it("gives no hint when the mic level was fine or unknown", function()
    assert.is_nil(core.noSpeechHint("AirPods Pro", 27, 0.4))
    assert.is_nil(core.noSpeechHint("AirPods Pro", 27, nil))
  end)
end)

describe("parseStreamOutput", function()
  local function decode(line)
    local map = {
      ['{"event":"listening"}'] = { event = "listening" },
      ['{"transcript":"hi"}'] = { transcript = "hi" },
      ['{"error":"offline"}'] = { error = "offline" },
    }
    if map[line] == nil then error("bad json") end
    return map[line]
  end

  it("skips progress events and returns the final result", function()
    local out = '{"event":"listening"}\n{"transcript":"hi"}\n'
    assert.are.same({ transcript = "hi" }, core.parseStreamOutput(out, decode))
  end)

  it("handles errors, junk and empty output", function()
    assert.are.same({ error = "offline" }, core.parseStreamOutput('junk\n{"error":"offline"}', decode))
    assert.is_nil(core.parseStreamOutput('{"event":"listening"}\n', decode))
    assert.is_nil(core.parseStreamOutput(nil, decode))
  end)

  describe("activeSeconds", function()
    it("is the elapsed time without pauses", function()
      assert.are.equal(60, core.activeSeconds(100, 160))
      assert.are.equal(50, core.activeSeconds(100, 160, 10))
    end)

    it("excludes a pause in progress", function()
      assert.are.equal(30, core.activeSeconds(100, 160, 10, 140))
    end)

    it("is never negative", function()
      assert.are.equal(0, core.activeSeconds(100, 90))
      assert.are.equal(0, core.activeSeconds(100, 160, 100))
    end)
  end)

  describe("indicatorText", function()
    it("shows the meeting and time while recording", function()
      assert.same({ "Transcribing", "Google Meet · 1:05" },
        { core.indicatorText("recording", false, 65, "Google Meet") })
      assert.same({ "Transcribing", "0:09" }, { core.indicatorText("recording", false, 9) })
    end)

    it("says when paused", function()
      assert.are.equal("Paused", (core.indicatorText("recording", true, 65)))
    end)

    it("covers the other states", function()
      assert.are.equal("Starting…", (core.indicatorText("starting", false, 0)))
      assert.are.equal("Saving transcript…", (core.indicatorText("transcribing", false, 0)))
      assert.are.equal("Saving transcript…", (core.indicatorText("stopping", false, 0)))
      assert.is_nil(core.indicatorText("idle", false, 0))
    end)
  end)
end)

describe("mergeNames", function()
  it("puts dictionary names first and drops case-insensitive duplicates", function()
    local names = core.mergeNames({ names = { "Priya", " sam " } },
      { names = { "Sam", "Alex", "priya", "Slack" } }, 10)
    assert.are.same({ "Priya", "sam", "Alex", "Slack" }, names)
  end)

  it("builds keyterms from dictionary keyterms and names plus the top extracted keyterms", function()
    local _, keyterms = core.mergeNames({ keyterms = { "Deepgram" }, names = { "Priya" } },
      { names = { "Alex", "Sam", "Jordan", "Slack" }, keyterms = { "Alex", "Sam", "Jordan" } }, 2)
    assert.are.same({ "Deepgram", "Priya", "Alex", "Sam" }, keyterms)
  end)

  it("never adds a keyterm twice", function()
    local _, keyterms = core.mergeNames({ keyterms = { "Priya" }, names = { "priya" } },
      { keyterms = { "PRIYA", "Sam" } }, 5)
    assert.are.same({ "Priya", "Sam" }, keyterms)
  end)

  it("works without extracted names", function()
    local names, keyterms = core.mergeNames({ keyterms = { "X" } }, nil, 50)
    assert.are.same({}, names)
    assert.are.same({ "X" }, keyterms)
  end)
end)

describe("cleanupSystemPrompt", function()
  it("appends the names list", function()
    assert.are.equal("Do it.\n\nNames list:\nPriya, Sam\n",
      core.cleanupSystemPrompt("Do it.\n\n", { "Priya", "Sam" }))
  end)

  it("leaves the instructions alone without names", function()
    assert.are.equal("Do it.", core.cleanupSystemPrompt("Do it.", {}))
  end)
end)

describe("cleanupRequest", function()
  it("wraps the transcript, caches the system prompt and turns thinking off", function()
    local body = core.cleanupRequest(core.mergeConfig({ cleanup = true }), "SYS", "go life")
    assert.are.equal("claude-haiku-5-5", body.model)
    assert.are.same({ type = "disabled" }, body.thinking)
    assert.are.equal("low", body.output_config.effort)
    assert.are.equal("SYS", body.system[1].text)
    assert.are.same({ type = "ephemeral" }, body.system[1].cache_control)
    assert.are.equal("<transcript>go life</transcript>", body.messages[1].content)
    assert.is_true(body.max_tokens >= 64)
  end)

  it("gives long dictations enough output room", function()
    local text = string.rep("word ", 400)
    assert.is_true(core.cleanupRequest(core.mergeConfig(), "S", text).max_tokens > #text / 4)
  end)
end)

describe("parseCleanup", function()
  local function resp(text, stop)
    return { type = "message", stop_reason = stop or "end_turn", content = { { type = "text", text = text } } }
  end
  local raw = "So I I was going to, I think we should go life with the the app on Tuesday, no, Wednesday."

  it("returns the cleaned text, trimmed", function()
    assert.are.equal("I think we should go live with the app on Wednesday.",
      core.parseCleanup(resp("  I think we should go live with the app on Wednesday.\n"), raw))
  end)

  it("strips transcript tags echoed back", function()
    assert.are.equal("go live", core.parseCleanup(resp("<transcript>go live</transcript>"), "go life"))
  end)

  it("rejects an answer that grew (Claude replied instead of cleaning)", function()
    local text, why = core.parseCleanup(resp("The capital of France is Paris, a city on the Seine."),
      "what is the capital of France")
    assert.is_nil(text)
    assert.matches("grew", why)
  end)

  it("rejects an answer that shrank drastically", function()
    local text, why = core.parseCleanup(resp("Ship Wednesday."), raw)
    assert.is_nil(text)
    assert.matches("shrank", why)
  end)

  it("rejects an answer that removed or softened swearing", function()
    local said = "First of all, why the fuck are we showing the run button on this screen?"
    local text, why = core.parseCleanup(resp("First of all, why are we showing the run button on this screen?"), said)
    assert.is_nil(text)
    assert.are.equal("removed swearing", why)
    assert.are.equal(said, core.parseCleanup(resp(said), said))
  end)

  it("rejects a same-length answer made of words never said", function()
    local said = "what is the best way to structure a service in Go"
    local text, why = core.parseCleanup(resp("Use small packages, clear interfaces and one main entry point."), said)
    assert.is_nil(text)
    assert.matches("never said", why)
  end)

  it("allows a few fixed words", function()
    assert.are.equal("we go live on Monday", core.parseCleanup(resp("we go live on Monday"), "we go life on Monday"))
    assert.are.equal("go live", core.parseCleanup(resp("go live"), "go life"))
  end)

  it("counts swear words as whole words", function()
    assert.are.equal(3, core.swearCount("What the Fuck, this is bullshit. Hell."))
    assert.are.equal(0, core.swearCount("Hello shell, the class passed and Shelly assessed it."))
  end)

  it("allows big relative cuts on short dictations", function()
    assert.are.equal("the app", core.parseCleanup(resp("the app"), "the the the app"))
  end)

  it("rejects truncated, empty and error responses", function()
    assert.is_nil(core.parseCleanup(resp("I think", "max_tokens"), raw))
    assert.is_nil(core.parseCleanup(resp("   "), raw))
    local text, why = core.parseCleanup({ type = "error", error = { message = "overloaded" } }, raw)
    assert.is_nil(text)
    assert.matches("overloaded", why)
    assert.is_nil(core.parseCleanup(nil, raw))
  end)
end)

describe("dictationsToPrune", function()
  it("returns the oldest stems beyond the limit", function()
    local stems = { "2026-10-11_10-00-02-000", "2026-10-11_10-00-00-500", "2026-10-11_10-00-01-000" }
    assert.are.same({ "2026-10-11_10-00-00-500" }, core.dictationsToPrune(stems, 2))
  end)

  it("returns nothing when under the limit", function()
    assert.are.same({}, core.dictationsToPrune({ "a", "b" }, 200))
  end)
end)
