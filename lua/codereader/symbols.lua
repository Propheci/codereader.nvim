-- Symbol paths for Symbol Anchors and Stops: Treesitter first, LSP document
-- symbols as the fallback (round 3, Q4). A symbol path is the list of named
-- containers from the outside in, e.g. { "UserService", "login" }.

local M = {}

-- A node type is a container if it names one of these and none of `NOT`.
local KINDS = { "function", "method", "class", "struct", "impl", "trait", "interface", "module", "enum", "namespace", "constructor" }
local NOT = {
  "call", "param", "argument", "variant", "parenthes", "_type$", "^type_", "identifier",
  "expression$", "body$", "list$", "modifier", "reference", "signature$",
}

local function is_container(t)
  for _, bad in ipairs(NOT) do
    if t:find(bad) then
      return false
    end
  end
  for _, k in ipairs(KINDS) do
    if t:find(k, 1, true) then
      return true
    end
  end
  return false
end

local function name_of(node, bufnr)
  for _, field in ipairs({ "name", "type", "declarator" }) do
    local n = node:field(field)[1]
    if n then
      -- C/C++: function_definition > function_declarator > identifier.
      while n:field("declarator")[1] do
        n = n:field("declarator")[1]
      end
      local text = vim.treesitter.get_node_text(n, bufnr):gsub("%s+", " ")
      if #text > 0 and #text <= 80 then
        return text
      end
    end
  end
end

--- 1-based inclusive line range of a node.
local function lines(node)
  local sr, _, er, ec = node:range()
  if ec == 0 and er > sr then
    er = er - 1
  end
  return sr + 1, er + 1
end

local function ts_tree(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  return trees and trees[1]
end

local function ts_at(bufnr, line)
  local tree = ts_tree(bufnr)
  if not tree then
    return nil
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local col = #(text:match("^%s*") or "")
  local node = tree:root():named_descendant_for_range(line - 1, col, line - 1, col)
  local path, innermost = {}, nil
  while node do
    if is_container(node:type()) then
      local name = name_of(node, bufnr)
      if name then
        table.insert(path, 1, name)
        innermost = innermost or node
      end
    end
    node = node:parent()
  end
  if not innermost then
    return false -- parsed, but the line is outside any named container
  end
  local s, e = lines(innermost)
  return { symbol = path, start_line = s, end_line = e }
end

local function ts_all(bufnr)
  local tree = ts_tree(bufnr)
  if not tree then
    return nil
  end
  local out = {}
  local function walk(node, path)
    for child in node:iter_children() do
      if child:named() then
        local p = path
        if is_container(child:type()) then
          local name = name_of(child, bufnr)
          if name then
            p = vim.list_extend(vim.list_slice(path), { name })
            local s, e = lines(child)
            out[#out + 1] = { symbol = p, start_line = s, end_line = e }
          end
        end
        walk(child, p)
      end
    end
  end
  walk(tree:root(), {})
  return out
end

-- LSP SymbolKind values that are containers.
local LSP_KINDS = { [2] = true, [3] = true, [5] = true, [6] = true, [9] = true, [10] = true, [11] = true, [12] = true, [23] = true }

local function lsp_all(bufnr)
  if #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" }) == 0 then
    return nil
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local res = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 500)
  local out = {}
  local function add(path, kind, range)
    if LSP_KINDS[kind] and range then
      out[#out + 1] = { symbol = path, start_line = range.start.line + 1, end_line = range["end"].line + 1 }
    end
  end
  local function walk(items, path)
    for _, item in ipairs(items or {}) do
      if item.range then -- DocumentSymbol
        local p = vim.list_extend(vim.list_slice(path), { item.name })
        add(p, item.kind, item.range)
        walk(item.children, p)
      elseif item.location then -- SymbolInformation (flat)
        local p = item.containerName and item.containerName ~= "" and { item.containerName, item.name } or { item.name }
        add(p, item.kind, item.location.range)
      end
    end
  end
  for _, r in pairs(res or {}) do
    walk(r.result, {})
  end
  return out
end

--- All named containers in the buffer.
function M.all(bufnr)
  return ts_all(bufnr) or lsp_all(bufnr) or {}
end

--- The innermost named container around `line`, or nil.
function M.at(bufnr, line)
  local found = ts_at(bufnr, line)
  if found ~= nil then
    return found or nil
  end
  local best
  for _, s in ipairs(lsp_all(bufnr) or {}) do
    if s.start_line <= line and line <= s.end_line then
      if not best or (s.end_line - s.start_line) < (best.end_line - best.start_line) then
        best = s
      end
    end
  end
  return best
end

return M
