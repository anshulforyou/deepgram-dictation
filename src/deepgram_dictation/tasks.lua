-- Grandma's background tasks: "review this PR", said with Fn+Control, starts a Claude Code session
-- in the background (task_agent.py) with the user's grandma memory, and she comes back when it is
-- done or when she needs something. Her answer shows in a notification and, on a click, in the
-- panel; holding Fn+Control while that panel is open replies to her, and she carries on.
--
-- Claude Code runs the session (`claude --bg`) and keeps its state in ~/.claude/jobs/<id>/: this
-- module reads that every few seconds while a task is working and never runs Lua otherwise. The
-- list of tasks is kept in the support folder, so a reload picks up where it was.

local core = require("deepgram_dictation.core")
local overlay = require("deepgram_dictation.screen_overlay")
local sounds = require("deepgram_dictation.sounds")

local M = {}

local MODULE_DIR = hs.configdir .. "/deepgram_dictation"
local SCRIPT = MODULE_DIR .. "/task_agent.py"
local JOBS = os.getenv("HOME") .. "/.claude/jobs/"
local POLL = 4 -- seconds between looks at a working task
local TAIL = 65536 -- bytes of a session's timeline read for her last message
local SHOWN = 8 -- tasks in the menu

local cfg
local list = {} -- { id, title, state, startedAt, memory, edits, dir }
local poller, awaiting
local running = {} -- luacheck: ignore 241 (hs.tasks in flight, kept so they aren't collected)

local function log(fmt, ...) print("[deepgram-dictation] tasks: " .. string.format(fmt, ...)) end
local function exists(p) return hs.fs.attributes(p) ~= nil end
local function dir() return core.supportDir() .. "/tasks" end
local function expand(p) return (p:gsub("^~", os.getenv("HOME"))) end

local function python() return cfg.python or core.findExecutable(exists, core.PYTHON_CANDIDATES) end

local function claude()
  if cfg.claudePath then return cfg.claudePath end
  local candidates = {}
  for _, p in ipairs(core.CLAUDE_CANDIDATES) do table.insert(candidates, expand(p)) end
  return core.findExecutable(exists, candidates)
end

local function save()
  hs.fs.mkdir(core.supportDir())
  hs.fs.mkdir(dir())
  local f = io.open(dir() .. "/tasks.json", "w")
  if f then f:write(hs.json.encode(list)) f:close() end
end

-- A file's JSON as a table, or nil (hs.json logs an error for anything that isn't JSON).
local function readJSON(path)
  local f = io.open(path, "r")
  local text = f and f:read("a")
  if f then f:close() end
  if not text or not text:match("^%s*[%[{]") then return nil end
  local ok, value = pcall(hs.json.decode, text)
  return ok and type(value) == "table" and value or nil
end

local function load() list = readJSON(dir() .. "/tasks.json") or {} end

local function find(id)
  for _, t in ipairs(list) do if t.id == id then return t end end
end

local function readState(id) return readJSON(JOBS .. id .. "/state.json") end

-- Her last message, from the end of the session's timeline.
local function lastText(id)
  local f = io.open(JOBS .. id .. "/timeline.jsonl", "r")
  if not f then return nil end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - TAIL))
  local text = f:read("a")
  f:close()
  if size > TAIL then text = text:gsub("^[^\n]*\n", "", 1) end -- a cut-off first line
  local last
  for line in text:gmatch("[^\n]+") do
    local ok, entry = pcall(hs.json.decode, line:match("^{") and line or "{}")
    if ok and type(entry) == "table" and type(entry.text) == "string" and entry.text:match("%S") then
      last = entry.text
    end
  end
  return last
end

-- Runs task_agent.py with `args`; `done(result, err)` gets its JSON.
local function agent(args, done)
  local py, cl = python(), claude()
  if not py or not cl then return done(nil, cl and "python3 wasn't found" or "the claude CLI wasn't found") end
  local full = { SCRIPT }
  for _, a in ipairs(args) do table.insert(full, a) end
  table.insert(full, "--claude")
  table.insert(full, cl)
  local task
  task = hs.task.new(py, function(_, stdout, stderr)
    running[task] = nil
    local lastLine = (stdout or ""):match("([^\n]+)%s*$") or ""
    local ok, value = pcall(hs.json.decode, lastLine)
    if not ok or type(value) ~= "table" then
      log("task_agent.py: %s", tostring(stderr))
      return done(nil, "grandma's task helper failed, see the Hammerspoon console")
    end
    if value.error then return done(nil, value.error) end
    done(value)
  end, full)
  running[task] = true
  if not task:start() then running[task] = nil done(nil, "couldn't start grandma's task helper") end
end

-- Opens the session in Terminal, where it can be watched and answered like any Claude Code session.
local function attach(id)
  local cl = claude()
  if not cl then return end
  hs.osascript.applescript(string.format('tell application "Terminal"\nactivate\ndo script "%s attach %s"\nend tell',
    cl, id))
end

local NOTE = { blocked = "Needs you", done = "Done", failed = "Failed", stopped = "Stopped", working = "Working" }

-- Shows what she said about task `id` in the panel. While it is open, Fn+Control replies to her.
function M.show(id)
  local t = find(id)
  if not t then return end
  local state = readState(id) or {}
  local text = core.taskReport(state, lastText(id))
  if state.worktreeBranch then
    text = text .. "\n\nBranch " .. state.worktreeBranch .. " in " .. tostring(state.worktreePath)
  end
  local hint = (t.state == "working") and "Still working. Return opens it in Terminal."
    or "Hold Fn+Control to reply. Return opens it in Terminal."
  awaiting = t.state ~= "working" and id or nil
  local gist = t.state == "blocked" and (state.needs or state.detail) or state.detail
  overlay.showPanel({ gist = gist or t.title,
                      body = t.title .. "\n\n" .. (text ~= "" and text or "Nothing yet.") .. "\n\n" .. hint },
    NOTE[t.state] or t.state, t.state == "failed", {
      onReturn = function() awaiting = nil attach(id) end,
      onEscape = function() if awaiting == id then awaiting = nil end end,
    })
end

local function notify(t, event, state)
  local title = ({ blocked = "Grandma needs you", done = "Grandma finished", failed = "Grandma's task failed" })[event]
  if not title then return end
  sounds.play(({ blocked = "ask", done = "done", failed = "error" })[event])
  local body = event == "blocked" and (state.needs or state.detail) or state.detail
  hs.notify.new(function() M.show(t.id) end, {
    title = title, subTitle = t.title, informativeText = core.unmark(body or ""), withdrawAfter = 0,
  }):send()
end

local function anyWorking()
  for _, t in ipairs(list) do if t.state == "working" then return true end end
  return false
end

local function stopPolling()
  if poller then poller:stop() poller = nil end
end

local function check()
  local now = os.time()
  local changed = false
  for _, t in ipairs(list) do
    if t.state == "working" then
      local state = readState(t.id)
      local event = core.taskEvent(t.state, state)
      if event then
        t.state = event
        changed = true
        notify(t, event, state)
      elseif now - (t.resumedAt or t.startedAt or now) > cfg.taskMinutes * 60 then
        log("stopping %s after %d minutes", t.id, cfg.taskMinutes)
        t.state = "stopped"
        changed = true
        agent({ "stop", "--id", t.id }, function() end)
        hs.notify.new(function() M.show(t.id) end, { title = "Grandma stopped a task", subTitle = t.title,
          informativeText = "Still working after " .. cfg.taskMinutes .. " minutes. Open it to carry on.",
          withdrawAfter = 0 }):send()
      end
    end
  end
  if changed then save() end
  if not anyWorking() then stopPolling() end
end

local function startPolling()
  if not poller then poller = hs.timer.doEvery(POLL, check) end
end

function M.setup(config)
  cfg = config
  load()
  if anyWorking() then startPolling() end
end

function M.enabled()
  return cfg ~= nil and cfg.backgroundTasks == true and cfg.screenAssist == true
end

function M.teardown()
  stopPolling()
  awaiting = nil
end

-- The task whose panel is open, so the next Fn+Control is a reply to her.
function M.awaiting() return awaiting end

local function workingCount()
  local n = 0
  for _, t in ipairs(list) do if t.state == "working" then n = n + 1 end end
  return n
end

-- Starts `task` (core.taskFrom) asked as `question`; `done(err)` once it is running or not.
function M.start(task, question, done)
  if workingCount() >= cfg.maxTasks then
    return done(string.format("She already has %d tasks going. Stop one from the menu, or wait.", cfg.maxTasks))
  end
  local stamp = os.date("%m%d-%H%M%S")
  local folder = dir() .. "/" .. stamp
  hs.fs.mkdir(core.supportDir())
  hs.fs.mkdir(dir())
  hs.fs.mkdir(folder)
  local f = io.open(folder .. "/task.json", "w")
  if not f then return done("couldn't write the task") end
  f:write(hs.json.encode({ question = question, title = task.title, goal = task.goal, target = task.target,
                           memory = task.memory, edits = task.edits, stamp = stamp }))
  f:close()
  local args = { "start", "--task", folder .. "/task.json", "--workspace", expand(cfg.taskWorkspace),
                 "--out-dir", folder }
  if cfg.grandmaHome then
    table.insert(args, "--grandma-home")
    table.insert(args, expand(cfg.grandmaHome))
  end
  if cfg.taskModel then
    table.insert(args, "--model")
    table.insert(args, cfg.taskModel)
  end
  agent(args, function(result, err)
    if not result then return done(err) end
    table.insert(list, 1, { id = result.id, title = task.title, state = "working", startedAt = os.time(),
                            memory = result.memory, edits = result.edits, dir = folder })
    while #list > 30 do table.remove(list) end
    save()
    startPolling()
    log("started %s: %s (%s)", result.id, task.title, result.cwd)
    done(nil, result)
  end)
end

-- Sends `text` to task `id` as the user's answer; she picks up from where she stopped.
function M.reply(id, text, done)
  local t = find(id)
  if not t then return done("that task is gone") end
  agent({ "reply", "--id", id, "--text", text }, function(result, err)
    if not result then return done(err) end
    t.state, t.resumedAt = "working", os.time()
    if result.id ~= id then t.id = result.id end
    save()
    startPolling()
    done(nil)
  end)
end

local function stopTask(t)
  agent({ "stop", "--id", t.id }, function(_, err)
    if err then return hs.alert.show("Couldn't stop it: " .. err, 3) end
    t.state = "stopped"
    save()
  end)
end

-- Menu items: each recent task with what can be done with it.
function M.menuItems()
  if not M.enabled() then return {} end
  local items = {}
  for i, t in ipairs(list) do
    if i > SHOWN then break end
    local sub = { { title = "Show", fn = function() M.show(t.id) end },
                  { title = "Open in Terminal", fn = function() attach(t.id) end } }
    if t.state == "working" then table.insert(sub, { title = "Stop", fn = function() stopTask(t) end }) end
    table.insert(sub, { title = "Remove from list", fn = function()
      for j, other in ipairs(list) do if other == t then table.remove(list, j) break end end
      save()
    end })
    table.insert(items, { title = string.format("🧶 %s: %s", t.title, (NOTE[t.state] or t.state):lower()), menu = sub })
  end
  if #items > 0 then table.insert(items, 1, { title = "Grandma's tasks", disabled = true }) end
  return items
end

return M
