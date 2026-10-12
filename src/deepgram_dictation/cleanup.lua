-- Cleans a dictation with Claude before it is pasted: removes repeats and false starts, applies
-- spoken self-corrections, fixes misheard words and names. Falls back to the raw transcript
-- whenever Claude is slow, errors, or answers with something that isn't a cleanup.
--
-- Names come from the dictionary's `names` and, when grandmaHome is set, from names.json, which
-- names_from_grandma.py extracts from grandma memory about once a day.

local core = require("deepgram_dictation.core")

local M = {}

local API_URL = "https://api.anthropic.com/v1/messages"
local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local NAMES_PATH = core.supportDir() .. "/names.json"
local NAMES_MAX_AGE = 24 * 60 * 60
local NAMES_RETRY_AFTER = 60 * 60 -- after a failed extraction, don't try again on every dictation

local cfg, instructions, apiKey, extractor, lastAttempt
local extracted, extractedMtime = {}, nil -- { names = {...}, keyterms = {...} }

local function log(fmt, ...) print("[deepgram-dictation] cleanup: " .. string.format(fmt, ...)) end

local function getApiKey()
  if apiKey then return apiKey end
  local out, ok = hs.execute("/usr/bin/security find-generic-password -s '" .. cfg.anthropicKeychainName .. "' -w")
  if ok and out and out:match("%S") then apiKey = out:gsub("%s+$", "") end
  return apiKey
end

-- Names extracted from grandma memory, re-read only when names.json changes.
local function extractedNames()
  local attrs = hs.fs.attributes(NAMES_PATH)
  if not attrs then return {} end
  local function list(v) return type(v) == "table" and v or {} end
  if attrs.modification ~= extractedMtime then
    extractedMtime = attrs.modification
    local f = io.open(NAMES_PATH, "r")
    local ok, data = pcall(hs.json.decode, f and f:read("a") or "")
    if f then f:close() end
    data = ok and type(data) == "table" and data or {}
    extracted = { names = list(data.names), keyterms = list(data.keyterms) }
  end
  return extracted
end

-- Re-extracts names from grandma memory in the background when names.json is missing or stale.
local function refreshNames()
  if not cfg.grandmaHome or extractor then return end
  local attrs = hs.fs.attributes(NAMES_PATH)
  if attrs and os.time() - attrs.modification < NAMES_MAX_AGE then return end
  if lastAttempt and os.time() - lastAttempt < NAMES_RETRY_AFTER then return end
  lastAttempt = os.time()
  local python = cfg.python or core.findExecutable(function(p) return hs.fs.attributes(p) ~= nil end,
    core.PYTHON_CANDIDATES)
  if not python then return end
  hs.fs.mkdir(core.supportDir())
  extractor = hs.task.new(python, function(code, stdout, stderr)
    extractor = nil
    if code == 0 then log("%s", stdout:gsub("%s+$", "")) else log("name extraction failed: %s", stderr) end
  end, {
    MODULE_DIR .. "/names_from_grandma.py",
    "--grandma-home", (cfg.grandmaHome:gsub("^~", os.getenv("HOME"))),
    "--out", NAMES_PATH,
    "--keychain-name", cfg.anthropicKeychainName,
    "--model", cfg.cleanupModel,
  })
  extractor:start()
end

function M.setup(config)
  cfg = config
  if not cfg.cleanup then return end
  local f = io.open(MODULE_DIR .. "/cleanup_prompt.txt", "r")
  instructions = f and f:read("a")
  if f then f:close() end
  if not instructions then log("cleanup_prompt.txt not found, cleanup is off") end
  if not getApiKey() then log("no Anthropic key in Keychain ('%s'), cleanup is off", cfg.anthropicKeychainName) end
  refreshNames()
end

function M.teardown()
  if extractor then extractor:terminate() extractor = nil end
end

-- All names for cleanup, and the Deepgram keyterms (dictionary keyterms plus the top names).
function M.namesFor(dict)
  return core.mergeNames(dict, cfg.grandmaHome and extractedNames() or {}, cfg.keytermNames)
end

-- Cleans `text`, then calls `done(finalText, info)` exactly once. `info` records what happened:
-- { status = "ok" | "off" | "timeout" | "error" | "rejected", ms = ..., reason = ... }.
function M.run(text, names, done)
  if not (cfg.cleanup and instructions and getApiKey()) then return done(text, { status = "off" }) end
  refreshNames()
  local started = hs.timer.secondsSinceEpoch()
  local finished, timer = false, nil
  local function finish(out, status, reason)
    if finished then return end
    finished = true
    if timer then timer:stop() end
    local ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000 + 0.5)
    if status ~= "ok" then log("%s after %d ms%s, pasting raw text", status, ms, reason and (": " .. reason) or "") end
    done(out, { status = status, ms = ms, reason = reason })
  end
  timer = hs.timer.doAfter(cfg.cleanupTimeout, function() finish(text, "timeout") end)
  local body = core.cleanupRequest(cfg, core.cleanupSystemPrompt(instructions, names), text)
  hs.http.asyncPost(API_URL, hs.json.encode(body), {
    ["x-api-key"] = getApiKey(),
    ["anthropic-version"] = "2023-06-01",
    ["content-type"] = "application/json",
  }, function(status, respBody)
    local ok, resp = pcall(hs.json.decode, respBody or "")
    if status ~= 200 then
      if status == 401 or status == 403 then apiKey = nil end
      local message = ok and type(resp) == "table" and type(resp.error) == "table" and resp.error.message
      return finish(text, "error", "HTTP " .. tostring(status) .. (message and (": " .. message) or ""))
    end
    local clean, why = core.parseCleanup(ok and resp or nil, text)
    if clean then finish(clean, "ok") else finish(text, "rejected", why) end
  end)
end

return M
