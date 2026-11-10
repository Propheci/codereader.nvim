-- Declarative component DSL: `text`, `row`, `col` with chainable options.
--
-- Ported (lean) from Neogit's component system. A component is a builder you
-- "call" to instantiate; unknown field accesses return option-setter closures so
-- options read declaratively:
--
--   text.highlight("CodeReaderTitle")("hello")
--   --   └ option setter ────────┘└ value (instantiates)
--
-- Options inherit from the parent (see `get_highlight` / `get_line_highlight`),
-- so a color set on a row/col cascades to children unless overridden.

local Component = {}
Component.__index = Component

--- Nearest `highlight` walking up the parent chain.
function Component:get_highlight()
  local node = self
  while node do
    if node.options.highlight then
      return node.options.highlight
    end
    node = node.parent
  end
end

--- Nearest whole-line highlight walking up the parent chain.
function Component:get_line_highlight()
  local node = self
  while node do
    if node.options.line_hl then
      return node.options.line_hl
    end
    node = node.parent
  end
end

--- Walk up the parent chain returning the first ancestor (or self) matching `fn`.
function Component:find_parent(fn)
  local node = self
  while node do
    if fn(node) then
      return node
    end
    node = node.parent
  end
end

local function make_builder(factory, options)
  return setmetatable({}, {
    -- `.name(value)` accretes one option and returns a fresh builder.
    __index = function(_, key)
      return function(value)
        local next_options = vim.deepcopy(options)
        next_options[key] = value
        return make_builder(factory, next_options)
      end
    end,
    -- Calling the builder instantiates the node, merging accumulated options
    -- under any inline options the factory set (inline wins).
    __call = function(_, ...)
      local node = factory(...)
      node.options = vim.tbl_extend("force", vim.deepcopy(options), node.options or {})
      return setmetatable(node, Component)
    end,
  })
end

local M = {}

--- Wrap a factory `f(...) -> node` in the chainable builder metatable.
function M.new(factory)
  return make_builder(factory, {})
end

--- A leaf rendering a string. `text("hi")` or `text("hi", { highlight = "X" })`.
M.text = M.new(function(value, options)
  return { tag = "text", value = value or "", options = options or {} }
end)

--- Lays children horizontally on one line. Children must be `text` or `row`.
M.row = M.new(function(children)
  return { tag = "row", children = children or {} }
end)

--- Stacks children vertically; each child renders on its own line(s).
M.col = M.new(function(children)
  return { tag = "col", children = children or {} }
end)

--- Convenience: a blank line.
M.EmptyLine = M.text("")

return M
