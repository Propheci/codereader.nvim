-- Plugin tests. Build the binary first, then run:
--   cargo build && nvim --headless --clean -u NONE -l tests/spec.lua
--
-- Drives the Lua layer against the real debug binary in a throwaway Project,
-- so a Rust change that breaks the JSON contract fails here.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
-- `-u NONE` skips plugin/ for paths added after startup; load ours.
vim.cmd.runtime("plugin/codereader.lua")
vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "F"

local BINARY = vim.env.CODEREADER_BIN or (root .. "/target/debug/codereader")

local failures, passes = {}, 0
local function check(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passes = passes + 1
    print("  ok   " .. name)
  else
    failures[#failures + 1] = name
    print("  FAIL " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "not equal") .. ": " .. vim.inspect(a) .. " ~= " .. vim.inspect(b), 2)
  end
end

local function wait(cond, msg)
  assert(vim.wait(3000, cond, 10), "timed out: " .. (msg or "condition"))
end

-- A throwaway Project: a git root with one Lua file.
local tmp = vim.fn.tempname()
local repo = tmp .. "/repo"
vim.fn.mkdir(repo .. "/.git", "p")
vim.fn.mkdir(repo .. "/src", "p")
local AUTH = {
  "local M = {}",
  "",
  "function M.login(user)",
  "  local ok = check(user)",
  "  log(ok)",
  "  return ok",
  "end",
  "",
  "return M",
}
vim.fn.writefile(AUTH, repo .. "/src/auth.lua")
vim.fn.chdir(repo)

for _, m in ipairs({
  "codereader", "codereader.config", "codereader.backend", "codereader.util", "codereader.highlights",
  "codereader.symbols", "codereader.notes", "codereader.editor", "codereader.trail", "codereader.lsp",
  "codereader.actions", "codereader.pickers", "codereader.pickers.telescope", "codereader.pick",
  "codereader.panel", "codereader.ui.buffer", "codereader.ui.component", "codereader.ui.renderer",
}) do
  check("require " .. m, function()
    require(m)
  end)
end

local backend = require("codereader.backend")
local Config = require("codereader.config")

check("backend refuses an unknown schema version", function()
  local ok, err = backend.parse({ code = 0, stdout = '{"schema_version":0,"ok":true,"data":1}', stderr = "" })
  assert(not ok and err:find("rebuild the codereader binary"), err)
  ok, err = backend.parse({ code = 0, stdout = '{"schema_version":99,"ok":true,"data":1}', stderr = "" })
  assert(not ok and err:find("update codereader.nvim"), err)
  ok, err = backend.parse({ code = 2, stdout = "", stderr = "error: unexpected argument" })
  assert(not ok and err:find("unexpected argument"), err)
end)

check("backend refuses a stale binary end to end", function()
  local fake = tmp .. "/fake_v0_binary.sh"
  vim.fn.writefile({ "#!/bin/sh", [[echo '{"ok":true,"data":{}}']] }, fake)
  vim.fn.setfperm(fake, "rwxr-xr-x")
  Config.setup({ binary = fake })
  local ok, err = backend.call({ "project" })
  assert(not ok and err:find("schema %(none%)"), err)
end)

require("codereader").setup({ binary = BINARY, data_dir = tmp .. "/data" })
local Actions = require("codereader.actions")
local Notes = require("codereader.notes")
local Panel = require("codereader.panel")
local Symbols = require("codereader.symbols")
local Trail = require("codereader.trail")
local Lsp = require("codereader.lsp")

check("backend talks to the real binary", function()
  local ok, p = backend.call({ "project" })
  assert(ok, p)
  eq(p.root, vim.uv.fs_realpath(repo))
  assert(p.store_dir:find(tmp .. "/data", 1, true) or p.store_dir:find("/data/", 1, true), p.store_dir)
end)

vim.cmd.edit(repo .. "/src/auth.lua")
local code_buf = vim.api.nvim_get_current_buf()
local code_win = vim.api.nvim_get_current_win()

local function list_notes()
  local ok, notes = backend.call({ "note", "list", "--resolve" })
  assert(ok, notes)
  return notes
end

--- Type `lines` into the Note float that is open now and save with `:w`.
local function write_float(lines)
  vim.cmd.stopinsert()
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, "markdown", "the Note float is focused")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd.write()
  vim.api.nvim_win_close(0, true)
end

local function refreshed()
  local done = false
  Notes.refresh(code_buf, function()
    done = true
  end)
  wait(function()
    return done
  end, "notes refresh")
  return Notes.by_buf[code_buf]
end

check("symbols: Treesitter finds the enclosing function", function()
  local s = Symbols.at(code_buf, 4)
  assert(s, "no symbol")
  eq(s.symbol, { "M.login" })
  eq({ s.start_line, s.end_line }, { 3, 7 })
  eq(Symbols.at(code_buf, 1), nil, "top level has no symbol")
  assert(#Symbols.all(code_buf) >= 1)
end)

local login_id
check("add a Symbol Note from the cursor via the float", function()
  vim.api.nvim_win_set_cursor(code_win, { 5, 0 })
  Actions.add_note({ win = code_win })
  write_float({ "Fake login #lie", "", "real one is elsewhere" })
  local notes = list_notes()
  eq(#notes, 1)
  eq(notes[1].kind, "symbol")
  eq(notes[1].symbol, { "M.login" })
  eq(notes[1].title, "Fake login #lie")
  eq(notes[1].tags, { "lie" })
  login_id = notes[1].id
end)

check("an empty float creates nothing", function()
  vim.api.nvim_set_current_win(code_win)
  Actions.add_note({ win = code_win })
  vim.cmd.stopinsert()
  vim.api.nvim_win_close(0, true)
  eq(#list_notes(), 1)
end)

check("the Note shows as a sign + virtual text and is found at the cursor", function()
  local notes = refreshed()
  eq(#notes, 1)
  local marks = vim.api.nvim_buf_get_extmarks(code_buf, -1, 0, -1, { details = true })
  local signed = vim.tbl_filter(function(m)
    return m[4].sign_text ~= nil
  end, marks)
  eq(#signed, 1)
  eq(signed[1][2], 2, "sign on the function's first line (0-based 2)")
  assert(signed[1][4].virt_text[1][1]:find("Fake login"), vim.inspect(signed[1][4].virt_text))
  vim.api.nvim_win_set_cursor(code_win, { 6, 0 })
  eq(Notes.at_cursor(code_win).id, login_id)
  vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
  eq(Notes.at_cursor(code_win), nil)
end)

check("virtual text toggles off and on", function()
  Notes.toggle_virtual_text()
  local marks = vim.api.nvim_buf_get_extmarks(code_buf, -1, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    assert(m[4].virt_text == nil, "virtual text still shown")
  end
  Notes.toggle_virtual_text()
end)

check("unsaved edits move the Note (buffer text is sent, not the file)", function()
  vim.api.nvim_buf_set_lines(code_buf, 0, 0, false, { "-- new", "-- lines" })
  local n = refreshed()[1]
  eq(n.resolution.start_line, 5)
  eq(n.resolution.status, "moved")
end)

check("editing the function makes it Drifted; confirm clears it", function()
  vim.api.nvim_buf_set_lines(code_buf, 6, 7, false, { "  audit(ok)" })
  local n = refreshed()[1]
  eq(n.resolution.status, "drifted")
  assert(Actions.confirm(n))
  eq(refreshed()[1].resolution.status, "ok")
end)

check("File and Project Notes", function()
  vim.api.nvim_set_current_win(code_win)
  Actions.add_file_note({ win = code_win })
  write_float({ "auth module #question" })
  Actions.add_project_note()
  write_float({ "Auth is done in 3 places" })
  local kinds = {}
  for _, n in ipairs(list_notes()) do
    kinds[n.kind] = (kinds[n.kind] or 0) + 1
  end
  eq(kinds, { symbol = 1, file = 1, project = 1 })
  local file_note = vim.tbl_filter(function(n)
    return n.kind == "file"
  end, refreshed())[1]
  assert(file_note and file_note.resolution.status == "ok")
  vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
  eq(Notes.at_cursor(code_win).kind, "file", "File Note at line 1")
end)

check("a Range Note from a visual-style range, edited in the float", function()
  vim.api.nvim_set_current_win(code_win)
  Actions.add_note({ win = code_win, range = { 1, 2 } })
  write_float({ "- starts with a dash" })
  local n = vim.tbl_filter(function(x)
    return x.kind == "range"
  end, list_notes())[1]
  eq(n.body, "- starts with a dash", "values starting with - are not read as flags")
  eq({ n.start_line, n.end_line }, { 1, 2 })
  Actions.edit(n)
  write_float({ "- edited" })
  local again = vim.tbl_filter(function(x)
    return x.id == n.id
  end, list_notes())[1]
  eq(again.body, "- edited")
  assert(Actions.delete(again, { force = true }))
end)

check("deleted code makes an Orphan; attach moves it", function()
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "local M = {}", "return M" })
  vim.api.nvim_buf_call(code_buf, function()
    vim.cmd.write()
  end)
  refreshed()
  local orphan = vim.tbl_filter(function(n)
    return n.id == login_id
  end, list_notes())[1]
  eq(orphan.resolution.status, "orphan")
  Actions.mark_for_attach(orphan)
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
  assert(Actions.attach({ win = code_win }))
  local moved = vim.tbl_filter(function(n)
    return n.id == login_id
  end, list_notes())[1]
  eq(moved.resolution.status, "ok")
  eq(moved.kind, "range")
  eq(Actions.pending_attach, nil)
end)

-- Restore a file with more lines for the Trail tests.
vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, AUTH)
vim.api.nvim_buf_call(code_buf, function()
  vim.cmd.write()
end)

check("a manual Stop starts an unnamed Trail", function()
  Trail.set_active(nil)
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
  local s = Trail.add_stop()
  assert(s and Trail.active, "no Trail")
  eq(Trail.active.name, nil)
  eq(s.line, 1)
end)

check("an LSP jump (LspRequest + cursor move) records a Stop", function()
  vim.api.nvim_exec_autocmds("LspRequest", {
    data = { client_id = 1, request_id = 1, request = { type = "pending", method = "textDocument/definition" } },
  })
  assert(Lsp.pending, "pending not recorded from the autocmd")
  vim.api.nvim_win_set_cursor(code_win, { 4, 2 })
  Lsp.check(false)
  eq(Lsp.pending, nil)
  local ok, t = backend.call({ "trail", "show", Trail.active.id })
  assert(ok, t)
  eq(#t.stops, 2, "the origin was the current Stop, so only the target is new")
  eq(t.stops[2].via, "definition")
  eq(t.stops[2].line, 4)
  eq(t.stops[2].symbol, { "M.login" })
end)

check("an LSP request that goes nowhere is forgotten", function()
  Lsp.on_request({ type = "pending", method = "textDocument/definition" })
  Lsp.check(true)
  eq(Lsp.pending, nil)
  Lsp.on_request({ type = "pending", method = "textDocument/hover" })
  eq(Lsp.pending, nil, "hover is not a jump")
end)

check("back / forward move the cursor along the Trail", function()
  Trail.back(code_win)
  eq(vim.api.nvim_win_get_cursor(code_win)[1], 1)
  Trail.forward(code_win)
  eq(vim.api.nvim_win_get_cursor(code_win)[1], 4)
end)

check(":CodeReader trail new / rename and completion", function()
  vim.cmd("CodeReader trail new how login works")
  eq(Trail.active.name, "how login works")
  vim.cmd("CodeReader trail rename login flow")
  eq(Trail.active.name, "login flow")
  local items = vim.fn.getcompletion("CodeReader ", "cmdline")
  assert(vim.tbl_contains(items, "note") and vim.tbl_contains(items, "orphans"), vim.inspect(items))
  eq(vim.fn.getcompletion("CodeReader trail ", "cmdline"), { "list", "new", "rename" })
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_win_set_cursor(code_win, { 3, 0 })
  vim.cmd("CodeReader stop")
end)

local function panel_lines()
  return vim.api.nvim_buf_get_lines(Panel.view.bufnr, 0, -1, false)
end

local function panel_has(pat)
  for _, l in ipairs(panel_lines()) do
    if l:find(pat) then
      return true
    end
  end
  return false
end

check("the Panel shows every section and follows the data", function()
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("CodeReader")
  assert(Panel.is_open(), "Panel did not open")
  wait(function()
    return Panel.data.project and Panel.data.notes and Panel.data.trail
  end, "panel data")
  for _, pat in ipairs({ "^codereader", "Trail: login flow", "Project Notes", "Notes here: src/auth.lua", "Needs attention", "%? help" }) do
    assert(panel_has(pat), "missing " .. pat .. "\n" .. table.concat(panel_lines(), "\n"))
  end
  assert(not panel_has("Auth is done"), "Project Notes are collapsed by default")
  wait(function()
    return panel_has("M.login")
  end, "trail stops rendered")
  assert(panel_has("auth module"), "File Note in Notes here")
end)

check("<Tab> unfolds a section; <CR> on a Stop jumps the code window", function()
  vim.api.nvim_set_current_win(Panel.view.win)
  for i, l in ipairs(panel_lines()) do
    if l:find("Project Notes") then
      vim.api.nvim_win_set_cursor(Panel.view.win, { i, 0 })
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  assert(panel_has("Auth is done"), "Project Notes unfolded")
  for i, l in ipairs(panel_lines()) do
    if l:find("M%.login") then
      vim.api.nvim_win_set_cursor(Panel.view.win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(vim.api.nvim_get_current_win(), code_win, "focus moved to the code window")
  eq(vim.api.nvim_win_get_cursor(code_win)[1], 3, "the login flow Trail's only Stop")
end)

check("Panel `?` help lists the keys", function()
  vim.api.nvim_set_current_win(Panel.view.win)
  vim.api.nvim_feedkeys("?", "x", false)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(table.concat(lines, "\n"):find("move %(attach%) the Note"), "help text")
  vim.api.nvim_win_close(0, true)
end)

check(":CodeReader toggles the Panel closed", function()
  vim.cmd("CodeReader")
  assert(not Panel.is_open())
end)

check("pickers report a missing telescope instead of failing", function()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  require("codereader.pickers").pick({ title = "x", items = { 1 }, entry = tostring, on_select = function() end })
  vim.notify = orig
  assert(msgs[1] and msgs[1]:find("not installed"), vim.inspect(msgs))
end)

vim.fn.delete(tmp, "rf")
print(("\n%d passed, %d failed"):format(passes, #failures))
os.exit(#failures == 0 and 0 or 1)
