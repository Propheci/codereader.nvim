-- The active Trail of this Neovim instance (round 5, Q2: one per instance).
-- The id lives here, in memory; the Trail itself lives in the binary's store.
-- The first Stop with no active Trail starts an unnamed one (round 2, Q3).

local Symbols = require("codereader.symbols")
local backend = require("codereader.backend")
local util = require("codereader.util")

local M = {}

M.active = nil -- { id, name }
local listeners = {}

function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

local function fire()
  for _, fn in ipairs(listeners) do
    pcall(fn)
  end
end

function M.set_active(id, name)
  M.active = id and { id = id, name = name } or nil
  fire()
end

--- `--path=..`/`--from-path=..` style flags for a location from `util.here`.
local function loc_args(args, prefix, loc)
  local p = prefix and ("--" .. prefix .. "-") or "--"
  vim.list_extend(args, {
    p .. "path=" .. loc.path,
    p .. "line=" .. loc.line,
    p .. "col=" .. loc.col,
    p .. "snapshot=" .. loc.text,
  })
  local sym = loc.bufnr and Symbols.at(loc.bufnr, loc.line)
  for _, name in ipairs(sym and sym.symbol or {}) do
    args[#args + 1] = p .. "symbol=" .. name
  end
end

--- Start a Trail (unnamed if `name` is nil) and make it active.
function M.new(name)
  local args = { "trail", "new" }
  if name and name ~= "" then
    vim.list_extend(args, { "--", name })
  end
  local ok, data = backend.call(args)
  if not ok then
    util.error(data)
    return nil
  end
  M.set_active(data.id, data.name)
  return data
end

local function ensure()
  return M.active or M.new(nil)
end

--- Record a move to `to` (from `util.here`). With `from`, it is a jump.
function M.push(from, to, via)
  local t = ensure()
  if not t then
    return nil
  end
  local args = { "trail", "push", t.id, "--via=" .. (via or "manual") }
  loc_args(args, nil, to)
  if from then
    loc_args(args, "from", from)
  end
  local ok, data = backend.call(args)
  if not ok then
    util.error(data)
    return nil
  end
  fire()
  return data
end

--- Add a Stop at the cursor of `win`.
function M.add_stop(win)
  local here = util.here(win)
  if not here then
    util.error("put the cursor in a file first")
    return
  end
  local stop = M.push(nil, here, "manual")
  if stop then
    util.notify(("Stop %s added to %s"):format(stop.id, M.active.name or "the unnamed Trail"))
  end
  return stop
end

local function move(args, win)
  if not M.active then
    util.error("no active Trail: add a Stop, or pick a Trail")
    return
  end
  local ok, stop = backend.call(args)
  if not ok then
    util.notify(stop, vim.log.levels.WARN)
    return
  end
  util.jump(stop.abs_path, stop.line, stop.col, win)
  if stop.status == "lost" then
    util.notify(("Stop %s is Lost: its code was not found"):format(stop.id), vim.log.levels.WARN)
  end
  fire()
  return stop
end

function M.back(win)
  return M.active and move({ "trail", "back", M.active.id }, win) or move({}, win)
end

function M.forward(win)
  return M.active and move({ "trail", "forward", M.active.id }, win) or move({}, win)
end

function M.goto_stop(stop_id, win)
  return M.active and move({ "trail", "goto", M.active.id, stop_id }, win) or move({}, win)
end

--- The active Trail with every Stop re-found, or nil. Async with `cb`.
function M.show(cb)
  if not M.active then
    return cb(nil)
  end
  local id = M.active.id
  backend.call({ "trail", "show", id, "--resolve" }, {}, function(ok, data)
    if not ok then
      -- The Trail was deleted elsewhere: drop it rather than fail every refresh.
      if M.active and M.active.id == id then
        M.active = nil
      end
      return cb(nil)
    end
    if M.active and M.active.id == id then
      M.active.name = data.name
    end
    cb(data)
  end)
end

return M
