-- Picker adapter (round 3, Q1). Views describe what to pick; a backend module
-- (`codereader.pickers.<name>`) decides how. v1 ships telescope only.
--
-- spec = {
--   title: string,
--   items: any[],
--   entry: fn(item) -> { display: string, ordinal: string },
--   preview?: fn(item) -> { lines: string[], filetype?: string },
--   on_select: fn(item),
--   actions?: { { key: string, desc: string, fn: fn(item) } },
-- }

local Config = require("codereader.config")
local util = require("codereader.util")

local M = {}

function M.pick(spec)
  local name = Config.get().picker
  local ok, impl = pcall(require, "codereader.pickers." .. name)
  if not ok then
    util.error(("unknown picker %q"):format(name))
    return
  end
  if not impl.available() then
    util.error(("picker %q is not installed"):format(name))
    return
  end
  if #spec.items == 0 then
    util.notify(spec.empty or ("nothing to pick: " .. spec.title))
    return
  end
  impl.pick(spec)
end

return M
