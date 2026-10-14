-- Grandma's sounds: soft music-box notes and wooden needle taps (made by scripts/make_sounds.py).
-- Silent whenever a call might hear them: a call app holding the mic, or an online meeting
-- being recorded. See core.soundAllowed for every rule.

local core = require("deepgram_dictation.core")

local M = {}

local DIR = hs.configdir .. "/deepgram_dictation/sounds/"
local THINK_FIRST, THINK_EVERY = 0.7, 1.4 -- seconds: her needles while she thinks

local cfg, inCall
local cache = {}
local thinkTimer, thinkFirst

local function sound(name)
  if cache[name] == nil then cache[name] = hs.sound.getByFile(DIR .. name .. ".wav") or false end
  return cache[name] or nil
end

-- Plays `name` (a file in sounds/) at the configured volume times `scale`.
function M.play(name, scale)
  if not (cfg and core.soundAllowed(cfg, name, inCall())) then return end
  local s = sound(name)
  if not s then return end
  if s:isPlaying() then s:stop() end
  s:volume(math.min(1, cfg.soundVolume * (scale or 1)))
  s:play()
end

-- Her needles, quietly, until stopThinking.
function M.startThinking()
  M.stopThinking()
  thinkFirst = hs.timer.doAfter(THINK_FIRST, function()
    thinkFirst = nil
    M.play("think", 0.7)
    thinkTimer = hs.timer.doEvery(THINK_EVERY, function() M.play("think", 0.7) end)
  end)
end

function M.stopThinking()
  if thinkFirst then thinkFirst:stop() thinkFirst = nil end
  if thinkTimer then thinkTimer:stop() thinkTimer = nil end
end

-- `isInCall` returns true while a call might hear a sound.
function M.setup(config, isInCall)
  cfg, inCall = config, isInCall or function() return false end
end

function M.teardown()
  M.stopThinking()
  cache = {}
end

return M
