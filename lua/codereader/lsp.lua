-- Turn LSP jumps into Stops (round 3, Q1).
--
-- Neovim 0.12's `vim.lsp.buf.definition` moves the cursor itself (no
-- `show_document`), and references go through the quickfix list or a picker,
-- so no single function sees every jump. Instead:
--   1. `LspRequest` "pending" for a watched method -> remember where we are;
--   2. the first time the cursor then lands somewhere else in a code buffer,
--      that is the target -> push the jump onto the Trail;
--   3. if the cursor is still in place 300 ms after the reply (no result, or
--      a cancelled picker), forget it. In a quickfix list or picker we keep
--      waiting (up to a minute) for the Reader to choose.

local Trail = require("codereader.trail")
local util = require("codereader.util")

local M = {}

M.WATCH = {
  ["textDocument/definition"] = "definition",
  ["textDocument/declaration"] = "declaration",
  ["textDocument/typeDefinition"] = "type_definition",
  ["textDocument/implementation"] = "implementation",
  ["textDocument/references"] = "references",
}

local TIMEOUT_MS = 60000
local SETTLE_MS = 300

M.pending = nil

local function same(a, b)
  return a.path == b.path and a.line == b.line
end

--- See the module comment. `settled`: the reply has arrived and had time to
--- move the cursor.
function M.check(settled)
  local p = M.pending
  if not p then
    return
  end
  if vim.uv.now() - p.t > TIMEOUT_MS then
    M.pending = nil
    return
  end
  local here = util.here()
  if not here then
    return -- in a quickfix list or picker: wait for the choice
  end
  if same(here, p.from) then
    if settled then
      M.pending = nil
    end
    return
  end
  M.pending = nil
  Trail.push(p.from, here, p.via)
end

function M.on_request(request)
  local via = request and M.WATCH[request.method]
  if not via then
    return
  end
  if request.type == "pending" then
    local here = util.here()
    if here then
      M.pending = { from = here, via = via, t = vim.uv.now() }
    end
  else -- complete / cancel
    local p = M.pending
    vim.defer_fn(function()
      if M.pending == p then
        M.check(true)
      end
    end, SETTLE_MS)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("codereader_lsp", { clear = true })
  vim.api.nvim_create_autocmd("LspRequest", {
    group = group,
    callback = function(ev)
      M.on_request(ev.data and ev.data.request)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    callback = function()
      if M.pending then
        -- Scheduled: on BufEnter the cursor is not yet at the target.
        vim.schedule(function()
          M.check(false)
        end)
      end
    end,
  })
end

return M
