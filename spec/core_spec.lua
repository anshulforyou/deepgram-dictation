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

  it("rejects invalid language, model and minSeconds", function()
    assert.has_error(function() core.mergeConfig({ language = "" }) end)
    assert.has_error(function() core.mergeConfig({ model = 3 }) end)
    assert.has_error(function() core.mergeConfig({ minSeconds = -1 }) end)
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

describe("normalizeDictionary", function()
  it("returns empty lists for non-table input", function()
    assert.are.same({ keyterms = {}, replacements = {} }, core.normalizeDictionary(nil))
    assert.are.same({ keyterms = {}, replacements = {} }, core.normalizeDictionary("oops"))
  end)

  it("drops malformed entries", function()
    local dict = core.normalizeDictionary({
      keyterms = { "Good", "", "   ", 42 },
      replacements = { { from = "btw", to = "by the way" }, { from = "" , to = "x" }, { from = "a" }, "bad" },
    })
    assert.are.same({ "Good" }, dict.keyterms)
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
