-- Bridge to the `codereader` binary (see docs/adr/0002). Every call runs
-- `codereader --json <args>` and reads one envelope:
--   { schema_version, ok = true, data } or { schema_version, ok = false, error }.
-- This is the only module that knows the binary exists, so a later switch to a
-- persistent process only touches this file.
--
-- String values are always passed as `--flag=value`, so a value that starts
-- with `-` (a Note starting "- item", a code line "-- comment") is never read
-- as a flag.

local Config = require("codereader.config")

local M = {}

--- The payload version this plugin understands.
M.SCHEMA_VERSION = 1

function M.available()
  return vim.fn.executable(Config.get().binary) == 1
end

local function not_found()
  return ("codereader binary not found: %q (build it with `cargo build --release` in %s, or set require('codereader').setup{ binary = ... })"):format(
    Config.get().binary,
    Config.root
  )
end

function M.command(args)
  local cmd = { Config.get().binary }
  vim.list_extend(cmd, Config.global_args())
  vim.list_extend(cmd, args)
  return cmd
end

--- Parse a finished `vim.system` result. Returns `ok, data_or_error`.
function M.parse(result)
  local out = result.stdout or ""
  local ok, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    local err = vim.trim((result.stderr and result.stderr ~= "" and result.stderr) or out)
    return false, err ~= "" and err or ("codereader exited with code " .. tostring(result.code))
  end
  local found = decoded.schema_version
  if found ~= M.SCHEMA_VERSION then
    return false,
      ("codereader schema %s, but this plugin expects %s: %s"):format(
        tostring(found or "(none)"),
        M.SCHEMA_VERSION,
        (type(found) ~= "number" or found < M.SCHEMA_VERSION) and "rebuild the codereader binary"
          or "update codereader.nvim"
      )
  end
  if not decoded.ok then
    return false, decoded.error or "unknown error"
  end
  return true, decoded.data
end

--- Run `codereader <args>`. `opts.stdin` is a string to write to stdin.
--- With `cb(ok, data)` the call is async; without, it blocks and returns
--- `ok, data_or_error` (fine for user-triggered writes: a call takes ~10 ms).
function M.call(args, opts, cb)
  opts = opts or {}
  if not M.available() then
    if cb then
      vim.schedule(function()
        cb(false, not_found())
      end)
      return
    end
    return false, not_found()
  end
  local sys_opts = { text = true, cwd = opts.cwd or vim.fn.getcwd(), stdin = opts.stdin }
  if cb then
    vim.system(M.command(args), sys_opts, vim.schedule_wrap(function(result)
      cb(M.parse(result))
    end))
    return
  end
  return M.parse(vim.system(M.command(args), sys_opts):wait())
end

return M
