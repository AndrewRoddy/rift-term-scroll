-- rift-term-scroll: move through a terminal's output like a buffer, the way
-- Neovim's terminal-normal mode does.
--
-- In rift a terminal buffer is only what's on screen, and it's rewritten
-- whenever the shell prints something. So Alt+a (`buffer_key`) pages through
-- the history, copies it into a scratch buffer and shows that in the
-- terminal's window. Every motion, search, Visual mode and yank works there
-- because it's an ordinary buffer. `i` (or anything else that enters Insert
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
  -- Opens the history as a buffer, from terminal and terminal-normal mode.
  -- false to disable.
  buffer_key = "<A-a>",
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

local views = {} -- copy's buffer id -> terminal's buffer id
local cap        -- the capture in progress

local function run(name)
  rift.exec_action(string.format("editor:run:lua _rift_commands[%q].fn({})", name))
end

-- The visible screen. Trailing spaces go: rift pads the cursor's line.
local function read_screen()
  local lines = rift.get_lines(1, -1)
  for i, l in ipairs(lines) do lines[i] = l:gsub("%s+$", "") end
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

-- Queues `n` pages, each followed by `step`. Reads only see a scroll once
-- it has been applied, and `:lua` refreshes them. The pages are queued up
-- front because rift allows only 16 rounds of queueing from one key press;
-- each batch is bigger than the last so the whole history fits.
local function queue_pages(dir, n, step, after)
  for _ = 1, n do
    rift.exec_action(dir < 0 and cap.up or cap.down)
    run(step)
  end
  run(after)
end

-- Called after each page. cap.done: this page didn't move the screen, so it's
-- at the end. A screen that repeats every page (`yes` output, say) looks the
-- same either way, so then we can't tell and keep going.
local function page()
  if not cap then return end
  local old, new = cap.screen, read_screen()
  cap.screen = new
  if shifted(old, new, 0) then
    if shifted(old, new, cap.size) then
      cap.repeats = cap.repeats + 1
    else
      cap.done = true
    end
    return old, new, true
  end
  cap.done = false
  return old, new, false
end

function M._page_down() page() end

function M._page_up()
  local old, new, same = page()
  if not old or same then return end
  -- Repeating pages we passed were real, now that there's more above them.
  for _ = 1, cap.repeats do
    for i = cap.size, 1, -1 do cap.rev[#cap.rev + 1] = old[i] end
  end
  cap.pages = cap.pages + cap.repeats + 1
  cap.repeats = 0
  -- The last page before the top can be a short one.
  local k = cap.size
  while k > 0 and not shifted(old, new, k) do k = k - 1 end
  if k == 0 then k = cap.size end -- the screen changed under us
  for i = k, 1, -1 do cap.rev[#cap.rev + 1] = new[i] end
end

-- First get to the bottom, in case the terminal was already scrolled up.
function M._down_done()
  if not cap then return end
  if not cap.done and cap.queued < cap.max then
    local n = math.min(cap.queued * 8, cap.max)
    cap.queued = cap.queued + n
    return queue_pages(1, n, "TermScrollPageDown", "TermScrollDownDone")
  end
  -- At the bottom the cursor is the shell's own.
  cap.bottom = cap.screen
  cap.prompt = rift.get_cursor()
  cap.done, cap.repeats, cap.queued = false, 0, 4
  queue_pages(-1, 4, "TermScrollPageUp", "TermScrollUpDone")
end

function M._up_done()
  if not cap then return end
  if not cap.done and cap.queued < cap.max then
    local n = math.min(cap.queued * 2, cap.max)
    cap.queued = cap.queued + n
    return queue_pages(-1, n, "TermScrollPageUp", "TermScrollUpDone")
  end

  local c = cap
  cap = nil
  -- Put the terminal back at the bottom for when we return to it.
  for _ = 1, c.pages + c.repeats do rift.exec_action(c.down) end

  local lines = {}
  for i = #c.rev, 1, -1 do lines[#lines + 1] = c.rev[i] end
  local above = #lines
  -- Skip the empty screen below the prompt.
  local last = #c.bottom
  while last > c.prompt and c.bottom[last] == "" do last = last - 1 end
  for i = 1, last do lines[#lines + 1] = c.bottom[i] end

  -- Show what was on screen: find it, newest first.
  local top, row, col = above, above + c.prompt, c.col
  if not shifted(c.start, c.bottom, 0) then
    for t = above, 0, -1 do
      local same = true
      for i = 1, #c.start do
        if (lines[t + i] or "") ~= c.start[i] then
          same = false
          break
        end
      end
      if same then
        top, row, col = t, math.min(t + #c.start, #lines), 0
        break
      end
    end
  end

  -- A copy of this terminal left open earlier is out of date.
  for view, term in pairs(views) do
    if term == c.term then
      views[view] = nil
      for _, b in ipairs(rift.get_buf_list()) do
        if b.id == view then rift.close_buf(true, { buf = view }) end
      end
    end
  end

  local view = rift.create_scratch_buf("terminal history", lines)
  views[view] = c.term
  -- Line numbers would push full-width lines past the edge of the window.
  rift.set_option("number", "off", { buf = view })
  rift.set_cursor(row, col, { buf = view })
  rift.set_scroll(top, 0)
end

-- Alt+a in a terminal.
function M.open()
  if rift.buf_kind() ~= "terminal" then return end
  local screen = read_screen()
  local _, col = rift.get_cursor()
  local big = #screen >= 20
  local size = big and 20 or 5
  cap = {
    term = rift.current_buf(),
    size = size,
    up = big and "terminal:scroll_page_up" or "terminal:scroll_up",
    down = big and "terminal:scroll_page_down" or "terminal:scroll_down",
    max = math.ceil(HISTORY / size) + 1,
    start = screen, screen = screen, col = col,
    rev = {}, pages = 0, repeats = 0, queued = 1, done = false,
  }
  rift.exec_action("terminal:exit")
  queue_pages(1, 1, "TermScrollPageDown", "TermScrollDownDone")
end

-- Back to the live terminal, ready to type.
function M.back()
  local view = rift.current_buf()
  local term = views[view]
  if not term then return end
  for _, b in ipairs(rift.get_buf_list()) do
    if b.id == term then
      views[view] = nil
      rift.exec_action("mode:normal")
      rift.switch_buf(term)
      rift.close_buf(true, { buf = view })
      rift.exec_action("mode:insert")
      return
    end
  end
  rift.exec_action("mode:normal")
  rift.notify("info", "That terminal has closed")
end

local function setup_buffer(key)
  rift.register_command("TermScrollPageDown", M._page_down, "rift-term-scroll internal")
  rift.register_command("TermScrollPageUp", M._page_up, "rift-term-scroll internal")
  rift.register_command("TermScrollDownDone", M._down_done, "rift-term-scroll internal")
  rift.register_command("TermScrollUpDone", M._up_done, "rift-term-scroll internal")
  rift.register_command("TermScrollOpen", M.open, "Open the terminal's history as a buffer")
  rift.register_command("TermScrollBack", M.back, "Go back to the live terminal")
  map("t", key, "TermScrollOpen")
  map("tn", key, "TermScrollOpen")
  -- However Insert mode is entered (i, a, o, c...), it goes back.
  rift.on("ModeChanged", function(ev)
    if ev.to == "insert" and views[rift.current_buf()] then run("TermScrollBack") end
  end)
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
  if buffer_key then setup_buffer(buffer_key) end
end

return M
