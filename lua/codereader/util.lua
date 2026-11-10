local M = {}

function M.notify(msg, level)
  vim.notify("codereader: " .. msg, level or vim.log.levels.INFO)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- A normal file buffer (not a panel, picker, quickfix or terminal).
function M.is_code_buf(bufnr)
  return bufnr
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

--- Absolute path with symlinks resolved, so it compares equal to the paths
--- the binary returns (macOS: /var -> /private/var).
function M.real(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(abs) or abs
end

function M.buf_path(bufnr)
  return M.real(vim.api.nvim_buf_get_name(bufnr))
end

--- The loaded buffer showing `path`, or nil.
function M.find_buf(path)
  local want = M.real(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and M.is_code_buf(b) and M.buf_path(b) == want then
      return b
    end
  end
end

function M.buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- The cursor location in `win` (default: current), or nil outside code.
function M.here(win)
  win = (win and win ~= 0) and win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.is_code_buf(buf) then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(win)
  return {
    win = win,
    bufnr = buf,
    path = M.buf_path(buf),
    line = pos[1],
    col = pos[2] + 1,
    text = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1] or "",
  }
end

--- Open `path` at `line`/`col` (1-based) in `win` (default: current).
function M.jump(path, line, col, win)
  win = (win and vim.api.nvim_win_is_valid(win)) and win or vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
    if M.buf_path(vim.api.nvim_win_get_buf(win)) ~= M.real(path) then
      vim.cmd.edit(vim.fn.fnameescape(path))
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local last = vim.api.nvim_buf_line_count(buf)
    local l = math.max(1, math.min(line or 1, last))
    pcall(vim.api.nvim_win_set_cursor, win, { l, math.max((col or 1) - 1, 0) })
    vim.cmd("normal! zv")
  end)
end

--- `src/very/deep/file.rs` -> `deep/file.rs`.
function M.short_path(path, keep)
  keep = keep or 2
  local rel = vim.fn.fnamemodify(path, ":~:.")
  local parts = vim.split(rel, "/", { plain = true })
  if #parts <= keep then
    return rel
  end
  return table.concat(vim.list_slice(parts, #parts - keep + 1), "/")
end

function M.truncate(s, n)
  s = s or ""
  if vim.fn.strchars(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

return M
