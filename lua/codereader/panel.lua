-- The Panel: the home screen (round 6). One Neogit-style buffer with
-- collapsible sections, in a side split that follows the code window:
--
--   codereader  my-repo-1a2b3c4d
--   Trail: login flow · 2 Drifted · 1 Orphan
--
--   ▸ Project Notes (2)
--   ▾ Trail: login flow (5)
--   ▾ Notes here: src/auth.rs (3)
--   ▾ Needs attention (3)
--
--   a add · e edit · s stop · [ ] trail · t trails · / find · ? help
--
-- Actions that need a code location use the cursor of the last code window.

local Actions = require("codereader.actions")
local Buffer = require("codereader.ui.buffer")
local C = require("codereader.ui.component")
local Config = require("codereader.config")
local Editor = require("codereader.editor")
local Notes = require("codereader.notes")
local Trail = require("codereader.trail")
local backend = require("codereader.backend")
local util = require("codereader.util")

local row, text = C.row, C.text

local M = {}

M.view = nil
M.code_win = nil
M.folds = { project = true, trail = false, here = false, attention = false }
M.data = { project = nil, notes = nil, trail = nil, error = nil }

function M.is_open()
  return M.view ~= nil and M.view:is_valid() and vim.api.nvim_win_is_valid(M.view.win)
end

--- The window the Panel acts on: the last code window, else any code window.
function M.code_window()
  if M.code_win and vim.api.nvim_win_is_valid(M.code_win) and util.is_code_buf(vim.api.nvim_win_get_buf(M.code_win)) then
    return M.code_win
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if util.is_code_buf(vim.api.nvim_win_get_buf(w)) then
      M.code_win = w
      return w
    end
  end
end

-- Rendering ------------------------------------------------------------------

local function note_lines(n)
  local r = n.resolution or {}
  return r.start_line or n.start_line, r.end_line or n.end_line or r.start_line or n.start_line
end

--- A Note in the same file within 3 lines of the Stop (round 5, Q6).
local function note_near(stop, notes)
  for _, n in ipairs(notes or {}) do
    if n.abs_path == stop.abs_path then
      local s, e = note_lines(n)
      if s and s - 3 <= stop.line and stop.line <= e + 3 then
        return true
      end
    end
  end
  return false
end

local function section(id, title, count, items, empty_hint)
  local folded = M.folds[id]
  local out = {
    row.tag({ kind = "section", id = id })({
      text.highlight("CodeReaderSection")((folded and "▸ " or "▾ ") .. title),
      text.highlight("CodeReaderMuted")(count and ("  (" .. count .. ")") or ""),
    }),
  }
  if not folded then
    if #items == 0 and empty_hint then
      out[#out + 1] = row.tag({ kind = "hint", section = id })({ text.highlight("CodeReaderMuted")("    " .. empty_hint) })
    end
    vim.list_extend(out, items)
  end
  out[#out + 1] = C.EmptyLine
  return out
end

local function note_row(n, sec, label)
  local status = (n.resolution or {}).status
  local icon, hl = "●", "CodeReaderSign"
  if n.kind == "file" then
    icon = "▤"
  elseif n.kind == "project" then
    icon = "◆"
  end
  if status == "drifted" then
    icon, hl = "◐", "CodeReaderDrifted"
  elseif status == "orphan" then
    icon, hl = "✗", "CodeReaderOrphan"
  end
  local title = n.title ~= "" and n.title or "(empty note)"
  local parts = { text("  "), text.highlight(hl)(icon .. " ") }
  if label then
    parts[#parts + 1] = text.highlight("CodeReaderMuted")(label .. "  ")
  end
  parts[#parts + 1] = text(title)
  return row.tag({ kind = "note", note = n, section = sec })(parts)
end

local function stop_rows(trail, notes)
  local children = {}
  for _, s in ipairs(trail.stops or {}) do
    local p = s.parent or "_root"
    children[p] = children[p] or {}
    table.insert(children[p], s)
  end
  local rows = {}
  local function walk(parent, depth)
    for _, s in ipairs(children[parent] or {}) do
      local current = trail.current == s.id
      local label = (s.symbol and #s.symbol > 0) and table.concat(s.symbol, " > ")
        or (util.short_path(s.abs_path, 1) .. ":" .. s.line)
      local parts = {
        text.highlight("CodeReaderCurrent")(current and "▶ " or "  "),
        text(string.rep("  ", depth)),
        text.highlight("CodeReaderNear")(note_near(s, notes) and "● " or "  "),
        text.highlight(current and "CodeReaderCurrent" or "Normal")(label),
        text.highlight("CodeReaderMuted")("  " .. util.truncate(vim.trim(s.snapshot or ""), 32)),
      }
      if s.status == "lost" then
        parts[#parts + 1] = text.highlight("CodeReaderLost")("  [lost]")
      end
      rows[#rows + 1] = row.tag({ kind = "stop", stop = s, section = "trail" })(parts)
      walk(s.id, depth + 1)
    end
  end
  walk("_root", 0)
  return rows
end

local function here_notes()
  local win = M.code_window()
  local buf = win and vim.api.nvim_win_get_buf(win)
  if not buf then
    return nil, {}
  end
  local path = util.buf_path(buf)
  local list = Notes.by_buf[buf]
  if not list then
    list = vim.tbl_filter(function(n)
      return n.abs_path == path
    end, M.data.notes or {})
  end
  list = vim.tbl_filter(function(n)
    return (n.resolution or {}).status ~= "orphan"
  end, list)
  table.sort(list, function(a, b)
    if (a.kind == "file") ~= (b.kind == "file") then
      return a.kind == "file" -- File Notes first (round 6 follow-up)
    end
    return (note_lines(a) or 0) < (note_lines(b) or 0)
  end)
  return path, list
end

local function render()
  local d = M.data
  local notes = d.notes or {}
  local drifted, orphans, project = {}, {}, {}
  for _, n in ipairs(notes) do
    local st = (n.resolution or {}).status
    if st == "drifted" then
      drifted[#drifted + 1] = n
    elseif st == "orphan" then
      orphans[#orphans + 1] = n
    end
    if n.kind == "project" then
      project[#project + 1] = n
    end
  end
  local trail_name = Trail.active and (Trail.active.name or "(unnamed)") or nil

  local out = {
    row({
      text.highlight("CodeReaderTitle")("codereader"),
      text.highlight("CodeReaderMuted")("  " .. (d.project and d.project.name or "")),
    }),
    row({
      text.highlight("CodeReaderMuted")("Trail: "),
      text(trail_name or "none"),
      text.highlight(#drifted > 0 and "CodeReaderDrifted" or "CodeReaderMuted")(("  · %d Drifted"):format(#drifted)),
      text.highlight(#orphans > 0 and "CodeReaderOrphan" or "CodeReaderMuted")((" · %d Orphan"):format(#orphans)),
    }),
  }
  if d.error then
    out[#out + 1] = row({ text.highlight("CodeReaderLost")(d.error) })
  end
  out[#out + 1] = C.EmptyLine

  local project_rows = vim.tbl_map(function(n)
    return note_row(n, "project")
  end, project)
  vim.list_extend(out, section("project", "Project Notes", #project, project_rows, "P adds a Note about the whole Project"))

  local trail_rows = d.trail and stop_rows(d.trail, notes) or {}
  vim.list_extend(
    out,
    section(
      "trail",
      "Trail: " .. (trail_name or "none"),
      d.trail and #d.trail.stops or nil,
      trail_rows,
      Trail.active and "no Stops yet: s adds one, LSP jumps add more" or "s adds a Stop and starts a Trail · t picks one"
    )
  )

  local path, here = here_notes()
  local here_rows = vim.tbl_map(function(n)
    local label = n.kind ~= "file" and ("%4s"):format(note_lines(n) or "?") or nil
    return note_row(n, "here", label)
  end, here)
  vim.list_extend(
    out,
    section(
      "here",
      "Notes here" .. (path and (": " .. util.short_path(path)) or ""),
      #here,
      here_rows,
      path and "a adds a Note at the code cursor" or "open a file to see its Notes"
    )
  )

  local attention = vim.list_extend(vim.list_slice(drifted), orphans)
  local attention_rows = vim.tbl_map(function(n)
    local where = n.kind == "project" and "(project)" or util.short_path(n.abs_path or n.path or "", 1)
    local s = note_lines(n)
    if s and n.resolution.status ~= "orphan" then
      where = where .. ":" .. s
    end
    return note_row(n, "attention", where)
  end, attention)
  vim.list_extend(out, section("attention", "Needs attention", #attention, attention_rows, "nothing Drifted or Orphaned"))

  out[#out + 1] = row({
    text.highlight("CodeReaderKey")("a"), text.highlight("CodeReaderMuted")(" add · "),
    text.highlight("CodeReaderKey")("e"), text.highlight("CodeReaderMuted")(" edit · "),
    text.highlight("CodeReaderKey")("s"), text.highlight("CodeReaderMuted")(" stop · "),
    text.highlight("CodeReaderKey")("[ ]"), text.highlight("CodeReaderMuted")(" trail · "),
    text.highlight("CodeReaderKey")("/"), text.highlight("CodeReaderMuted")(" find · "),
    text.highlight("CodeReaderKey")("?"), text.highlight("CodeReaderMuted")(" help"),
  })
  return out
end

function M.render()
  if M.is_open() then
    M.view:render()
  end
end

-- Data -------------------------------------------------------------------------

function M.reload_trail()
  if not M.is_open() then
    return
  end
  Trail.show(function(t)
    M.data.trail = t
    M.render()
  end)
end

--- Fetch everything the Panel shows (async), re-rendering as each part lands.
function M.reload()
  if not M.is_open() then
    return
  end
  if not M.data.project then
    backend.call({ "project" }, {}, function(ok, p)
      if ok then
        M.data.project = p
        M.render()
      end
    end)
  end
  backend.call({ "note", "list", "--resolve" }, {}, function(ok, notes)
    if ok then
      M.data.notes, M.data.error = notes, nil
    else
      M.data.error = notes
    end
    M.render()
  end)
  M.reload_trail()
end

-- Keys -------------------------------------------------------------------------

M.KEYS = {
  { "<CR>", "open the item: jump to a Note or Stop, fold a section" },
  { "<Tab>", "fold or unfold the section" },
  { "a", "add a Note at the code cursor (Symbol, else Range)" },
  { "A", "add a File Note for the code window's file" },
  { "P", "add a Project Note" },
  { "e", "edit the Note" },
  { "d", "delete the Note" },
  { "c", "confirm a Drifted Note" },
  { "m", "move (attach) the Note to the code cursor" },
  { "s", "add a Stop at the code cursor" },
  { "[ / ]", "go back / forward on the Trail" },
  { "t", "pick the active Trail" },
  { "T", "start a new named Trail" },
  { "/", "find a Note (all Notes)" },
  { "o", "pick an Orphan to attach" },
  { "v", "toggle virtual text" },
  { "R", "refresh" },
  { "q", "close the Panel" },
}

M.COMMANDS = {
  { ":CodeReader", "toggle this Panel" },
  { ":[range]CodeReader note", "add a Note (range, symbol or line)" },
  { ":CodeReader note file | project", "add a File / Project Note" },
  { ":CodeReader show", "open the Note under the cursor" },
  { ":CodeReader confirm | delete", "the Note under the cursor" },
  { ":CodeReader move", "select the Note under the cursor to move" },
  { ":[range]CodeReader attach", "attach the selected Note here" },
  { ":CodeReader notes [#tag] | here | orphans", "pickers" },
  { ":CodeReader stop | back | forward", "the Trail" },
  { ":CodeReader trail new [name] | list | rename <name>", "Trails" },
}

local function help()
  local lines = { "Panel keys", "" }
  for _, k in ipairs(M.KEYS) do
    lines[#lines + 1] = ("  %-6s %s"):format(k[1], k[2])
  end
  vim.list_extend(lines, { "", "Commands (anywhere)", "" })
  for _, c in ipairs(M.COMMANDS) do
    lines[#lines + 1] = ("  %-44s %s"):format(c[1], c[2])
  end
  vim.list_extend(lines, { "", "Signs: ● Note  ◐ Drifted  ▤ File Note   Panel: ● Note near a Stop  ▶ current Stop" })
  Editor.show("codereader help", lines)
end

local function item()
  local node = M.view:component_at_cursor(function(n)
    return n.options and n.options.tag
  end)
  return node and node.options.tag
end

local function toggle(id)
  if id and M.folds[id] ~= nil then
    M.folds[id] = not M.folds[id]
    M.render()
  end
end

local function with_note(fn)
  return function()
    local it = item()
    if not it or it.kind ~= "note" then
      return util.notify("put the cursor on a Note", vim.log.levels.WARN)
    end
    fn(it.note)
  end
end

local function focus(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

local mappings = {
  ["<CR>"] = function()
    local it = item()
    if not it then
      return
    end
    if it.kind == "section" then
      toggle(it.id)
    elseif it.kind == "note" then
      local w = M.code_window()
      Actions.jump(it.note, w)
      if it.note.abs_path then
        focus(w)
      end
    elseif it.kind == "stop" then
      local w = M.code_window()
      Trail.goto_stop(it.stop.id, w)
      focus(w)
    end
  end,
  ["<Tab>"] = function()
    local it = item()
    if it then
      toggle(it.id or it.section)
    end
  end,
  a = function()
    Actions.add_note({ win = M.code_window() })
  end,
  A = function()
    Actions.add_file_note({ win = M.code_window() })
  end,
  P = Actions.add_project_note,
  e = with_note(Actions.edit),
  d = with_note(Actions.delete),
  c = with_note(Actions.confirm),
  m = with_note(function(n)
    Actions.attach({ win = M.code_window() }, n)
  end),
  s = function()
    Trail.add_stop(M.code_window())
  end,
  ["["] = function()
    Trail.back(M.code_window())
  end,
  ["]"] = function()
    Trail.forward(M.code_window())
  end,
  t = function()
    require("codereader.pick").trails()
  end,
  T = function()
    vim.ui.input({ prompt = "New Trail name: " }, function(name)
      if name and name ~= "" and Trail.new(name) then
        util.notify("started Trail: " .. name)
      end
    end)
  end,
  ["/"] = function()
    require("codereader.pick").notes()
  end,
  o = function()
    require("codereader.pick").orphans()
  end,
  v = Notes.toggle_virtual_text,
  R = function()
    M.data.project = nil
    M.reload()
  end,
  q = function()
    M.close()
  end,
  ["?"] = help,
}

-- Open / close -------------------------------------------------------------------

function M.open()
  if M.is_open() then
    focus(M.view.win)
    return
  end
  local cur = vim.api.nvim_get_current_win()
  if util.is_code_buf(vim.api.nvim_win_get_buf(cur)) then
    M.code_win = cur
  end
  local cfg = Config.get().panel
  local kind = ({ right = "right", left = "left", float = "float" })[cfg.position] or "right"
  M.view = Buffer.create({
    name = "codereader://panel",
    filetype = "codereader",
    kind = kind,
    win = { width = cfg.width, title = "codereader" },
    render = render,
    mappings = { n = mappings },
    on_close = function()
      M.view = nil
    end,
  })
  M.reload()
  if not cfg.focus and M.code_win and vim.api.nvim_win_is_valid(M.code_win) then
    focus(M.code_win)
  end
end

function M.close()
  if M.view then
    M.view:close()
    M.view = nil
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Track the code window and redraw "Notes here" when it changes buffer.
function M.on_enter()
  local win = vim.api.nvim_get_current_win()
  if util.is_code_buf(vim.api.nvim_win_get_buf(win)) then
    M.code_win = win
    M.render()
  end
end

return M
