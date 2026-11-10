local M = {}

local links = {
  CodeReaderSign = "DiagnosticInfo",
  CodeReaderDrifted = "DiagnosticWarn",
  CodeReaderVirtText = "Comment",
  CodeReaderDriftedText = "DiagnosticVirtualTextWarn",
  CodeReaderTitle = "Title",
  CodeReaderSection = "Function",
  CodeReaderMuted = "Comment",
  CodeReaderCurrent = "Special",
  CodeReaderLost = "DiagnosticError",
  CodeReaderOrphan = "DiagnosticError",
  CodeReaderNear = "DiagnosticInfo",
  CodeReaderKey = "Special",
}

function M.setup()
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

return M
