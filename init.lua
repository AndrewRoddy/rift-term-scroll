-- rift-term-scroll: move through a terminal's output like a buffer, the way
-- Neovim's terminal-normal mode does.
--
-- In rift a terminal buffer is only what's on screen, and it's rewritten
-- whenever the shell prints something. So Alt+a (`buffer_key`) in
-- terminal-normal mode (Alt+a twice, if it's also what leaves terminal mode)
-- pages through
-- the history, copies it into a scratch buffer and shows that in the
-- terminal's window, updating it as the shell prints more. Every motion,
-- search, Visual mode and yank works there because it's an ordinary buffer. `i` (or anything else that enters Insert
-- mode) goes back to the live terminal and deletes the copy.
--
-- Leaving terminal mode with rift's own <C-\> doesn't make a copy. For that,
-- the usual Vim scroll keys are put on rift's terminal:scroll_* actions in
-- terminal-normal mode ("tn"), and `k` / `j` scroll at the screen's edges.
--
-- rift only scrolls in fixed steps: 5 lines with terminal:scroll_up/down and
-- 20 with terminal:scroll_page_up/down.
local M = {}

local defaults = {
  -- `k` on the top row and `j` on the bottom row scroll the history.
  edge_scroll = true,
  -- Opens the history as a buffer, from terminal-normal mode.
  -- false to disable.
  buffer_key = "<A-a>",
  -- How often the open copy is brought up to date, in milliseconds.
  update_ms = 100,
  -- More terminal-normal maps, key -> action. Set a key to false to drop it.
  keys = {
    ["<C-y>"] = "terminal:scroll_up",
    ["<C-e>"] = "terminal:scroll_down",
    ["<C-b>"] = "terminal:scroll_page_up",
    ["<C-f>"] = "terminal:scroll_page_down",
    ["<PageUp>"] = "terminal:scroll_page_up",
    ["<PageDown>"] = "terminal:scroll_page_down",
  },
}

-- Maps go through `:lua` because that's when rift updates the cursor and
-- line count that plugins see. Mapping `editor:run:TermScrollUp` directly
-- would see the cursor from before the last motion. _rift_commands holds
-- the commands plugins have registered.
local function map(mode, keys, name)
  rift.map(mode, keys, string.format("editor:run:lua _rift_commands[%q].fn({})", name))
end

local edge_scroll = true

-- Scrolling rebuilds the terminal buffer and moves the cursor, so put it
-- back on the edge row afterwards. That way holding `k` keeps scrolling
-- instead of the cursor jumping around.
local function edge_move(dir)
  if rift.buf_kind() ~= "terminal" then
    rift.exec_action(dir < 0 and "editor:move:up" or "editor:move:down")
    return
  end
  local row, col = rift.get_cursor()
  local last = rift.get_line_count()
  if not edge_scroll then
    rift.exec_action(dir < 0 and "editor:move:up" or "editor:move:down")
  elseif dir < 0 and row <= 1 then
    rift.exec_action("terminal:scroll_up")
    rift.set_cursor(1, col)
  elseif dir > 0 and row >= last then
    rift.exec_action("terminal:scroll_down")
    rift.set_cursor(last, col)
  else
    rift.exec_action(dir < 0 and "editor:move:up" or "editor:move:down")
  end
end

function M.up() edge_move(-1) end
function M.down() edge_move(1) end

-- rift can't scroll straight to the top or bottom, so page enough times to
-- cover the whole history: 10,000 lines (alacritty's default) at 20 a page.
-- Paging past the end does nothing, so extra pages don't hurt.
local jump_steps = 500

local function jump(dir)
  if rift.buf_kind() ~= "terminal" then return end
  local action = dir < 0 and "terminal:scroll_page_up" or "terminal:scroll_page_down"
  for _ = 1, jump_steps do rift.exec_action(action) end
  local _, col = rift.get_cursor()
  rift.set_cursor(dir < 0 and 1 or rift.get_line_count(), col)
end

function M.top() jump(-1) end
function M.bottom() jump(1) end

---------------------------------------------------------------------------
-- The history as a buffer
---------------------------------------------------------------------------

local HISTORY = 10000 -- alacritty's default, which rift uses
local PEEK = "termscroll.peek"

-- The open copy, or nil. buf, term: buffer ids. hist: the lines above the
-- terminal's screen, which never change again. screen: the screen's lines.
-- lines: what's in the copy (hist, then the screen).
local view
local cap                -- the sync in progress
local update_ms = 100
local mode = "normal"    -- from ModeChanged, which tells operator-pending apart
local hold               -- timer id while syncing waits

local function run(name)
  rift.exec_action(string.format("editor:run:lua _rift_commands[%q].fn({})", name))
end

-- Reading the terminal. rift refreshes a terminal's text only while it's
-- shown in a window, or when a scroll action runs in it; and a scroll action
-- draws a frame. So: switch to the terminal, scroll, and switch back at the
-- start of that frame, before anything is drawn. A cursor-enter hook is what
-- runs there: the annotation is new each time, so the cursor always "enters"
-- it. Events like CursorMoved would work too, but other plugins listen to
-- those.
--
-- Each hook uses up one of rift's 16 rounds of queueing, so that's for small
-- updates (HIDDEN pages). More than that is read in the terminal, with the
-- scrolling briefly on screen (cap.plain).
local HIDDEN = 3

local function peek(action)
  if cap.plain then
    rift.exec_action(action)
    run("TermScrollPeeked")
    return
  end
  local term = { buf = view.term }
  rift.switch_buf(view.term)
  rift.annotations.clear(PEEK, term)
  rift.annotations.add({ kind = PEEK, range = { 0, 10000000 }, buf = view.term })
  rift.exec_action(action)
  run("TermScrollPeeked") -- in case the hook didn't run
end

-- The visible screen. Trailing spaces go: rift pads the cursor's line.
local function read_screen()
  local lines = rift.get_lines(1, -1)
  for i, l in ipairs(lines) do lines[i] = (l:gsub("%s+$", "")) end
  return lines
end

-- Whether `new` is `old` with `k` lines scrolled in at the top.
local function shifted(old, new, k)
  if #old ~= #new then return false end
  for i = 1, #old - k do
    if old[i] ~= new[i + k] then return false end
  end
  return true
end

local function copy(t) return table.move(t, 1, #t, 1, {}) end

-- The terminal is synced and active: read it, then go back.
function M._peeked()
  if not cap or not view or rift.current_buf() ~= view.term then return end
  local old, new = cap.screen, read_screen()
  local row, col = rift.get_cursor()
  if not cap.plain then
    rift.annotations.clear(PEEK, { buf = view.term })
    rift.switch_buf(view.buf)
  end
  cap.screen = new
  cap.row, cap.col = row, col

  -- cap.done: this page didn't move the screen, so it's at the end. A screen
  -- that repeats every page (`yes` output, say) looks the same either way,
  -- so then we can't tell and keep going.
  cap.done = false
  if not old then return end
  if shifted(old, new, 0) then
    if shifted(old, new, cap.size) then
      cap.repeats = cap.repeats + 1
    else
      cap.done = true
    end
    return
  end
  if cap.phase ~= "up" then return end
  -- Repeating pages we passed were real, now that there's more above them.
  for _ = 1, cap.repeats do
    for i = cap.size, 1, -1 do cap.rev[#cap.rev + 1] = old[i] end
  end
  cap.repeats = 0
  -- The last page before the top can be a short one.
  local k = cap.size
  while k > 0 and not shifted(old, new, k) do k = k - 1 end
  if k == 0 then k = cap.size end -- the screen changed under us
  for i = k, 1, -1 do cap.rev[#cap.rev + 1] = new[i] end
end

-- Queues `n` pages, then the next step. They're queued up front because rift
-- allows only 16 rounds of queueing at a time; each batch is bigger than the
-- last, so the whole history fits.
local function pages(action, n)
  cap.queued = cap.queued + n
  if cap.plain then rift.switch_buf(view.term) end
  for _ = 1, n do peek(action) end
  run("TermScrollStep")
end

-- How many of the lines just read are new history, given what we had: the
-- older ones must match the end of `hist`. nil if more has to be read.
local function new_lines(hist, rev, prev)
  local c = #rev -- rev[1] is the newest
  local found
  for d = 0, c do
    local overlap = math.min(c - d, #hist)
    if c - d > #hist and not cap.top then break end
    if overlap < math.min(8, #hist) then break end
    local same = c - d <= #hist
    for i = 1, overlap do
      if rev[d + i] ~= hist[#hist - i + 1] then
        same = false
        break
      end
    end
    if same then
      -- Lines that scrolled off were the top of the screen before, so prefer
      -- the count for which they still read the same.
      local match = true
      for i = 1, math.min(d, #prev) do
        if rev[d - i + 1] ~= prev[i] then
          match = false
          break
        end
      end
      if match then return d end
      found = found or d
    end
  end
  return found
end

-- Puts `lines` in the copy, changing only what's different, and keeps the
-- cursor where it was (or at the end, if it was on the last line).
local function show(lines, row, col)
  local opts = { buf = view.buf }
  local old = view.lines
  local count = rift.get_line_count(opts)
  if count ~= #old then old = rift.get_lines(1, -1, opts) end -- it was edited
  local first = 1
  while first <= #old and first <= #lines and old[first] == lines[first] do
    first = first + 1
  end
  local last_old, last_new = #old, #lines
  while last_old >= first and last_new >= first and old[last_old] == lines[last_new] do
    last_old, last_new = last_old - 1, last_new - 1
  end
  local changed = last_old >= first or last_new >= first
  if changed then
    -- Replace at least one line on each side, so it's never a pure insert
    -- or delete.
    if last_old < first or last_new < first then
      if first > 1 then
        first = first - 1
      else
        last_old, last_new = last_old + 1, last_new + 1
      end
    end
    local r, c = rift.get_cursor(opts)
    local follow = r >= #old
    rift.replace_lines(first, last_old, table.move(lines, first, last_new, 1, {}), opts)
    if view.fresh or follow then r, c = row, col end
    rift.set_cursor(math.min(r, #lines), c, opts)
  end
  view.lines = lines
end

local function pause(ms)
  if hold then rift.timer_stop(hold) end
  hold = rift.timer(ms, function() hold = nil end)
end

local function finish()
  local c = cap
  cap = nil
  local v = view
  if c.plain then
    rift.switch_buf(v.buf)
    if not v.fresh then pause(500) end -- lots of output: don't flash too often
  end
  -- Skip the empty screen below the prompt.
  local screen = c.bottom
  local last = #screen
  while last > c.prompt and screen[last] == "" do last = last - 1 end
  local lines = copy(v.hist)
  for i = 1, last do lines[#lines + 1] = screen[i] end
  local row, col = #v.hist + c.prompt, c.prompt_col

  if v.fresh then
    local top = #v.hist
    row, col = top + v.row, v.col
    -- If the terminal was scrolled up, show the same place: newest first.
    if not shifted(v.start, screen, 0) then
      for t = top, 0, -1 do
        local same = true
        for i = 1, #v.start do
          if (lines[t + i] or "") ~= v.start[i] then
            same = false
            break
          end
        end
        if same then
          top, row = t, t + v.row
          break
        end
      end
    end
    show(lines, row, col)
    rift.set_scroll(top, 0)
    v.fresh = false
  else
    show(lines, row, col)
  end
  v.screen = screen
end

-- Runs after each batch of pages and decides what's next.
function M._step()
  local c = cap
  if not c or not view then return end

  if c.phase == "down" then
    -- The first page is enough unless the terminal was scrolled up.
    if view.fresh and not c.done and c.queued < c.max then
      return pages(c.down, math.min(c.queued * 8, c.max))
    end
    -- At the bottom the cursor is the shell's own.
    c.bottom, c.prompt, c.prompt_col = c.screen, c.row, c.col
    if not c.bottom then
      cap = nil
      return
    end
    if not view.fresh and #c.bottom == #view.screen and shifted(view.screen, c.bottom, 0) then
      cap = nil
      return
    end
    c.phase, c.repeats, c.queued, c.done = "up", 0, 0, false
    return pages(c.up, view.fresh and 4 or 1)
  end

  if c.phase == "up" then
    c.top = c.done
    local d = not view.fresh and new_lines(view.hist, c.rev, view.screen)
    if not d and not c.top and c.queued < c.max then
      local n = math.min(c.queued * 2, c.max)
      if c.queued + n > HIDDEN then c.plain = true end
      return pages(c.up, n)
    end
    if d then
      for i = d, 1, -1 do view.hist[#view.hist + 1] = c.rev[i] end
    elseif #c.rev > 0 or view.fresh then
      -- First time, or it was resized: take it all again.
      view.hist = {}
      for i = #c.rev, 1, -1 do view.hist[#view.hist + 1] = c.rev[i] end
    end -- else no history at all: cleared, or a full-screen program. Keep ours.
    -- Put the terminal back at the bottom for when we return to it.
    c.phase, c.repeats = "back", 0
    local n = c.queued
    return pages(c.down, n)
  end

  finish()
end

local function sync()
  if cap or not view then return end
  local big = #view.start >= 20
  local size = big and 20 or 5
  cap = {
    phase = "down",
    size = size,
    up = big and "terminal:scroll_page_up" or "terminal:scroll_up",
    down = big and "terminal:scroll_page_down" or "terminal:scroll_down",
    max = math.ceil(HISTORY / size) + 1,
    rev = {}, repeats = 0, queued = 0, done = false, plain = view.fresh,
  }
  pages(cap.down, view.fresh and 2 or 1)
end

local function is_open(buf)
  for _, b in ipairs(rift.get_buf_list()) do
    if b.id == buf then return true end
  end
  return false
end

-- Only in Normal mode: a selection, a search or an operator shouldn't have
-- text change under it.
local function tick()
  if not view then return end
  if not is_open(view.buf) then
    view, cap = nil, nil
    return
  end
  if mode ~= "normal" or rift.current_buf() ~= view.buf then return end
  if hold or not is_open(view.term) then return end
  cap = nil
  sync()
end

-- Alt+a in terminal-normal mode.
function M.open()
  if rift.buf_kind() ~= "terminal" then return end
  local term = rift.current_buf()
  local screen = read_screen()
  local row, col = rift.get_cursor()
  rift.exec_action("terminal:exit")
  if view and is_open(view.buf) then rift.close_buf(true, { buf = view.buf }) end
  cap = nil
  local buf = rift.create_scratch_buf("terminal history", screen)
  view = {
    buf = buf, term = term, start = screen, screen = screen,
    lines = screen, hist = {}, fresh = true,
    row = row, col = col, -- the cursor stays where it was
  }
  -- Line numbers would push full-width lines past the edge of the window.
  rift.set_option("number", "off", { buf = buf })
  rift.set_cursor(row, col, { buf = buf })
  sync()
end

-- Back to the live terminal, ready to type.
function M.back()
  if not view or rift.current_buf() ~= view.buf then return end
  rift.exec_action("mode:normal")
  if not is_open(view.term) then
    rift.notify("info", "That terminal has closed")
    return
  end
  local v = view
  view, cap = nil, nil
  rift.switch_buf(v.term)
  rift.close_buf(true, { buf = v.buf })
  rift.exec_action("mode:insert")
end

local function setup_buffer(key)
  rift.register_command("TermScrollPeeked", M._peeked, "rift-term-scroll internal")
  rift.register_command("TermScrollStep", M._step, "rift-term-scroll internal")
  rift.register_command("TermScrollOpen", M.open, "Open the terminal's history as a buffer")
  rift.register_command("TermScrollBack", M.back, "Go back to the live terminal")
  map("tn", key, "TermScrollOpen")
  rift.annotations.on_enter(PEEK, M._peeked)
  -- However Insert mode is entered (i, a, o, c...), it goes back.
  rift.on("ModeChanged", function(ev)
    mode = ev.to
    if not view or rift.current_buf() ~= view.buf then return end
    if ev.to == "insert" then
      run("TermScrollBack")
    elseif ev.from:find("^visual") then
      -- rift-clipboard copies a Visual yank a moment after Visual mode ends,
      -- and not if the buffer changed in between.
      pause(1000)
    end
  end)
  rift.timer(update_ms, tick, { ["repeat"] = true })
end

function M.setup(opts)
  opts = opts or {}
  local keys = {}
  for k, v in pairs(defaults.keys) do keys[k] = v end
  for k, v in pairs(opts.keys or {}) do keys[k] = v end
  local edge = opts.edge_scroll
  if edge == nil then edge = defaults.edge_scroll end
  edge_scroll = edge

  for k, action in pairs(keys) do
    if action then rift.map("tn", k, action) end
  end

  if opts.jump_steps then jump_steps = opts.jump_steps end
  if opts.jump ~= false then
    rift.register_command("TermScrollTop", M.top, "Scroll to the top of the terminal history")
    rift.register_command("TermScrollBottom", M.bottom, "Scroll to the bottom of the terminal")
    map("tn", "gg", "TermScrollTop")
    map("tn", "G", "TermScrollBottom")
  end

  if edge then
    rift.register_command("TermScrollUp", M.up,
      "Move up; scroll the terminal history on the top row")
    rift.register_command("TermScrollDown", M.down,
      "Move down; scroll the terminal history on the bottom row")
    map("tn", "k", "TermScrollUp")
    map("tn", "j", "TermScrollDown")
    map("tn", "<Up>", "TermScrollUp")
    map("tn", "<Down>", "TermScrollDown")
  end

  local buffer_key = opts.buffer_key
  if buffer_key == nil then buffer_key = defaults.buffer_key end
  update_ms = opts.update_ms or defaults.update_ms
  if buffer_key then setup_buffer(buffer_key) end
end

return M
