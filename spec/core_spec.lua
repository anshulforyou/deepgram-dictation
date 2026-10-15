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

describe("screen questions", function()
  local cfg = core.mergeConfig({ screenAssist = true })

  it("is off by default and uses Sonnet with a low effort", function()
    local defaults = core.mergeConfig()
    assert.is_false(defaults.screenAssist)
    assert.are.equal("claude-sonnet-5-5", defaults.screenModel)
    assert.are.equal("low", defaults.screenEffort)
  end)

  it("validates its options", function()
    assert.has_error(function() core.mergeConfig({ screenTimeout = 0 }) end)
    assert.has_error(function() core.mergeConfig({ screenEffort = "max" }) end)
  end)

  it("can't use Control with a Control hotkey", function()
    assert.has_error(function() core.mergeConfig({ screenAssist = true, hotkey = "rightControl" }) end)
    assert.has_no.errors(function() core.mergeConfig({ hotkey = "rightControl" }) end)
  end)

  describe("wantsScreen", function()
    it("is a screen question when Control is down with the hotkey, pressed first or second", function()
      assert.is_true(core.wantsScreen(cfg, { fn = true, ctrl = true }))
    end)

    it("is plain dictation without Control", function()
      assert.is_false(core.wantsScreen(cfg, { fn = true }))
      assert.is_false(core.wantsScreen(cfg, { fn = true, alt = true }))
    end)

    it("is never a screen question when screenAssist is off", function()
      assert.is_false(core.wantsScreen(core.mergeConfig(), { fn = true, ctrl = true }))
    end)
  end)

  describe("screenRequest", function()
    local body = core.screenRequest(cfg, "SYSTEM", "where do I click?", "BASE64", "image/jpeg")

    it("sends the screenshot before the question", function()
      local content = body.messages[1].content
      assert.are.same({ type = "base64", media_type = "image/jpeg", data = "BASE64" }, content[1].source)
      assert.are.equal("<question>where do I click?</question>", content[2].text)
    end)

    it("asks for the answer in a fixed shape", function()
      assert.are.equal("json_schema", body.output_config.format.type)
      assert.are.same({ "insert", "answer", "fill" }, body.output_config.format.schema.properties.kind.enum)
      assert.are.equal("low", body.output_config.effort)
    end)

    it("uses adaptive thinking, which Sonnet 5.5 can't turn off, and caches the prompt", function()
      assert.are.equal("adaptive", body.thinking.type)
      assert.are.equal("claude-sonnet-5-5", body.model)
      assert.are.equal("ephemeral", body.system[1].cache_control.type)
    end)
  end)

  describe("screenRequest with grandma memory", function()
    local memory = {
      profile = "PROFILE", catalog = "- acme: shoes", openable = { "acme", "spring-launch" },
      memory = { { name = "acme", kind = "sweater", text = "ACME FACTS" } },
    }
    local body = core.screenRequest(cfg, "SYSTEM", "q", "IMG", "image/jpeg", memory)

    it("puts the profile and catalog after the instructions, cached", function()
      assert.are.equal("SYSTEM", body.system[1].text)
      assert.is_nil(body.system[1].cache_control)
      assert.truthy(body.system[2].text:find("<profile>\nPROFILE\n</profile>", 1, true))
      assert.truthy(body.system[2].text:find("<memory_catalog>\n- acme: shoes\n</memory_catalog>", 1, true))
      assert.are.equal("ephemeral", body.system[2].cache_control.type)
    end)

    it("sends named memory before the screenshot and caches up to it", function()
      local content = body.messages[1].content
      assert.are.equal('<memory name="acme" kind="sweater">\nACME FACTS\n</memory>', content[1].text)
      assert.are.equal("ephemeral", content[1].cache_control.type)
      assert.are.equal("image", content[2].type)
      assert.are.equal("<question>q</question>", content[3].text)
    end)

    it("offers open_memory for everything in the catalog", function()
      assert.are.equal("open_memory", body.tools[1].name)
      assert.are.same({ "acme", "spring-launch" }, body.tools[1].input_schema.properties.name.enum)
    end)

    it("leaves out what grandma doesn't have", function()
      local bare = core.screenRequest(cfg, "SYSTEM", "q", "IMG", "image/jpeg",
        { profile = "", catalog = "", openable = {}, memory = {} })
      assert.are.equal(1, #bare.system)
      assert.are.equal("ephemeral", bare.system[1].cache_control.type)
      assert.is_nil(bare.tools)
      assert.are.equal("image", bare.messages[1].content[1].type)
    end)
  end)

  describe("memoryRequests and continueWithResults", function()
    local resp = { stop_reason = "tool_use", content = {
      { type = "thinking", thinking = "", signature = "SIG" },
      { type = "tool_use", id = "t1", name = "open_memory", input = { name = "acme" } },
    } }

    it("lists the memory Claude asked to open", function()
      assert.are.same({ { id = "t1", name = "acme", tool = "open_memory" } }, core.memoryRequests(resp))
      assert.are.same({}, core.memoryRequests({ stop_reason = "end_turn", content = resp.content }))
      assert.are.same({}, core.memoryRequests(nil))
    end)

    it("sends Claude's turn back unchanged, then the results", function()
      local body = { messages = { { role = "user", content = {} } } }
      core.continueWithResults(body, resp, { { id = "t1", text = "ACME" }, { id = "t2", text = "no", isError = true } })
      assert.are.equal(resp.content, body.messages[2].content)
      assert.are.same({ type = "tool_result", tool_use_id = "t1", content = "ACME" }, body.messages[3].content[1])
      assert.is_true(body.messages[3].content[2].is_error)
    end)
  end)

  describe("parseScreenAnswer", function()
    local decoded = {
      ['{"kind":"insert","text":"  Hi Priya, Thursday works.  "}'] =
        { kind = "insert", text = "  Hi Priya, Thursday works.  " },
      ['{"kind":"answer","text":"Billing, in the left sidebar."}'] =
        { kind = "answer", text = "Billing, in the left sidebar." },
      ['{"kind":"shout","text":"x"}'] = { kind = "shout", text = "x" },
      ['{"kind":"answer","text":" "}'] = { kind = "answer", text = " " },
    }
    local function decode(s)
      if decoded[s] then return decoded[s] end
      error("not json")
    end
    local function reply(text, stop)
      return { stop_reason = stop or "end_turn",
               content = { { type = "thinking", thinking = "" }, { type = "text", text = text } } }
    end

    it("reads text to insert, trimmed, skipping thinking blocks", function()
      assert.are.same({ kind = "insert", text = "Hi Priya, Thursday works." },
        core.parseScreenAnswer(reply('{"kind":"insert","text":"  Hi Priya, Thursday works.  "}'), decode))
    end)

    it("reads an answer", function()
      assert.are.same({ kind = "answer", text = "Billing, in the left sidebar." },
        core.parseScreenAnswer(reply('{"kind":"answer","text":"Billing, in the left sidebar."}'), decode))
    end)

    it("shows anything that isn't the expected JSON as an answer rather than losing it", function()
      assert.are.same({ kind = "answer", text = "Click Billing." },
        core.parseScreenAnswer(reply("Click Billing."), decode))
      assert.are.equal("answer", core.parseScreenAnswer(reply('{"kind":"shout","text":"x"}'), decode).kind)
      assert.are.equal("answer", core.parseScreenAnswer(reply('{"kind":"answer","text":" "}'), decode).kind)
    end)

    it("reports refusals, cut-off answers, errors and empty replies", function()
      assert.are.equal("Claude declined to answer", select(2, core.parseScreenAnswer(reply("", "refusal"), decode)))
      assert.are.equal("stopped: max_tokens", select(2, core.parseScreenAnswer(reply("{", "max_tokens"), decode)))
      assert.are.equal("api error: overloaded",
        select(2, core.parseScreenAnswer({ type = "error", error = { message = "overloaded" } }, decode)))
      assert.are.equal("empty answer", select(2, core.parseScreenAnswer(reply("  "), decode)))
      assert.are.equal("unexpected response", select(2, core.parseScreenAnswer(nil, decode)))
    end)
  end)

  describe("panelOrigin", function()
    local frame = { x = 0, y = 25, w = 1920, h = 1055 }

    it("opens below and right of the mouse", function()
      assert.are.same({ x = 116, y = 216 }, core.panelOrigin({ x = 100, y = 200 }, 440, 200, frame))
    end)

    it("flips left at the right edge and stays above the bottom", function()
      assert.are.same({ x = 1404, y = 864 }, core.panelOrigin({ x = 1860, y = 1050 }, 440, 200, frame))
    end)

    it("stays inside the screen on a second display", function()
      local right = { x = 1920, y = 0, w = 1440, h = 900 }
      assert.are.same({ x = 1936, y = 16 }, core.panelOrigin({ x = 1900, y = -40 }, 440, 200, right))
    end)
  end)
end)

describe("filling a form", function()
  local fields = {
    { label = "Title", value = "Nowhere Suit", skip = false },
    { label = "Price", value = "", skip = true },
  }

  describe("parseScreenAnswer with a fill plan", function()
    local plan = '{"kind":"fill","text":"2 fields","fields":[...]}'
    local function decode(s)
      if s == plan then
        return { kind = "fill", text = " 2 fields ", fields = {
          { label = " Title ", value = "Nowhere Suit", skip = false },
          { label = "Price", value = "  ", skip = false },
          { label = "", value = "x", skip = false },
          "junk",
        } }
      end
      if s == "empty" then return { kind = "fill", text = "x", fields = {} } end
      error("not json")
    end
    local function reply(text) return { stop_reason = "end_turn", content = { { type = "text", text = text } } } end

    it("keeps well-formed fields and skips ones without a value", function()
      assert.are.same({ kind = "fill", text = "2 fields", fields = {
        { label = "Title", value = "Nowhere Suit", skip = false },
        { label = "Price", value = "  ", skip = true },
      } }, core.parseScreenAnswer(reply(plan), decode))
    end)

    it("shows a plan with no fields as an answer", function()
      assert.are.equal("answer", core.parseScreenAnswer(reply("empty"), decode).kind)
    end)
  end)

  describe("checkFillAction", function()
    it("types only the values the user confirmed", function()
      assert.is_true(core.checkFillAction("type", { text = "Nowhere Suit" }, fields))
      assert.is_false(core.checkFillAction("type", { text = "Nowhere Suit\n" }, fields))
      assert.is_false(core.checkFillAction("type", { text = "my password" }, fields))
      assert.is_false(core.checkFillAction("type", { text = "" }, fields), "a skipped field's empty value")
    end)

    it("never presses Return or shortcuts, but can move between fields", function()
      assert.is_true(core.checkFillAction("key", { text = "Tab" }, fields))
      assert.is_true(core.checkFillAction("key", { text = "shift+tab" }, fields))
      assert.is_true(core.checkFillAction("key", { text = "cmd+a" }, fields))
      assert.is_true(core.checkFillAction("key", { text = "super+a" }, fields))
      assert.is_false(core.checkFillAction("key", { text = "Return" }, fields))
      assert.is_false(core.checkFillAction("key", { text = "KP_Enter" }, fields))
      assert.is_false(core.checkFillAction("key", { text = "cmd+w" }, fields))
      assert.is_false(core.checkFillAction("key", { text = "backspace", ["repeat"] = 99 }, fields))
    end)

    it("refuses actions that are switched off", function()
      for _, name in ipairs({ "right_click", "left_click_drag", "hold_key", "left_mouse_down", "made_up" }) do
        assert.is_false(core.checkFillAction(name, {}, fields), name)
      end
      assert.is_true(core.checkFillAction("left_click", { coordinate = { 1, 2 } }, fields))
      assert.is_true(core.checkFillAction("screenshot", {}, fields))
    end)
  end)

  it("scales its caps to the plan", function()
    local five = {}
    for i = 1, 5 do five[i] = { label = "F" .. i, value = "x", skip = false } end
    assert.are.same({ 40, 90 }, { core.fillLimits(five) })
    table.insert(five, { label = "Image", value = "", skip = false, file = { id = "i" } })
    table.insert(five, { label = "Skipped", value = "", skip = true })
    assert.are.same({ 50, 114 }, { core.fillLimits(five) })
    local many = {}
    for i = 1, 40 do many[i] = { label = "F" .. i, value = "x", skip = false } end
    assert.are.same({ 80, 180 }, { core.fillLimits(many) })
  end)

  describe("fillClickAllowed", function()
    it("clicks fields and pop-ups but never buttons, links or checkboxes", function()
      assert.is_true(core.fillClickAllowed("AXTextField"))
      assert.is_true(core.fillClickAllowed("AXPopUpButton"))
      for _, role in ipairs({ "AXButton", "AXLink", "AXCheckBox", "AXMenuItem", "AXGroup" }) do
        assert.is_false(core.fillClickAllowed(role), role)
      end
      assert.is_false(core.fillClickAllowed(nil))
    end)

    it("chooses an option only in a menu she opened", function()
      assert.is_true(core.fillClickAllowed("AXMenuItem", nil, true))
    end)

    it("never touches a password field", function()
      assert.is_false(core.fillClickAllowed("AXTextField", "AXSecureTextField"))
    end)
  end)

  describe("fillFocusAllowed", function()
    it("types and presses keys in fields", function()
      assert.is_true(core.fillFocusAllowed("type", { text = "Trail Runner" }, "AXTextField"))
      assert.is_true(core.fillFocusAllowed("key", { text = "space" }, "AXTextArea"))
      assert.is_true(core.fillFocusAllowed("type", { text = "x" }, nil))
    end)

    it("never presses a focused button, link or checkbox with a typed space or Space", function()
      for _, role in ipairs({ "AXButton", "AXLink", "AXCheckBox", "AXMenuItem" }) do
        assert.is_false(core.fillFocusAllowed("type", { text = "Trail Runner" }, role), role)
        assert.is_false(core.fillFocusAllowed("key", { text = "space" }, role), role)
      end
      assert.is_true(core.fillFocusAllowed("key", { text = "shift+tab" }, "AXButton"))
    end)

    it("never types into a password field", function()
      assert.is_false(core.fillFocusAllowed("type", { text = "x" }, "AXTextField", "AXSecureTextField"))
    end)
  end)

  describe("coordinates", function()
    it("maps screenshot pixels to points on the right display", function()
      local frame = { x = -1920, y = -233, w = 1920, h = 1080 }
      assert.are.same({ x = -1820, y = -33 }, core.fillPoint({ 100, 200 }, frame, 1))
      assert.are.same({ x = 200, y = 400 }, core.fillPoint({ 100, 200 }, { x = 0, y = 0, w = 3440, h = 1440 }, 0.5))
    end)

    it("refuses points outside the display or malformed ones", function()
      local frame = { x = 0, y = 0, w = 100, h = 100 }
      assert.is_nil(core.fillPoint({ 101, 5 }, frame, 1))
      assert.is_nil(core.fillPoint({ -1, 5 }, frame, 1))
      assert.is_nil(core.fillPoint({ "a", 5 }, frame, 1))
      assert.is_nil(core.fillPoint(nil, frame, 1))
    end)

    it("scales screens down only when they are too big to send", function()
      assert.are.equal(1, core.fillScale(1920, 1080))
      assert.are.equal(1, core.fillScale(1512, 982))
      local scale = core.fillScale(5120, 2880)
      assert.is_true(5120 * scale <= core.FILL_MAX_EDGE)
      assert.is_true(5120 * scale * 2880 * scale <= core.FILL_MAX_PIXELS + 1)
    end)
  end)

  describe("requests and results", function()
    local body = core.fillRequest(core.mergeConfig(), "FILL PROMPT", fields, "IMG")

    it("uses the computer toolset with the risky actions switched off", function()
      local toolset = body.tools[1]
      assert.are.equal("computer_toolset_20260801", toolset.type)
      assert.is_nil(toolset.name)
      for _, name in ipairs(core.FILL_DISABLED) do assert.is_false(toolset.configs[name].enabled, name) end
      assert.is_nil(toolset.configs.left_click)
    end)

    it("starts from the confirmed plan and a screenshot, leaving out skipped fields", function()
      local content = body.messages[1].content
      assert.truthy(content[1].text:find("- Title: Nowhere Suit", 1, true))
      assert.is_nil(content[1].text:find("Price", 1, true))
      assert.are.equal("IMG", content[2].source.data)
    end)

    it("names the toolset on every result", function()
      assert.are.same({ type = "tool_result", tool_use_id = "t1", toolset_name = "computer", content = "OK" },
        core.fillResult("t1", "OK"))
      assert.is_true(core.fillResult("t1", "no", true).is_error)
      assert.are.equal("image", core.fillImage("t2", "DATA").content[1].type)
    end)

    it("reads the computer actions out of a response", function()
      local resp = { content = {
        { type = "thinking", thinking = "" },
        { type = "tool_use", id = "a", name = "left_click", toolset_name = "computer",
          input = { coordinate = { 1, 2 } } },
        { type = "tool_use", id = "b", name = "open_memory", input = {} },
        { type = "tool_use", id = "c", name = "screenshot", toolset_name = "computer" },
      } }
      assert.are.same({ { id = "a", name = "left_click", input = { coordinate = { 1, 2 } }, computer = true },
                        { id = "b", name = "open_memory", input = {}, computer = false },
                        { id = "c", name = "screenshot", input = {}, computer = true } }, core.fillActions(resp))
    end)

    it("parses keys", function()
      assert.are.same({ { "shift" }, "tab" }, { core.fillKey("Shift+Tab") })
      assert.are.same({ { "cmd" }, "a" }, { core.fillKey("super+a") })
    end)
  end)
end)

describe("uploading a file from memory", function()
  local images = {
    { id = "img-1", path = "/m/acme/brand/hero-wide.jpg", name = "hero-wide.jpg", width = 1200, height = 630,
      note = "hero-wide.jpg is the sharing image", thumb = "THUMB1" },
    { id = "img-2", path = "/m/acme/brand/logo.png", name = "logo.png", width = 512, height = 512, note = "",
      thumb = "" },
  }
  local fields = core.fillFields({
    { label = "Title", value = "Trailrunner 2", upload = "", skip = false },
    { label = "Sharing image", value = "", upload = "img-1", skip = false },
    { label = "Logo", value = "", upload = "img-9", skip = false },
  }, images)

  it("turns an upload field into the confirmed file, and skips one naming an image it wasn't shown", function()
    assert.are.same({ id = "img-1", path = "/m/acme/brand/hero-wide.jpg", name = "hero-wide.jpg" }, fields[2].file)
    assert.is_false(fields[2].skip)
    assert.is_true(fields[3].skip)
    assert.is_nil(fields[3].file)
  end)

  it("sends each memory image as what memory says about it, then its thumbnail", function()
    local blocks = core.imageBlocks(images)
    assert.are.equal(2, #blocks, "an image without a thumbnail is left out")
    assert.are.equal('<memory_image id="img-1" file="hero-wide.jpg" size="1200x630">'
      .. "hero-wide.jpg is the sharing image</memory_image>", blocks[1].text)
    assert.are.equal("THUMB1", blocks[2].source.data)
    local body = core.screenRequest(core.mergeConfig(), "S", "q", "IMG", "image/jpeg", { images = images, memory = {} })
    assert.are.equal("THUMB1", body.messages[1].content[2].source.data)
  end)

  it("offers upload_file only for confirmed files and tells Claude which field gets which", function()
    local tools = core.fillTools(fields)
    assert.are.equal("upload_file", tools[2].name)
    assert.are.same({ "img-1" }, tools[2].input_schema.properties.file.enum)
    assert.are.equal(1, #core.fillTools({ { label = "T", value = "x", skip = false } }))
    assert.truthy(core.fillPlanText(fields):find("- Sharing image: upload file img-1 (hero-wide.jpg)", 1, true))
  end)

  it("uploads only confirmed files, at most twice each", function()
    assert.is_true(core.checkFillAction("upload_file", { file = "img-1", coordinate = { 1, 1 } }, fields))
    assert.is_false(core.checkFillAction("upload_file", { file = "img-9" }, fields))
    assert.is_false(core.checkFillAction("upload_file", { file = "/etc/passwd" }, fields))
    assert.is_true(core.checkFillAction("upload_file", { file = "img-1" }, fields, { ["img-1"] = 1 }))
    assert.is_false(core.checkFillAction("upload_file", { file = "img-1" }, fields, { ["img-1"] = 2 }))
  end)

  it("drags files only onto drop zones, never onto buttons or links", function()
    assert.is_true(core.dropTarget("AXStaticText"))
    assert.is_true(core.dropTarget("AXGroup"))
    assert.is_false(core.dropTarget("AXButton"))
    assert.is_false(core.dropTarget("AXLink"))
    assert.is_false(core.dropTarget(nil))
  end)

  it("clicks upload buttons and drop zones, never anything that saves or publishes", function()
    assert.is_true(core.uploadClickAllowed("AXButton", "Upload"))
    assert.is_true(core.uploadClickAllowed("AXButton", "Choose image"))
    assert.is_true(core.uploadClickAllowed("AXGroup", "Drop your logo here"))
    assert.is_true(core.uploadClickAllowed("AXGroup", nil))
    assert.is_false(core.uploadClickAllowed("AXButton", "Upload & publish"))
    assert.is_false(core.uploadClickAllowed("AXButton", "Save product"))
    assert.is_false(core.uploadClickAllowed("AXButton", "Options"))
    assert.is_false(core.uploadClickAllowed("AXCheckBox", "Add"))
    assert.is_false(core.uploadClickAllowed("AXGroup", "Submit"))
    assert.is_false(core.uploadClickAllowed("AXButton", "Add to cart"))
  end)

  it("treats text inside a button or link as that button or link", function()
    local inLink = { { role = "AXStaticText", label = "Go live" }, { role = "AXLink", label = "Go live" },
                     { role = "AXGroup" } }
    assert.are.same({ "AXLink", "Go live" }, { core.clickTarget(inLink) })
    assert.is_false(core.uploadClickAllowed(core.clickTarget(inLink)))
    local inButton = { { role = "AXStaticText", label = "Choose image" }, { role = "AXButton" } }
    assert.are.same({ "AXButton" }, { core.clickTarget(inButton) })
    local zone = { { role = "AXStaticText", label = "Drop your logo here" }, { role = "AXGroup" },
                   { role = "AXWebArea" } }
    assert.are.same({ "AXStaticText", "Drop your logo here" }, { core.clickTarget(zone) })
    assert.is_true(core.uploadClickAllowed(core.clickTarget(zone)))
    assert.is_nil(core.clickTarget({}))
  end)
end)

describe("learning from voice", function()
  it("is on for questions and off for style by default", function()
    local cfg = core.mergeConfig()
    assert.is_true(cfg.learnFromVoice)
    assert.is_false(cfg.learnStyle)
  end)

  it("recognises remember requests however they are punctuated", function()
    assert.are.equal("the product photos are in ~/photos",
      core.rememberText("Grandma, remember that the product photos are in ~/photos"))
    assert.are.equal("Sam owns the backend", core.rememberText("remember: Sam owns the backend."))
    assert.are.equal("the deck is final", core.rememberText("Hey grandma remember the deck is final"))
    assert.are.equal("we launch on Monday", core.rememberText("Note that we launch on Monday"))
    assert.are.equal("Priya prefers calls", core.rememberText("make a note Priya prefers calls"))
  end)

  it("leaves other questions alone", function()
    assert.is_nil(core.rememberText("Do you remember what this button does?"))
    assert.is_nil(core.rememberText("Where do I click to change billing?"))
    assert.is_nil(core.rememberText("remember"))
    assert.is_nil(core.rememberText("Remember which tab had the invoice?"))
    assert.is_nil(core.rememberText("grandma remember where I saved the deck"))
    assert.is_nil(core.rememberText("Note that this field is required?"))
  end)

  it("takes grandma's name before any of them and drops a capitalised that", function()
    assert.are.equal("Acme invoices go to Sam", core.rememberText("Grandma, note that Acme invoices go to Sam."))
    assert.are.equal("Priya prefers calls", core.rememberText("Make a note. That Priya prefers calls"))
    assert.are.equal("to send the deck on Friday", core.rememberText("remember to send the deck on Friday"))
  end)

  it("learns style only from dictations long enough to show it", function()
    assert.is_true(core.styleWorthy("I think we should ship this on Monday after the review"))
    assert.is_false(core.styleWorthy("yes sounds good"))
  end)
end)


describe("sounds", function()
  local function cfg(over)
    local c = { sounds = true, soundVolume = 0.5, dictationSounds = false }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end

  it("play by default, but never while a call could hear them", function()
    assert.is_true(core.soundAllowed(cfg(), "ask", false))
    assert.is_false(core.soundAllowed(cfg(), "ask", true))
    assert.is_false(core.soundAllowed(cfg({ sounds = false }), "answer", false))
  end)

  it("tick only with dictationSounds", function()
    assert.is_false(core.soundAllowed(cfg(), "tick", false))
    assert.is_true(core.soundAllowed(cfg({ dictationSounds = true }), "tick", false))
  end)

  it("leave out what soundsOff names", function()
    assert.is_false(core.soundAllowed(cfg({ soundsOff = { think = true } }), "think", false))
    assert.is_true(core.soundAllowed(cfg({ soundsOff = { think = true } }), "answer", false))
  end)

  it("count an online meeting or a call app on the mic as a call", function()
    assert.is_true(core.inCall(true, {}))
    assert.is_true(core.inCall(false, { ["us.zoom.xos"] = true }))
    assert.is_false(core.inCall(false, {}))
    assert.is_false(core.inCall(false, nil))
  end)

  it("defaults on, quiet, without the dictation tick", function()
    assert.is_true(core.DEFAULTS.sounds)
    assert.is_false(core.DEFAULTS.dictationSounds)
    assert.is_true(core.OPTIONS.soundsOff)
  end)
end)

describe("bridgeMic", function()
  local inputs = { { uid = "AirPods-UID", transport = "Bluetooth" },
                   { uid = "BuiltInMicrophoneDevice", transport = "Built-in" } }

  it("covers a Bluetooth mic with the built-in one", function()
    assert.are.equal("BuiltInMicrophoneDevice", core.bridgeMic(core.mergeConfig(), "Bluetooth", inputs))
  end)

  it("does nothing for the built-in mic, with no built-in mic, or when turned off", function()
    assert.is_nil(core.bridgeMic(core.mergeConfig(), "Built-in", inputs))
    assert.is_nil(core.bridgeMic(core.mergeConfig(), nil, inputs))
    assert.are.equal("BuiltInMicrophoneDevice", core.bridgeMic(core.mergeConfig(), "Bluetooth LE", inputs))
    assert.is_nil(core.bridgeMic(core.mergeConfig(), "Bluetooth", { inputs[1] }))
    assert.is_nil(core.bridgeMic(core.mergeConfig({ bridgeBluetoothMic = false }), "Bluetooth", inputs))
  end)
end)
