-- What grandma learns from what you say to her: the app's side of voice_memory.py. Each screen
-- question, form fill and correction is logged to interactions/<day>.jsonl (a follow-up within a
-- few minutes is linked to the question it follows), and with learnStyle each dictation long
-- enough to show how you write goes to style/<day>.jsonl. Once an hour voice_memory.py distills
-- finished days and checks whether style is due. Nothing here writes to grandma memory itself:
-- everything becomes a proposal for `grandma review`. Plain dictation is never used for facts.

local core = require("deepgram_dictation.core")

local M = {}

local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local FOLLOW_UP_SECONDS = 180
local TICK_SECONDS = 60 * 60

local cfg, timer, firstTick, worker, lastScreen
-- Tasks in flight: an hs.task nothing refers to can be collected before it ends, and its
-- callback never runs. Only written, never read, on purpose.
local running = {} -- luacheck: ignore 241

local function log(fmt, ...) print("[deepgram-dictation] voice memory: " .. string.format(fmt, ...)) end

local function exists(p) return hs.fs.attributes(p) ~= nil end

local function python()
  return cfg.python or core.findExecutable(exists, core.PYTHON_CANDIDATES)
end

local function claude()
  if cfg.claudePath then return cfg.claudePath end
  local home = os.getenv("HOME")
  local candidates = {}
  for _, p in ipairs(core.CLAUDE_CANDIDATES) do table.insert(candidates, (p:gsub("^~", home))) end
  return core.findExecutable(exists, candidates)
end

local function home() return (cfg.grandmaHome:gsub("^~", os.getenv("HOME"))) end

function M.enabled() return cfg ~= nil and cfg.learnFromVoice == true and cfg.grandmaHome ~= nil end
function M.styleEnabled() return cfg ~= nil and cfg.learnStyle == true and cfg.grandmaHome ~= nil end

-- Appends `record` as one JSON line to <support>/<dir>/<today>.jsonl.
local function append(dir, record)
  local base = core.supportDir()
  hs.fs.mkdir(base)
  hs.fs.mkdir(base .. "/" .. dir)
  local f = io.open(string.format("%s/%s/%s.jsonl", base, dir, os.date("%Y-%m-%d")), "a")
  if not f then return log("could not write to %s", dir) end
  f:write(hs.json.encode(record) .. "\n")
  f:close()
end

local function trim(text, n)
  text = tostring(text or "")
  return #text > n and (text:sub(1, n) .. "...") or text
end

-- A screen question, fill or "remember" from the dictation history record, as an interaction.
function M.screen(record)
  if not M.enabled() or type(record.screen) ~= "table" then return end
  local s = record.screen
  local now = hs.timer.secondsSinceEpoch()
  local id = os.date("%Y%m%d-%H%M%S", math.floor(now)) .. string.format("-%03d", math.floor(now % 1 * 1000))
  local fields
  for _, f in ipairs(type(s.fields) == "table" and s.fields or {}) do
    fields = fields or {}
    table.insert(fields, { label = f.label, value = trim(f.value, 200), skip = f.skip,
                           file = type(f.file) == "table" and f.file.name or nil })
  end
  append("interactions", {
    id = id, at = os.date("%Y-%m-%dT%H:%M:%S", math.floor(now)), kind = "screen",
    question = record.raw, answer_kind = s.kind, answer = trim(s.answer, 600), status = s.status, reason = s.reason,
    fields = fields, confirmed = s.confirmed, memory = s.memory, opened = s.opened,
    fill = type(s.fill) == "table" and { status = s.fill.status, reason = s.fill.reason } or nil,
    follows = lastScreen and now - lastScreen.at < FOLLOW_UP_SECONDS and lastScreen.id or nil,
  })
  lastScreen = { id = id, at = now }
end

-- A dictation flagged as transcribed wrong (a correction about names and words).
function M.flag(record)
  if not M.enabled() or type(record) ~= "table" then return end
  append("interactions", { at = os.date("%Y-%m-%dT%H:%M:%S"), kind = "flag", raw = record.raw,
                           pasted = record.pasted })
end

-- A pasted dictation, kept for style learning only when learnStyle is on.
function M.dictation(text)
  if not M.styleEnabled() or not core.styleWorthy(text) then return end
  local app = hs.application.frontmostApplication()
  append("style", { at = os.date("%Y-%m-%dT%H:%M:%S"), app = app and app:name(), text = text })
end

-- Runs voice_memory.py with `extra` and calls done(decodedJson) or done(nil, err).
local function run(extra, done)
  local py = python()
  if not py then return done(nil, "python3 not found") end
  local args = { MODULE_DIR .. "/voice_memory.py", "--grandma-home", home(), "--support", core.supportDir(),
                 "--keychain-name", cfg.anthropicKeychainName, "--model", cfg.cleanupModel }
  for _, a in ipairs(extra) do table.insert(args, a) end
  local out, task = {}, nil
  task = hs.task.new(py, function(code, stdout, stderr)
    running[task] = nil
    table.insert(out, stdout or "")
    if code ~= 0 then return done(nil, (tostring(stderr):gsub("%s+$", ""):match("[^\n]*$"))) end
    local ok, value = pcall(hs.json.decode, table.concat(out))
    if ok and type(value) == "table" then return done(value) end
    done(nil, "voice_memory.py printed something unexpected")
  end, function(_, stdout)
    table.insert(out, stdout or "")
    return true
  end, args)
  -- Claude Code finds its login in the Keychain by user name.
  local env = { HOME = os.getenv("HOME"), PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
                USER = os.getenv("USER"), LOGNAME = os.getenv("LOGNAME") or os.getenv("USER"),
                TMPDIR = os.getenv("TMPDIR") }
  task:setEnvironment(env)
  running[task] = true
  if not task:start() then
    running[task] = nil
    done(nil, "could not start voice_memory.py")
  end
end

-- "Grandma, remember ...": done({ scope, target, line, path }) or done(nil, err).
function M.remember(text, done) run({ "--remember=" .. text }, done) end

-- Distills finished days, then checks whether style learning is due. One run at a time.
function M.tick()
  if worker or not M.enabled() then return end
  local path = claude()
  if not path then return log("the claude CLI wasn't found, so nothing is distilled") end
  local extra = { "--claude", path }
  if cfg.claudeModel then table.insert(extra, "--claude-model") table.insert(extra, cfg.claudeModel) end
  worker = true
  run({ "--distill", table.unpack(extra) }, function(result, err)
    if err then log("distill failed: %s", err) end
    if result and #(result.proposals or {}) > 0 then
      log("%d proposal(s) for grandma review from %s", #result.proposals, table.concat(result.days, ", "))
      local text = string.format("%d memory proposal(s) from what you said to her. Run: grandma review",
        #result.proposals)
      hs.notify.new({ title = "Grandma learned something", informativeText = text }):send()
    end
    if not M.styleEnabled() then worker = nil return end
    run({ "--style", table.unpack(extra) }, function(style, styleErr)
      worker = nil
      if styleErr then return log("style failed: %s", styleErr) end
      if style and style.path then
        log("style proposal: %s", style.path)
        hs.notify.new({ title = "Grandma learned how you write",
                        informativeText = "A proposed change to your style notes. Run: grandma review global" }):send()
      end
    end)
  end)
end

function M.setup(config)
  cfg = config
  if not M.enabled() then return end
  firstTick = hs.timer.doAfter(90, M.tick) -- not during startup
  timer = hs.timer.doEvery(TICK_SECONDS, M.tick)
end

function M.teardown()
  if firstTick then firstTick:stop() firstTick = nil end
  if timer then timer:stop() timer = nil end
end

return M
