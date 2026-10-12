-- Keeps the last `keepDictations` dictations on disk: the audio plus a JSON record of what
-- Deepgram heard, what cleanup changed, what was pasted and how long each step took. Used to
-- spot bad transcriptions ("Flag last dictation") and to replay them through a changed pipeline
-- (scripts/replay_dictations.py). Nothing here leaves the Mac.

local core = require("deepgram_dictation.core")

local M = {}

local DIR = core.supportDir() .. "/dictations"

local cfg

local function log(fmt, ...) print("[deepgram-dictation] history: " .. string.format(fmt, ...)) end

local function stems()
  local out = {}
  if not hs.fs.attributes(DIR) then return out end
  for file in hs.fs.dir(DIR) do
    local stem = file:match("^(.+)%.json$")
    if stem then table.insert(out, stem) end
  end
  table.sort(out)
  return out
end

local function writeJson(path, value)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(hs.json.encode(value, true))
  f:close()
  return true
end

function M.setup(config) cfg = config end

function M.enabled() return cfg.keepDictations > 0 end

-- Saves `record` and moves the recording at `audioPath` next to it (or deletes the recording
-- when history is off).
function M.save(audioPath, record)
  if not M.enabled() then
    os.remove(audioPath)
    return
  end
  hs.fs.mkdir(core.supportDir())
  hs.fs.mkdir(DIR)
  local now = hs.timer.secondsSinceEpoch()
  local stem = core.sessionName(os.date("*t", math.floor(now))) .. string.format("-%03d", math.floor(now % 1 * 1000))
  if hs.fs.attributes(audioPath) then
    local moved = os.rename(audioPath, DIR .. "/" .. stem .. ".wav")
    if moved then record.audio = stem .. ".wav" else os.remove(audioPath) end
  end
  if not writeJson(DIR .. "/" .. stem .. ".json", record) then log("could not write %s", stem) end
  for _, old in ipairs(core.dictationsToPrune(stems(), cfg.keepDictations)) do
    os.remove(DIR .. "/" .. old .. ".json")
    os.remove(DIR .. "/" .. old .. ".wav")
  end
end

-- Marks the newest saved dictation as badly transcribed. Returns its record, or nil.
function M.flagLast()
  local all = stems()
  local stem = all[#all]
  if not stem then return nil end
  local path = DIR .. "/" .. stem .. ".json"
  local f = io.open(path, "r")
  local ok, record = pcall(hs.json.decode, f and f:read("a") or "")
  if f then f:close() end
  if not ok or type(record) ~= "table" then return nil end
  record.flagged = true
  writeJson(path, record)
  return record
end

-- Path of the newest saved recording, or nil.
function M.lastAudio()
  local all = stems()
  for i = #all, 1, -1 do
    local wav = DIR .. "/" .. all[i] .. ".wav"
    if hs.fs.attributes(wav) then return wav end
  end
  return nil
end

function M.dir() return DIR end

return M
