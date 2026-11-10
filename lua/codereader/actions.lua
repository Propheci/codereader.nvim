-- Note operations shared by commands, keymaps, pickers and the Panel. Each
-- takes an explicit context so the Panel can act on the code window's cursor
-- (round 6, Q4) rather than its own.

local Editor = require("codereader.editor")
local Notes = require("codereader.notes")
local Symbols = require("codereader.symbols")
local backend = require("codereader.backend")
local util = require("codereader.util")

local M = {}

--- A Note chosen in the Orphans picker (or with `move`), waiting for
--- `:CodeReader attach` at its new place (round 5, Q5).
M.pending_attach = nil

local function changed()
  Notes.refresh_all()
  local ok, Panel = pcall(require, "codereader.panel")
  if ok then
    Panel.reload()
  end
end
M.changed = changed

local function code_buf(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not util.is_code_buf(buf) then
    return nil
  end
  return buf
end

--- Anchor flags for a context, following round 3 Q5:
---   ctx.kind = "project"            -> Project Anchor
---   ctx.kind = "file"               -> File Anchor on the window's file
---   ctx.range = { s, e }            -> Range Anchor
---   otherwise, cursor in a symbol   -> Symbol Anchor on the enclosing symbol
---   otherwise                       -> Range Anchor on the cursor line
--- Returns args, label, bufnr (nil for project), or nil + error.
function M.anchor_for(ctx)
  ctx = ctx or {}
  if ctx.kind == "project" then
    return { "--kind=project" }, "Project", nil
  end
  local win = ctx.win or vim.api.nvim_get_current_win()
  local buf = code_buf(win)
  if not buf then
    return nil, "put the cursor in a file first"
  end
  local path = util.buf_path(buf)
  local args = { "--path=" .. path, "--text-stdin" }
  if ctx.kind == "file" then
    vim.list_extend(args, { "--kind=file" })
    return args, util.short_path(path), buf
  end
  if ctx.range then
    local s, e = ctx.range[1], ctx.range[2]
    vim.list_extend(args, { "--kind=range", "--start=" .. s, "--end=" .. e })
    return args, ("%s:%d-%d"):format(util.short_path(path), s, e), buf
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local sym = Symbols.at(buf, line)
  if sym then
    vim.list_extend(args, { "--kind=symbol", "--start=" .. sym.start_line, "--end=" .. sym.end_line })
    for _, name in ipairs(sym.symbol) do
      args[#args + 1] = "--symbol=" .. name
    end
    return args, table.concat(sym.symbol, " > "), buf
  end
  vim.list_extend(args, { "--kind=range", "--start=" .. line, "--end=" .. line })
  return args, ("%s:%d"):format(util.short_path(path), line), buf
end

local function stdin_for(buf)
  return buf and util.buf_text(buf) or ""
end

--- Write a new Note from the float. The first save creates it; later saves
--- of the same float edit it.
function M.add_note(ctx)
  local args, label, buf = M.anchor_for(ctx)
  if not args then
    util.error(label)
    return
  end
  local id
  return Editor.open({
    title = "New Note · " .. label,
    body = "",
    insert = true,
    on_save = function(body)
      local ok, data
      if id then
        ok, data = backend.call({ "note", "edit", id, "--message=" .. body })
      elseif body ~= "" then
        local full = { "note", "add" }
        vim.list_extend(full, args)
        full[#full + 1] = "--message=" .. body
        ok, data = backend.call(full, { stdin = stdin_for(buf) })
        if ok then
          id = data.id
        end
      else
        return
      end
      if not ok then
        util.error(data)
        return
      end
      changed()
    end,
  })
end

function M.add_file_note(ctx)
  return M.add_note(vim.tbl_extend("force", ctx or {}, { kind = "file" }))
end

function M.add_project_note()
  return M.add_note({ kind = "project" })
end

--- Open a Note in the float; saving edits it.
function M.edit(note)
  if not note then
    util.error("no Note here")
    return
  end
  local title = note.title ~= "" and note.title or note.id
  return Editor.open({
    id = note.id,
    title = util.truncate(title, 50),
    body = note.body,
    on_save = function(body)
      if body == "" then
        util.notify("empty Note not saved (use delete to remove it)", vim.log.levels.WARN)
        return
      end
      local ok, data = backend.call({ "note", "edit", note.id, "--message=" .. body })
      if not ok then
        util.error(data)
        return
      end
      changed()
    end,
  })
end

function M.delete(note, opts)
  if not note then
    util.error("no Note here")
    return false
  end
  opts = opts or {}
  if not opts.force then
    local title = note.title ~= "" and note.title or note.id
    if vim.fn.confirm(("Delete Note %q?"):format(util.truncate(title, 50)), "&Yes\n&No", 2) ~= 1 then
      return false
    end
  end
  local ok, data = backend.call({ "note", "delete", note.id })
  if not ok then
    util.error(data)
    return false
  end
  changed()
  return true
end

--- Accept the code under a Drifted Note as what it is about.
function M.confirm(note)
  if not note then
    util.error("no Note here")
    return false
  end
  local args, stdin = { "note", "confirm", note.id }, nil
  local buf = note.abs_path and util.find_buf(note.abs_path)
  if buf then
    args[#args + 1] = "--text-stdin"
    stdin = util.buf_text(buf)
  end
  local ok, data = backend.call(args, { stdin = stdin })
  if not ok then
    util.error(data)
    return false
  end
  util.notify("confirmed: " .. util.truncate(data.title, 50))
  changed()
  return true
end

--- Move `note` (default: the pending one) to the place `ctx` points at.
function M.attach(ctx, note)
  ctx = ctx or {}
  note = note or M.pending_attach
  if not note then
    util.error("pick a Note first: Orphans picker, or `:CodeReader move` on a Note")
    return false
  end
  local args, label, buf = M.anchor_for(ctx)
  if not args then
    util.error(label)
    return false
  end
  local full = { "note", "attach", note.id }
  vim.list_extend(full, args)
  local ok, data = backend.call(full, { stdin = stdin_for(buf) })
  if not ok then
    util.error(data)
    return false
  end
  M.pending_attach = nil
  util.notify(("attached %q to %s"):format(util.truncate(data.title, 40), label))
  changed()
  return true
end

function M.mark_for_attach(note)
  if not note then
    util.error("no Note here")
    return
  end
  M.pending_attach = note
  util.notify(("%q selected: go to the new place and run :CodeReader attach"):format(util.truncate(note.title, 40)))
end

--- Jump to a Note's Anchor in `win`.
function M.jump(note, win)
  if not note.abs_path then
    return M.edit(note) -- a Project Note has no place: open it instead
  end
  local r = note.resolution or {}
  if r.status == "orphan" then
    util.notify("this Note is an Orphan; showing where it used to be", vim.log.levels.WARN)
  end
  util.jump(note.abs_path, r.start_line or note.start_line or 1, 1, win)
end

function M.at_cursor()
  return Notes.at_cursor()
end

return M
