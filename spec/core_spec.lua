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

describe("findRecBinary", function()
  it("returns the first existing candidate", function()
    local exists = function(p) return p == "/usr/local/bin/rec" end
    assert.are.equal("/usr/local/bin/rec", core.findRecBinary(exists))
  end)

  it("prefers earlier candidates", function()
    assert.are.equal("/opt/homebrew/bin/rec", core.findRecBinary(function() return true end))
  end)

  it("returns nil when nothing exists", function()
    assert.is_nil(core.findRecBinary(function() return false end))
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
