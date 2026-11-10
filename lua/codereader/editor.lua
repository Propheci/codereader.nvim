-- The Note float: a Markdown buffer in a centered float. `:w` saves; closing
-- the float (or leaving it) also saves (round 3, Q5). An unchanged body is
-- never written.

local Config = require("codereader.config")

local M = {}

local function normalize(s)
  return (s:gsub("%s+$", ""))
end

--- opts: { title, body, id?, insert?, on_save = fn(body) }
--- `on_save` runs at most once per distinct body.
function M.open(opts)
  local cfg = Config.get().float
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "codereader://note/" .. (opts.id or ("new-" .. buf)))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.body or "", "\n", { plain = true }))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modified = false

  local width = math.min(cfg.width, vim.o.columns - 4)
  local height = math.min(cfg.height, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = cfg.border,
    title = " " .. (opts.title or "Note") .. " ",
    title_pos = "center",
    footer = " first line = title · #tags · :w or q saves ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local saved = normalize(opts.body or "")
  local function save()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local body = normalize(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.bo[buf].modified = false
    if body ~= saved then
      saved = body
      opts.on_save(body)
    end
  end

  local group = vim.api.nvim_create_augroup("codereader_editor_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buf, callback = save })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      save()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- A float left behind is easy to lose; leaving it closes (and saves) it.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end)
    end,
  })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })

  if opts.insert then
    vim.cmd.startinsert()
  end
  return { buf = buf, win = win }
end

--- A read-only float with `lines` (used by the Panel's `?` help).
function M.show(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = Config.get().float.border,
    title = " " .. title .. " ",
    title_pos = "center",
  })
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true, silent = true })
  end
  return { buf = buf, win = win }
end

return M
