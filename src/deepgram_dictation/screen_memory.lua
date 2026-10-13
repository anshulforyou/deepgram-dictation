-- What grandma knows about the user, for screen questions: runs grandma_context.py, which reads
-- the grandma memory home the way grandma routes (see that file). Only used with grandmaHome.

local core = require("deepgram_dictation.core")

local M = {}

local MODULE_DIR = hs.configdir .. "/deepgram_dictation"

local cfg, refresher, refreshFailedAt
local RETRY_AFTER = 60 * 60 -- after a failed profile refresh, don't pay for another on every question
-- Tasks in flight: an hs.task nothing refers to can be collected before it ends, and its
-- callback never runs. Only written, never read, on purpose.
local running = {} -- luacheck: ignore 241

local function log(fmt, ...) print("[deepgram-dictation] screen memory: " .. string.format(fmt, ...)) end

local function python()
  return cfg.python or core.findExecutable(function(p) return hs.fs.attributes(p) ~= nil end, core.PYTHON_CANDIDATES)
end

local function args(extra)
  local out = { MODULE_DIR .. "/grandma_context.py", "--grandma-home", (cfg.grandmaHome:gsub("^~", os.getenv("HOME"))) }
  for _, a in ipairs(extra) do table.insert(out, a) end
  return out
end

-- Runs grandma_context.py with `extra` arguments and calls `done(decodedJson)` or `done(nil, err)`.
local function run(extra, done)
  local py = python()
  if not py then return done(nil, "python3 not found") end
  -- Output is read as it comes: a sweater's memory is bigger than the pipe holds, and without a
  -- stream callback the script blocks on its write and never exits.
  local out, errs, task = {}, {}, nil
  task = hs.task.new(py, function(code, stdout, stderr)
    running[task] = nil
    table.insert(out, stdout or "")
    table.insert(errs, stderr or "")
    if code ~= 0 then
      local err = table.concat(errs):gsub("%s+$", ""):match("[^\n]*$") -- the last line says why
      return done(nil, err ~= "" and err or "grandma memory could not be read")
    end
    local ok, value = pcall(hs.json.decode, table.concat(out))
    if ok and type(value) == "table" then return done(value) end
    done(nil, "grandma_context.py printed something unexpected")
  end, function(_, stdout, stderr)
    table.insert(out, stdout or "")
    table.insert(errs, stderr or "")
    return true
  end, args(extra))
  running[task] = true
  if not task:start() then
    running[task] = nil
    done(nil, "could not start grandma_context.py")
  end
end

function M.enabled() return cfg ~= nil and cfg.screenAssist and cfg.grandmaHome ~= nil end

-- Rewrites the profile in the background when a global memory file has changed since.
function M.refreshProfile()
  if not M.enabled() or refresher then return end
  if refreshFailedAt and os.time() - refreshFailedAt < RETRY_AFTER then return end
  local py = python()
  if not py then return end
  refresher = hs.task.new(py, function(code, stdout, stderr)
    refresher = nil
    refreshFailedAt = code ~= 0 and os.time() or nil
    local out = tostring(code == 0 and stdout or stderr):gsub("%s+$", "")
    if code ~= 0 or out ~= "profile is current" then log("%s", out) end
  end, args({ "--refresh-profile", "--keychain-name", cfg.anthropicKeychainName, "--model", cfg.cleanupModel }))
  if not refresher:start() then refresher = nil end
end

function M.setup(config)
  cfg = config
  M.refreshProfile()
end

function M.teardown()
  if refresher then refresher:terminate() refresher = nil end
end

-- The profile, catalog and named memory for `question`: done(context) or done(nil, err).
-- (The `--flag=value` form, so a question starting with "-" isn't taken for a flag.)
function M.context(question, done) run({ "--question=" .. question }, done) end

-- One sweater's or project's memory, within `maxChars`: done({ name, kind, text }) or done(nil, err).
function M.open(name, maxChars, done)
  run({ "--open=" .. tostring(name), "--max-chars=" .. tostring(math.floor(maxChars)) }, done)
end

return M
