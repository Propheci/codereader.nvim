-- codereader.nvim: Notes and Trails for reading large codebases.
--
--   require("codereader").setup({ keymaps = { prefix = "<leader>c" } })
--
-- See `docs/ROADMAP.md` for what v1 does and `GLOSSARY.md` for the terms.

local Actions = require("codereader.actions")
local Config = require("codereader.config")
local Highlights = require("codereader.highlights")
local Notes = require("codereader.notes")
local Panel = require("codereader.panel")
local Trail = require("codereader.trail")
local backend = require("codereader.backend")
local util = require("codereader.util")

local M = {}

local did_setup = false

local function autocmds()
  local group = vim.api.nvim_create_augroup("codereader", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      Notes.refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if Notes.by_buf[ev.buf] == nil then
        Notes.refresh(ev.buf)
      end
      Panel.on_enter()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      Notes.forget(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = Highlights.setup })
end

--- Lines of a visual selection (call while still in visual mode).
local function visual_range()
  local s, e = vim.fn.line("v"), vim.fn.line(".")
  if s > e then
    s, e = e, s
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { s, e }
end

function M.add_note_visual()
  return Actions.add_note({ range = visual_range() })
end

function M.attach_visual()
  return Actions.attach({ range = visual_range() })
end

local function keymaps(km)
  if not km then
    return
  end
  local p = km.prefix or "<leader>c"
  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = "codereader: " .. desc, silent = true })
  end
  map("n", p .. "c", Panel.toggle, "toggle Panel")
  map("n", p .. "n", Actions.add_note, "add Note")
  map("x", p .. "n", M.add_note_visual, "add Note on selection")
  map("n", p .. "s", Trail.add_stop, "add Stop")
  map("n", "[t", Trail.back, "Trail back")
  map("n", "]t", Trail.forward, "Trail forward")
end

function M.setup(opts)
  Config.setup(opts)
  did_setup = true
  Highlights.setup()
  if not backend.available() then
    util.notify(
      ("binary not found (%s). Run `cargo build --release` in %s."):format(Config.get().binary, Config.root),
      vim.log.levels.WARN
    )
    return
  end
  autocmds()
  Notes.on_change(function()
    Panel.render()
  end)
  Trail.on_change(Panel.reload_trail)
  if Config.get().record_lsp_jumps then
    require("codereader.lsp").setup()
  end
  keymaps(Config.get().keymaps)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      Notes.refresh(buf)
    end
  end
end

--- Commands work before `setup()` (with default options).
function M.ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

M.toggle_panel = Panel.toggle
M.add_note = Actions.add_note
M.add_stop = Trail.add_stop
M.back = Trail.back
M.forward = Trail.forward

return M
