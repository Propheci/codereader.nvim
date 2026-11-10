-- Notes in code buffers: re-find them (Drift) and show them as a sign plus
-- dim virtual text (round 2, Q7). File Notes show on line 1. Orphans and
-- Project Notes have no place in a buffer; the Panel shows them.

local Config = require("codereader.config")
local Symbols = require("codereader.symbols")
local backend = require("codereader.backend")
local util = require("codereader.util")

local M = {}

local ns = vim.api.nvim_create_namespace("codereader_notes")
local ns_range = vim.api.nvim_create_namespace("codereader_note_ranges")

--- bufnr -> resolved Note views from the last refresh.
M.by_buf = {}
--- bufnr -> true when the buffer has Symbol Notes (send symbols up front).
local wants_symbols = {}
local listeners = {}
local virtual_text = nil

function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

local function fire(bufnr)
  for _, fn in ipairs(listeners) do
    pcall(fn, bufnr)
  end
end

function M.virtual_text_enabled()
  if virtual_text == nil then
    return Config.get().virtual_text
  end
  return virtual_text
end

function M.toggle_virtual_text()
  virtual_text = not M.virtual_text_enabled()
  for bufnr in pairs(M.by_buf) do
    M.decorate(bufnr)
  end
  util.notify("virtual text " .. (virtual_text and "on" or "off"))
end

--- Where a Note sits in the buffer now: 1-based start/end, or nil.
function M.lines_of(note)
  local r = note.resolution
  if not r or r.status == "orphan" then
    return nil
  end
  if note.kind == "file" then
    return 1, 1
  end
  return r.start_line, r.end_line
end

function M.decorate(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.by_buf[bufnr] = nil
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_range, 0, -1)
  local cfg = Config.get()
  local count = vim.api.nvim_buf_line_count(bufnr)
  for _, n in ipairs(M.by_buf[bufnr] or {}) do
    n._range = nil
    local s, e = M.lines_of(n)
    if s and s <= count then
      e = math.min(e or s, count)
      local drifted = n.resolution.status == "drifted"
      local sign = n.kind == "file" and cfg.signs.file or (drifted and cfg.signs.drifted or cfg.signs.note)
      local opts = { sign_text = sign, sign_hl_group = drifted and "CodeReaderDrifted" or "CodeReaderSign", priority = 20 }
      if M.virtual_text_enabled() then
        opts.virt_text = { { "  " .. sign .. " " .. (n.title ~= "" and n.title or "(empty note)"), drifted and "CodeReaderDriftedText" or "CodeReaderVirtText" } }
        opts.virt_text_pos = "eol"
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, s - 1, 0, opts)
      -- A second, invisible mark spans the whole range. It follows edits, so
      -- "the Note under the cursor" stays right until the next refresh.
      local last = vim.api.nvim_buf_get_lines(bufnr, e - 1, e, false)[1] or ""
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_range, s - 1, 0, { end_row = e - 1, end_col = #last })
      if ok then
        n._range = id
      end
    end
  end
end

--- Re-find every Note in the buffer, using the buffer text (which may be
--- unsaved) and its symbols, then redraw. `cb(notes)` runs after.
function M.refresh(bufnr, cb)
  if not util.is_code_buf(bufnr) then
    return
  end
  local path = util.buf_path(bufnr)
  local function run(with_symbols)
    local input = { text = util.buf_text(bufnr) }
    if with_symbols then
      local syms = Symbols.all(bufnr)
      if #syms > 0 then
        input.symbols = syms
      end
    end
    backend.call({ "resolve", "--path=" .. path, "--stdin" }, { stdin = vim.json.encode(input) }, function(ok, data)
      if not ok then
        util.error(data)
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local has_symbol = vim.iter(data):any(function(n)
        return n.kind == "symbol"
      end)
      wants_symbols[bufnr] = has_symbol
      if has_symbol and not with_symbols then
        return run(true)
      end
      M.by_buf[bufnr] = data
      M.decorate(bufnr)
      fire(bufnr)
      if cb then
        cb(data)
      end
    end)
  end
  run(wants_symbols[bufnr])
end

--- Refresh every buffer that has been decorated (after a Note changes).
function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and util.is_code_buf(bufnr) and M.by_buf[bufnr] then
      M.refresh(bufnr)
    end
  end
end

function M.forget(bufnr)
  M.by_buf[bufnr] = nil
  wants_symbols[bufnr] = nil
end

--- The Note under the cursor: the smallest range containing the line; a File
--- Note only on line 1 when nothing else matches.
function M.at_cursor(win)
  win = win or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local best, best_span, file_note
  for _, n in ipairs(M.by_buf[bufnr] or {}) do
    if n.kind == "file" then
      file_note = file_note or n
    elseif n._range then
      local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_range, n._range, { details = true })
      local s, e = mark[1], mark[3] and mark[3].end_row
      if s and e and s <= row and row <= e and (not best or e - s < best_span) then
        best, best_span = n, e - s
      end
    end
  end
  if best then
    return best
  end
  if row == 0 then
    return file_note
  end
end

return M
