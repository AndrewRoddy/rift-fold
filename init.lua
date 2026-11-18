-- rift-fold: folding by indent, with Vim's keys (zc zo za zR zM).
--
-- rift has no way to hide lines. It draws every line in the buffer, and
-- conceal only works inside a line. So closing a fold actually cuts its
-- lines out of the buffer and keeps them here. The fold's first line stays,
-- with "··· N lines" after it, and opening the fold puts the lines back.
--
-- Since the lines really are gone, saving would write the file without
-- them. So after every save they get written back into the file on disk,
-- and the file always has all of its text, even while folded.
--
-- Folds work like Vim's foldmethod=indent: a fold is the lines under a line
-- that are indented more than it. If nothing under the cursor line is
-- indented more, it's the fold the cursor is inside. A closing line like
-- `}`, `)`, `end` or `</tag>` at the same indent as the first line gets
-- folded too.
local M = {}
-- rift-conform looks for this to skip buffers with closed folds.
package.loaded["rift-fold"] = M

local KIND = "fold.closed"

local opts = {
  -- Shown after a closed fold's first line. %d is how many lines it hides.
  text = "  ··· %d lines",
  style = { fg = "#928374", italic = true },
  keys = true,
}

-- The closed folds in each buffer, by the id of the annotation that marks
-- them: folds[buf][id] = { lines = the hidden lines, seen = ... }.
local folds = {}

local function buf_folds(buf)
  folds[buf] = folds[buf] or {}
  return folds[buf]
end

local function is_blank(line) return line:match("^%s*$") ~= nil end

local function indent_of(line)
  local tw = rift.get_tab_width() or 4
  local n = 0
  for c in line:gmatch(".") do
    if c == " " then n = n + 1
    elseif c == "\t" then n = n + tw - (n % tw)
    else break end
  end
  return n
end

local function is_closer(line)
  local s = line:match("^%s*(.-)%s*$")
  return s:match("^[%]%)}]+[%)%],;]*$") ~= nil
    or s:match("^end[%s%),;]*$") ~= nil
    or s:match("^</[%w%-%.:_]+>$") ~= nil
end

-- Where each line starts, as a byte offset, since annotations are placed
-- by byte.
local function line_starts(lines)
  local starts, off = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = off
    off = off + #l + 1
  end
  return starts
end

-- Which line byte offset `off` is on.
local function line_at(starts, lines, off)
  local lo, hi = 1, #lines
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if starts[mid] <= off then lo = mid else hi = mid - 1 end
  end
  return lo
end

-- Which line a fold's lines go back in front of. A fold's annotation sits at
-- the end of its first line, so normally that's the next line. If the first
-- line was deleted, the annotation moves to the start of the next line and
-- the lines go back in front of that one. (A fold's first line is never
-- blank, so the annotation is only at the start of a line if that happened.)
local function insert_line(starts, lines, off)
  local row = line_at(starts, lines, off)
  if off == starts[row] then
    return row, nil
  end
  return row + 1, row
end

-- The current buffer's closed folds, bottom one first. `L` is the line they
-- go back in front of, and `header` is their first line.
local function closed_folds(lines, starts)
  local list = {}
  local recs = folds[rift.current_buf()]
  if not recs then return list end
  for id, rec in pairs(recs) do
    local a = rift.annotations.get(id)
    if a then
      local L, header = insert_line(starts, lines, a.start)
      list[#list + 1] = { id = id, rec = rec, L = L, header = header }
    end
  end
  table.sort(list, function(x, y) return x.L > y.L end)
  return list
end

local function drop(buf, id)
  rift.annotations.remove(id)
  if folds[buf] then folds[buf][id] = nil end
end

-- Forget folds that aren't there any more. Pressing `u` after closing a
-- fold puts its lines back, and reloading the file can drop an annotation.
local function validate()
  local buf = rift.current_buf()
  local recs = folds[buf]
  if not recs or next(recs) == nil then return end
  local lines = rift.get_lines(1, -1)
  local starts = line_starts(lines)
  for id, rec in pairs(recs) do
    local a = rift.annotations.get(id)
    if not a then
      if rec.seen then recs[id] = nil end
    else
      rec.seen = true
      local L = insert_line(starts, lines, a.start)
      local same = L + #rec.lines - 1 <= #lines
      for i = 1, #rec.lines do
        if not same or lines[L + i - 1] ~= rec.lines[i] then same = false; break end
      end
      if same then drop(buf, id) end
    end
  end
end

-- Make several edits one undo step. rift groups edits made in Insert mode.
local function grouped(fn)
  local wrap = rift.get_mode() == "normal"
  if wrap then rift.exec_action("mode:insert") end
  fn()
  if wrap then rift.exec_action("mode:normal") end
end

-- Put the `stored` lines back in front of line L.
local function put_back(lines, L, stored)
  local n = #lines
  if L <= n and not (L == n and lines[L] == "") then
    rift.set_cursor(L, 0)
    rift.insert(table.concat(stored, "\n") .. "\n")
  elseif L == n then
    -- The cursor can't go on the empty line after the file's last newline,
    -- so add them at the end instead. append_lines doesn't add a newline.
    local out = { table.unpack(stored) }
    out[#out + 1] = ""
    rift.append_lines(out)
  else
    local out = { "" }
    for _, l in ipairs(stored) do out[#out + 1] = l end
    rift.append_lines(out)
  end
end

-- The fold that starts on line `h`, as { s = h, e = its last line }, or nil.
local function block_from(lines, h)
  if is_blank(lines[h]) then return nil end
  local hi = indent_of(lines[h])
  local e, i = h, h + 1
  while i <= #lines do
    if not is_blank(lines[i]) then
      if indent_of(lines[i]) <= hi then break end
      e = i
    end
    i = i + 1
  end
  if e == h then return nil end
  local j = e + 1
  while j <= #lines and is_blank(lines[j]) do j = j + 1 end
  if j <= #lines and indent_of(lines[j]) == hi and is_closer(lines[j]) then e = j end
  return { s = h, e = e }
end

-- The fold for a cursor on `row`: the one starting there, or else the one
-- it's inside.
local function block_at(lines, row)
  local b = block_from(lines, row)
  if b then return b end
  local r = row
  while r <= #lines and is_blank(lines[r]) do r = r + 1 end
  if r > #lines then return nil end
  local ind = indent_of(lines[r])
  if is_closer(lines[r]) then ind = ind + 1 end -- a `}` goes with the fold above it
  for h = row - 1, 1, -1 do
    if not is_blank(lines[h]) and indent_of(lines[h]) < ind then
      b = block_from(lines, h)
      if b and b.e >= row then return b end
      if not b then return nil end
      ind = indent_of(lines[h])
    end
  end
  return nil
end

-- Close fold b. Any closed folds inside it (from `closed`) become part of
-- it, so opening b shows everything again.
local function close_block(lines, starts, b, closed)
  local buf = rift.current_buf()
  local stored = {}
  for i = b.s + 1, b.e do
    for _, f in ipairs(closed) do
      if not f.header and f.L == i then
        for _, l in ipairs(f.rec.lines) do stored[#stored + 1] = l end
        drop(buf, f.id)
      end
    end
    stored[#stored + 1] = lines[i]
    for _, f in ipairs(closed) do
      if f.L == i + 1 and f.header == i then
        for _, l in ipairs(f.rec.lines) do stored[#stored + 1] = l end
        drop(buf, f.id)
      end
    end
  end

  if b.e < #lines then
    rift.replace_lines(b.s + 1, b.e, {})
  else
    -- The fold goes to the end of a file with no newline at the end, so
    -- take the newline after its first line too.
    rift.replace_lines(b.s, b.e, { lines[b.s] })
  end

  local id = rift.annotations.add{
    kind = KIND,
    point = starts[b.s] + #lines[b.s],
    stickiness = "persist",
    adornment = { text = string.format(opts.text, #stored), placement = "trailing",
                  style = opts.style },
  }
  buf_folds(buf)[id] = { lines = stored, seen = false }
end

local function fold_on(closed, row)
  for _, f in ipairs(closed) do
    if f.header == row or (not f.header and f.L == row) then return f end
  end
end

local function context()
  if rift.buf_kind() ~= "file" then return nil end
  validate()
  local lines = rift.get_lines(1, -1)
  local starts = line_starts(lines)
  return lines, starts, closed_folds(lines, starts)
end

function M.close()
  local lines, starts, closed = context()
  if not lines then return end
  local row, col = rift.get_cursor()
  local b = block_at(lines, row)
  if not b then return end
  grouped(function() close_block(lines, starts, b, closed) end)
  rift.set_cursor(b.s, col)
end

function M.open()
  local lines, _, closed = context()
  if not lines then return end
  local row, col = rift.get_cursor()
  local f = fold_on(closed, row)
  if not f then return end
  grouped(function() put_back(lines, f.L, f.rec.lines) end)
  drop(rift.current_buf(), f.id)
  rift.set_cursor(row, col)
end

function M.toggle()
  local lines, _, closed = context()
  if not lines then return end
  local row = rift.get_cursor()
  if fold_on(closed, row) then M.open() else M.close() end
end

function M.open_all()
  local lines, _, closed = context()
  if not lines or #closed == 0 then return end
  local row, col = rift.get_cursor()
  local buf = rift.current_buf()
  -- Bottom to top, so the line numbers above don't change.
  grouped(function()
    for _, f in ipairs(closed) do put_back(lines, f.L, f.rec.lines) end
  end)
  -- Keep the cursor on the same text.
  for _, f in ipairs(closed) do
    if f.L <= row then row = row + #f.rec.lines end
    drop(buf, f.id)
  end
  rift.set_cursor(row, col)
end

function M.close_all()
  local lines, starts, closed = context()
  if not lines then return end
  local row, col = rift.get_cursor()
  local blocks, r = {}, 1
  while r <= #lines do
    local b = block_from(lines, r)
    if b then blocks[#blocks + 1] = b; r = b.e + 1 else r = r + 1 end
  end
  if #blocks == 0 then return end
  grouped(function()
    for i = #blocks, 1, -1 do close_block(lines, starts, blocks[i], closed) end
  end)
  for i = #blocks, 1, -1 do
    local b = blocks[i]
    if row > b.e then row = row - (b.e - b.s)
    elseif row > b.s then row = b.s end
  end
  rift.set_cursor(row, col)
end

function M.has_folds(buf)
  local recs = folds[buf or rift.current_buf()]
  return recs ~= nil and next(recs) ~= nil
end

-- rift just saved the folded buffer, so put the hidden lines back into the
-- file.
local function restore_file(ev)
  if not M.has_folds(ev.buf) or rift.current_buf() ~= ev.buf or not ev.path then return end
  local lines = rift.get_lines(1, -1)
  local closed = closed_folds(lines, line_starts(lines))
  if #closed == 0 then return end

  local f = io.open(ev.path, "rb")
  if not f then return end
  local data = f:read("a")
  f:close()

  local crlf = rift.get_line_ending() == "crlf"
  local parts, pos = {}, 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then parts[#parts + 1] = data:sub(pos); break end
    local line = data:sub(pos, nl - 1)
    if crlf then line = line:gsub("\r$", "") end
    parts[#parts + 1] = line
    pos = nl + 1
  end

  -- The file has the same lines as the buffer. Go bottom to top.
  for _, c in ipairs(closed) do
    for i = #c.rec.lines, 1, -1 do
      table.insert(parts, math.min(c.L, #parts + 1), c.rec.lines[i])
    end
  end

  f = io.open(ev.path, "wb")
  if not f then
    rift.notify("error", "rift-fold: couldn't write folded lines back to " .. ev.path)
    return
  end
  f:write(table.concat(parts, crlf and "\r\n" or "\n"))
  f:close()
end

-- Maps go through `:lua` because that's when rift updates the cursor and
-- lines that plugins see. Mapping `editor:run:FoldClose` directly would see
-- the cursor from before the last motion. _rift_commands holds the commands
-- plugins have registered.
local function map(mode, keys, name)
  rift.map(mode, keys, string.format("editor:run:lua _rift_commands[%q].fn({})", name))
end

function M.setup(user_opts)
  for k, v in pairs(user_opts or {}) do opts[k] = v end

  rift.register_command("FoldClose", M.close, "Close the fold under the cursor")
  rift.register_command("FoldOpen", M.open, "Open the fold under the cursor")
  rift.register_command("FoldToggle", M.toggle, "Toggle the fold under the cursor")
  rift.register_command("FoldOpenAll", M.open_all, "Open every fold")
  rift.register_command("FoldCloseAll", M.close_all, "Close every top-level block")

  if opts.keys then
    map("n", "zc", "FoldClose")
    map("n", "zo", "FoldOpen")
    map("n", "za", "FoldToggle")
    map("n", "zR", "FoldOpenAll")
    map("n", "zM", "FoldCloseAll")
  end

  if M._registered then return end
  M._registered = true
  rift.on("BufSavePost", restore_file)
  rift.on("TextChangedCoarse", validate)
  rift.on("CursorHold", validate)
  rift.on("BufClose", function(ev) folds[ev.buf] = nil end)
end

return M
