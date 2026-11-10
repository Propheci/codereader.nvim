-- Plugin configuration. `setup()` merges user options over the defaults; every
-- other module reads them through `get()`.

local M = {}

--- Plugin root (the directory holding `lua/`, `plugin/` and the Cargo workspace).
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

M.defaults = {
  -- Path to the `codereader` binary. Default: the release build next to the
  -- plugin, then the debug build, then `codereader` on $PATH.
  binary = nil,
  -- Where Notes and Trails live (one folder per Project). See ADR 0001.
  data_dir = vim.fn.stdpath("data") .. "/codereader",
  -- Fixed Project name instead of one derived from the git root path.
  project = nil,
  -- Store Notes and Trails in `<root>/.codereader/` (for sharing) instead.
  in_repo = false,
  -- Show each Note's title as virtual text at the end of its first line.
  virtual_text = true,
  signs = { note = "●", drifted = "◐", file = "▤" },
  panel = { position = "right", width = 50, focus = true },
  float = { width = 72, height = 14, border = "rounded" },
  -- Picker backend for finding Notes and Trails. v1 ships "telescope".
  picker = "telescope",
  -- Add a Stop to the active Trail on every LSP jump (definition,
  -- declaration, type definition, implementation, references).
  record_lsp_jumps = true,
  -- Opt-in global keymaps, e.g. `{ prefix = "<leader>c" }`. Off by default.
  keymaps = false,
}

local current = vim.deepcopy(M.defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

local function default_binary()
  for _, p in ipairs({ M.root .. "/target/release/codereader", M.root .. "/target/debug/codereader" }) do
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return "codereader"
end

function M.get()
  if not current.binary then
    current.binary = default_binary()
  end
  return current
end

--- Arguments every call to the binary starts with.
function M.global_args()
  local c = M.get()
  local args = { "--json", "--data-dir=" .. c.data_dir }
  if c.project then
    args[#args + 1] = "--project=" .. c.project
  end
  if c.in_repo then
    args[#args + 1] = "--in-repo"
  end
  return args
end

return M
