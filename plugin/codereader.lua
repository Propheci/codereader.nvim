-- Defines `:CodeReader` and the <Plug> mappings. Nothing runs until a command
-- is used or `require("codereader").setup()` is called. No global keymaps are
-- set here (round 3, Q6); `setup{ keymaps = { prefix = ... } }` opts in.
--
--   :CodeReader                        toggle the Panel
--   :[range]CodeReader note            add a Note (range / symbol / line)
--   :CodeReader note file|project      add a File / Project Note
--   :CodeReader show                   open the Note under the cursor
--   :CodeReader confirm|delete         the Note under the cursor
--   :CodeReader move                   select the Note under the cursor to move
--   :[range]CodeReader attach          attach the selected Note here
--   :CodeReader notes [#tag]           pick any Note
--   :CodeReader here|orphans|drifted   pick Notes in this file / Orphans / Drifted
--   :CodeReader stop|back|forward      the active Trail
--   :CodeReader trail new [name]|list|rename <name>
--   :CodeReader virtualtext|refresh

if vim.g.loaded_codereader then
  return
end
vim.g.loaded_codereader = true

local function cr()
  local m = require("codereader")
  m.ensure_setup()
  return m
end

local function A()
  cr()
  return require("codereader.actions")
end

local function P()
  cr()
  return require("codereader.pick")
end

local function T()
  cr()
  return require("codereader.trail")
end

local function at_cursor()
  return require("codereader.notes").at_cursor()
end

local function range_of(opts)
  if opts.range == 2 then
    return { math.min(opts.line1, opts.line2), math.max(opts.line1, opts.line2) }
  end
end

local subcommands = {
  panel = function()
    cr().toggle_panel()
  end,
  note = function(args, opts)
    local kind = args[1]
    if kind == "file" then
      A().add_file_note()
    elseif kind == "project" then
      A().add_project_note()
    else
      A().add_note({ range = range_of(opts) })
    end
  end,
  show = function()
    A().edit(at_cursor())
  end,
  confirm = function()
    A().confirm(at_cursor())
  end,
  delete = function()
    A().delete(at_cursor())
  end,
  move = function()
    A().mark_for_attach(at_cursor())
  end,
  attach = function(_, opts)
    A().attach({ range = range_of(opts) })
  end,
  notes = function(args)
    P().notes({ tag = args[1] })
  end,
  here = function()
    P().here()
  end,
  orphans = function()
    P().orphans()
  end,
  drifted = function()
    P().notes({ status = "drifted", title = "Drifted Notes", empty = "no Drifted Notes" })
  end,
  stop = function()
    T().add_stop()
  end,
  back = function()
    T().back()
  end,
  forward = function()
    T().forward()
  end,
  trail = function(args)
    local sub = args[1]
    local rest = table.concat(vim.list_slice(args, 2), " ")
    if sub == "new" then
      local t = T().new(rest ~= "" and rest or nil)
      if t then
        require("codereader.util").notify("started Trail: " .. (t.name or "(unnamed)"))
      end
    elseif sub == "rename" then
      local trail = T()
      if not trail.active or rest == "" then
        return require("codereader.util").error("usage: :CodeReader trail rename <name> (with an active Trail)")
      end
      local ok, data = require("codereader.backend").call({ "trail", "rename", trail.active.id, "--", rest })
      if not ok then
        return require("codereader.util").error(data)
      end
      trail.set_active(data.id, data.name)
    else
      P().trails()
    end
  end,
  virtualtext = function()
    cr()
    require("codereader.notes").toggle_virtual_text()
  end,
  refresh = function()
    A().changed()
  end,
}

local completions = {
  note = { "file", "project" },
  trail = { "new", "list", "rename" },
}

vim.api.nvim_create_user_command("CodeReader", function(opts)
  local args = opts.fargs
  local sub = args[1] or "panel"
  local handler = subcommands[sub]
  if not handler then
    vim.notify("codereader: unknown subcommand " .. sub, vim.log.levels.ERROR)
    return
  end
  handler(vim.list_slice(args, 2), opts)
end, {
  nargs = "*",
  range = true,
  desc = "codereader: Notes and Trails (no args: toggle the Panel)",
  complete = function(lead, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    local n = #words + (line:match("%s$") and 1 or 0)
    local items = n <= 2 and vim.tbl_keys(subcommands) or (completions[words[2]] or {})
    table.sort(items)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, items)
  end,
})

local plug = {
  { "n", "panel", function() cr().toggle_panel() end },
  { "n", "note", function() A().add_note() end },
  { "x", "note", function() cr().add_note_visual() end },
  { "n", "show", function() A().edit(at_cursor()) end },
  { "n", "stop", function() T().add_stop() end },
  { "n", "back", function() T().back() end },
  { "n", "forward", function() T().forward() end },
  { "n", "notes", function() P().notes() end },
  { "n", "here", function() P().here() end },
  { "n", "attach", function() A().attach() end },
  { "x", "attach", function() cr().attach_visual() end },
}
for _, p in ipairs(plug) do
  vim.keymap.set(p[1], "<Plug>(codereader-" .. p[2] .. ")", p[3], { desc = "codereader: " .. p[2] })
end
