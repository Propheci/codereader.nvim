-- Renderer: walks a component tree depth-first into flat lines + decoration
-- tables + a line->component index. There is no diffing; each render rebuilds
-- everything. The index is what lets interaction code ask "what object is under
-- the cursor?" without parsing buffer text.

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(layout)
  return setmetatable({
    layout = layout,
    out = {
      lines = {}, -- string[]
      highlights = {}, -- { line(0-based), col_start, col_end, group }
      line_highlights = {}, -- { line(0-based), group }
    },
    index = {}, -- line(1-based) -> innermost component on that line
  }, Renderer)
end

-- Render a `row`/`text` subtree inline: returns the concatenated string and the
-- highlight spans (columns relative to the start of the returned string).
function Renderer:inline(node, parent)
  node.parent = parent
  if node.tag == "text" then
    local s = tostring(node.value)
    local spans = {}
    local hl = node:get_highlight()
    if hl and #s > 0 then
      spans[#spans + 1] = { col_start = 0, col_end = #s, group = hl }
    end
    return s, spans
  elseif node.tag == "row" then
    local parts, spans = {}, {}
    local offset = 0
    for _, child in ipairs(node.children) do
      local s, child_spans = self:inline(child, node)
      for _, span in ipairs(child_spans) do
        spans[#spans + 1] = {
          col_start = span.col_start + offset,
          col_end = span.col_end + offset,
          group = span.group,
        }
      end
      parts[#parts + 1] = s
      offset = offset + #s
    end
    return table.concat(parts), spans
  end
  error("row children must be `text` or `row`, got: " .. tostring(node.tag))
end

function Renderer:emit_line(text, spans, node)
  local line_no = #self.out.lines + 1
  self.out.lines[line_no] = text
  for _, span in ipairs(spans) do
    self.out.highlights[#self.out.highlights + 1] = {
      line = line_no - 1,
      col_start = span.col_start,
      col_end = span.col_end,
      group = span.group,
    }
  end
  local line_hl = node:get_line_highlight()
  if line_hl then
    self.out.line_highlights[#self.out.line_highlights + 1] = { line = line_no - 1, group = line_hl }
  end
  node.position = { row = line_no }
  self.index[line_no] = node
end

-- Render a block-level node: `col` recurses; `row`/`text` emit a line.
function Renderer:block(node, parent)
  node.parent = parent
  if node.tag == "col" then
    for _, child in ipairs(node.children) do
      self:block(child, node)
    end
  else
    local text, spans = self:inline(node, parent)
    self:emit_line(text, spans, node)
  end
end

function Renderer:render()
  for _, child in ipairs(self.layout) do
    self:block(child, nil)
  end
  return self.out, self.index
end

return Renderer
