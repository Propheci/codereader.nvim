-- Copied from jenkins.nvim (see docs/adr/0002); adds left/right side splits.
--
-- Buffer: a thin wrapper over a read-only scratch buffer + its window. Owns the
-- render cycle (component tree -> lines + highlights) and the line->component
-- index used by cursor queries. Users never edit the buffer; they act via
-- keymaps that mutate state and trigger a re-render.

local Component = require("codereader.ui.component")
local Renderer = require("codereader.ui.renderer")

local ns = vim.api.nvim_create_namespace("codereader")

local Buffer = {}
Buffer.__index = Buffer

local function open_window(bufnr, kind, win_opts)
  kind = kind or "split"
  if kind == "current" then
    vim.api.nvim_win_set_buf(0, bufnr)
    return vim.api.nvim_get_current_win()
  elseif kind == "float" then
    local cols, rows = vim.o.columns, vim.o.lines
    local width = win_opts.width or math.floor(cols * 0.8)
    local height = win_opts.height or math.floor(rows * 0.8)
    return vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((rows - height) / 2),
      col = math.floor((cols - width) / 2),
      style = "minimal",
      border = win_opts.border or "rounded",
      title = win_opts.title,
      title_pos = win_opts.title and "center" or nil,
    })
  end
  local cmd = ({
    split = "botright split",
    vsplit = "botright vsplit",
    right = "botright vsplit",
    left = "topleft vsplit",
    tab = "tabnew",
  })[kind] or "botright split"
  vim.cmd(cmd)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  if kind == "split" and win_opts.height then
    vim.api.nvim_win_set_height(win, win_opts.height)
  end
  -- Side panels keep their width when other windows open or close.
  if (kind == "right" or kind == "left") and win_opts.width then
    vim.api.nvim_win_set_width(win, win_opts.width)
    vim.wo[win].winfixwidth = true
  end
  return win
end

--- Create a buffer-backed view.
--- opts: name, filetype, kind, win (width/height/border/title), mappings
--- (mode -> key -> fn(self)), render (self -> layout children), state, on_close.
function Buffer.create(opts)
  local self = setmetatable({
    opts = opts,
    state = opts.state or {},
    render_fn = opts.render,
    index = {},
  }, Buffer)

  self.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[self.bufnr].bufhidden = "wipe"
  vim.bo[self.bufnr].buftype = "nofile"
  vim.bo[self.bufnr].swapfile = false
  vim.bo[self.bufnr].filetype = opts.filetype or "codereader"
  pcall(vim.api.nvim_buf_set_name, self.bufnr, opts.name or ("codereader://" .. self.bufnr))

  self.win = open_window(self.bufnr, opts.kind, opts.win or {})
  vim.wo[self.win].wrap = false
  vim.wo[self.win].number = false
  vim.wo[self.win].relativenumber = false
  vim.wo[self.win].signcolumn = "no"
  vim.wo[self.win].cursorline = true

  self:set_mappings(opts.mappings or {})

  if opts.on_close then
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
      buffer = self.bufnr,
      once = true,
      callback = function()
        opts.on_close(self)
      end,
    })
  end

  if self.render_fn then
    self:render()
  end
  if opts.initialize then
    opts.initialize(self)
  end
  return self
end

function Buffer:set_mappings(mappings)
  for mode, keys in pairs(mappings) do
    for key, fn in pairs(keys) do
      vim.keymap.set(mode, key, function()
        fn(self)
      end, { buffer = self.bufnr, nowait = true, silent = true })
    end
  end
end

function Buffer:is_valid()
  return self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)
end

--- Run the render function (or explicit children), swap content, reapply
--- decorations. Cursor line is preserved across the swap.
function Buffer:render(children)
  if not self:is_valid() then
    return
  end
  children = children or (self.render_fn and self.render_fn(self)) or {}

  local out, index = Renderer.new(children):render()
  self.index = index

  local cursor = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_cursor(self.win) or { 1, 0 }

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, out.lines)
  -- Editable views (e.g. the form's string fields) stay modifiable; display-only
  -- views are locked so users act via keymaps, not raw edits.
  vim.bo[self.bufnr].modifiable = self.opts.modifiable == true

  vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
  for _, hl in ipairs(out.line_highlights) do
    vim.api.nvim_buf_set_extmark(self.bufnr, ns, hl.line, 0, {
      line_hl_group = hl.group,
      end_row = hl.line + 1,
    })
  end
  for _, hl in ipairs(out.highlights) do
    pcall(vim.api.nvim_buf_set_extmark, self.bufnr, ns, hl.line, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.group,
    })
  end

  if vim.api.nvim_win_is_valid(self.win) then
    local line = math.min(cursor[1], math.max(#out.lines, 1))
    pcall(vim.api.nvim_win_set_cursor, self.win, { line, cursor[2] })
  end
end

--- Append raw text lines (used by streaming output buffers). When `follow` is
--- truthy the cursor jumps to the new tail; otherwise the view stays put.
function Buffer:append(lines, follow)
  if not self:is_valid() then
    return
  end
  vim.bo[self.bufnr].modifiable = true
  local at = vim.api.nvim_buf_line_count(self.bufnr)
  if at == 1 and vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1] == "" then
    at = 0
  end
  vim.api.nvim_buf_set_lines(self.bufnr, at, -1, false, lines)
  vim.bo[self.bufnr].modifiable = false
  if follow then
    self:scroll_to_bottom()
  end
end

--- Move the cursor to the last line.
function Buffer:scroll_to_bottom()
  if vim.api.nvim_win_is_valid(self.win) then
    local total = vim.api.nvim_buf_line_count(self.bufnr)
    pcall(vim.api.nvim_win_set_cursor, self.win, { total, 0 })
  end
end

function Buffer:cursor_line()
  if not vim.api.nvim_win_is_valid(self.win) then
    return 1
  end
  return vim.api.nvim_win_get_cursor(self.win)[1]
end

--- Component on `line` (1-based), optionally the first ancestor matching `fn`.
function Buffer:component_on_line(line, fn)
  local node = self.index[line]
  if node and fn then
    return node:find_parent(fn)
  end
  return node
end

--- Component under the cursor (optionally filtered to a matching ancestor).
function Buffer:component_at_cursor(fn)
  return self:component_on_line(self:cursor_line(), fn)
end

--- Move the cursor to the first line whose component matches `fn`.
function Buffer:focus_component(fn)
  for line, node in pairs(self.index) do
    if node.find_parent and node:find_parent(fn) then
      pcall(vim.api.nvim_win_set_cursor, self.win, { line, 0 })
      return
    end
  end
end

function Buffer:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if self:is_valid() then
    pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
  end
end

Buffer.Component = Component

return Buffer
