local M = {}

function M.available()
  return (pcall(require, "telescope"))
end

function M.pick(spec)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local previewer
  if spec.preview then
    previewer = previewers.new_buffer_previewer({
      title = spec.preview_title or "Note",
      define_preview = function(self, entry)
        local p = spec.preview(entry.value)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, p.lines)
        if p.filetype then
          vim.bo[self.state.bufnr].filetype = p.filetype
          pcall(vim.treesitter.start, self.state.bufnr, p.filetype)
        end
      end,
    })
  end

  local hints = {}
  for _, a in ipairs(spec.actions or {}) do
    hints[#hints + 1] = a.key .. " " .. a.desc
  end

  pickers
    .new({}, {
      prompt_title = spec.title,
      results_title = #hints > 0 and table.concat(hints, " · ") or nil,
      finder = finders.new_table({
        results = spec.items,
        entry_maker = function(item)
          local e = spec.entry(item)
          return { value = item, display = e.display, ordinal = e.ordinal }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewer,
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local e = state.get_selected_entry()
          actions.close(prompt_bufnr)
          if e then
            spec.on_select(e.value)
          end
        end)
        for _, a in ipairs(spec.actions or {}) do
          map({ "i", "n" }, a.key, function()
            local e = state.get_selected_entry()
            if not e then
              return
            end
            actions.close(prompt_bufnr)
            -- After close, so prompts (confirm, input) get a normal window.
            vim.schedule(function()
              a.fn(e.value)
            end)
          end)
        end
        return true
      end,
    })
    :find()
end

return M
