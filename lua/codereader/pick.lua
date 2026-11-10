-- The pickers: all Notes, Notes in this file, Orphans, Trails (round 2 Q10,
-- round 5 Q4/Q5).

local Actions = require("codereader.actions")
local Pickers = require("codereader.pickers")
local Trail = require("codereader.trail")
local backend = require("codereader.backend")
local util = require("codereader.util")

local M = {}

local ICON = { range = "●", symbol = "ƒ", file = "▤", project = "◆" }
local STATUS = { drifted = " [drifted]", orphan = " [orphan]" }

function M.location(n)
  if n.kind == "project" then
    return "(project)"
  end
  local r = n.resolution or {}
  local line = r.start_line or n.start_line
  local where = util.short_path(n.abs_path or n.path or "")
  if n.kind == "symbol" then
    return ("%s:%s %s"):format(where, line or "?", table.concat(n.symbol or {}, " > "))
  end
  return line and (where .. ":" .. line) or where
end

local function note_entry(n)
  local status = STATUS[(n.resolution or {}).status] or ""
  local title = n.title ~= "" and n.title or "(empty note)"
  return {
    display = ("%s %s  %s%s"):format(ICON[n.kind] or "●", title, M.location(n), status),
    ordinal = table.concat({ title, n.body or "", M.location(n), status }, " "),
  }
end

--- The Note above the code it is anchored to.
function M.preview(n)
  local lines = vim.split(n.body ~= "" and n.body or "(empty note)", "\n", { plain = true })
  local r = n.resolution or {}
  local s, e = r.start_line or n.start_line, r.end_line or n.end_line
  if n.abs_path and s and e then
    local code
    local buf = util.find_buf(n.abs_path)
    if buf then
      code = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
    elseif vim.fn.filereadable(n.abs_path) == 1 then
      code = vim.list_slice(vim.fn.readfile(n.abs_path, "", e), s, e)
    end
    if code then
      local ft = vim.filetype.match({ filename = n.abs_path }) or ""
      vim.list_extend(lines, { "", ("```%s %s:%d-%d"):format(ft, util.short_path(n.abs_path), s, e) })
      vim.list_extend(lines, code)
      lines[#lines + 1] = "```"
    end
  elseif r.status == "orphan" and n.snapshot then
    vim.list_extend(lines, { "", "Orphan. The code it was about:", "```" })
    vim.list_extend(lines, vim.split(n.snapshot, "\n", { plain = true }))
    lines[#lines + 1] = "```"
  end
  return { lines = lines, filetype = "markdown" }
end

local function note_actions(reopen)
  return {
    { key = "<C-e>", desc = "edit", fn = Actions.edit },
    {
      key = "<C-d>",
      desc = "delete",
      fn = function(n)
        if Actions.delete(n) then
          reopen()
        end
      end,
    },
    {
      key = "<C-y>",
      desc = "confirm",
      fn = function(n)
        if Actions.confirm(n) then
          reopen()
        end
      end,
    },
  }
end

--- opts: { path?, tag?, status?, title? }
function M.notes(opts)
  opts = opts or {}
  local args = { "note", "list", "--resolve" }
  if opts.path then
    args[#args + 1] = "--path=" .. opts.path
  end
  if opts.tag then
    args[#args + 1] = "--tag=" .. opts.tag
  end
  if opts.status then
    args[#args + 1] = "--status=" .. opts.status
  end
  backend.call(args, {}, function(ok, notes)
    if not ok then
      return util.error(notes)
    end
    local win = vim.api.nvim_get_current_win()
    Pickers.pick({
      title = opts.title or (opts.tag and ("Notes #" .. opts.tag:gsub("^#", "")) or "Notes"),
      empty = opts.empty or "no Notes yet",
      items = notes,
      entry = note_entry,
      preview = M.preview,
      on_select = function(n)
        Actions.jump(n, win)
      end,
      actions = note_actions(function()
        M.notes(opts)
      end),
    })
  end)
end

function M.here()
  local buf = vim.api.nvim_get_current_buf()
  if not util.is_code_buf(buf) then
    return util.error("put the cursor in a file first")
  end
  M.notes({ path = util.buf_path(buf), title = "Notes in " .. util.short_path(util.buf_path(buf)), empty = "no Notes in this file" })
end

function M.orphans()
  backend.call({ "note", "list", "--status=orphan" }, {}, function(ok, notes)
    if not ok then
      return util.error(notes)
    end
    Pickers.pick({
      title = "Orphans · <CR> select, then :CodeReader attach at the new place",
      empty = "no Orphans",
      items = notes,
      entry = note_entry,
      preview = M.preview,
      on_select = Actions.mark_for_attach,
      actions = {
        { key = "<C-e>", desc = "edit", fn = Actions.edit },
        {
          key = "<C-f>",
          desc = "make File Note",
          fn = function(n)
            if not n.abs_path or vim.fn.filereadable(n.abs_path) == 0 then
              return util.error("the file is gone too; attach it elsewhere instead")
            end
            local ok2, data = backend.call({ "note", "attach", n.id, "--kind=file", "--path=" .. n.abs_path })
            if not ok2 then
              return util.error(data)
            end
            Actions.changed()
            M.orphans()
          end,
        },
        {
          key = "<C-d>",
          desc = "delete",
          fn = function(n)
            if Actions.delete(n) then
              M.orphans()
            end
          end,
        },
      },
    })
  end)
end

function M.trails()
  backend.call({ "trail", "list" }, {}, function(ok, trails)
    if not ok then
      return util.error(trails)
    end
    local active = Trail.active and Trail.active.id
    Pickers.pick({
      title = "Trails",
      empty = "no Trails yet: add a Stop, or :CodeReader trail new <name>",
      items = trails,
      entry = function(t)
        local name = t.name or "(unnamed)"
        return {
          display = ("%s %s  %d stops  %s"):format(t.id == active and "▶" or " ", name, t.stop_count, t.updated:sub(1, 16)),
          ordinal = name .. " " .. t.id,
        }
      end,
      on_select = function(t)
        Trail.set_active(t.id, t.name)
        util.notify("active Trail: " .. (t.name or "(unnamed)"))
      end,
      actions = {
        {
          key = "<C-r>",
          desc = "rename",
          fn = function(t)
            vim.ui.input({ prompt = "Trail name: ", default = t.name or "" }, function(name)
              if name and name ~= "" then
                local ok2, data = backend.call({ "trail", "rename", t.id, "--", name })
                if not ok2 then
                  return util.error(data)
                end
                if Trail.active and Trail.active.id == t.id then
                  Trail.set_active(t.id, name)
                end
              end
              M.trails()
            end)
          end,
        },
        {
          key = "<C-d>",
          desc = "delete",
          fn = function(t)
            if vim.fn.confirm(("Delete Trail %q?"):format(t.name or "(unnamed)"), "&Yes\n&No", 2) ~= 1 then
              return
            end
            local ok2, data = backend.call({ "trail", "delete", t.id })
            if not ok2 then
              return util.error(data)
            end
            if Trail.active and Trail.active.id == t.id then
              Trail.set_active(nil)
            end
            M.trails()
          end,
        },
      },
    })
  end)
end

return M
