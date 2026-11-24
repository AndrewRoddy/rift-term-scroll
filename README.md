# rift-term-scroll

Move through a terminal's output like a buffer, the way Neovim does.

Press `<A-a>` in a terminal. Its whole history (up to rift's 10,000 lines)
opens as a buffer in the same window, where every motion, search, Visual mode
and yank works. Press `i` to go back to the live terminal and keep typing.

rift's own terminal buffer is only the visible screen, so this is a copy:

- Output printed after you press `<A-a>` isn't in it. Go back and press it again.
- It has no colors: plugins can't read them.
- Edits to it do nothing to the terminal, and it's deleted when you go back.
- Anything that enters Insert mode (`i`, `a`, `o`, `c`) goes back.
- Full-screen programs (vim, htop) have no history, so you get their screen.

## Without the copy

rift's `<C-\>` still leaves terminal mode with no copy made.
In terminal-normal mode this plugin adds:

| Key | Does |
|---|---|
| `k` / `<Up>` | Move up; on the top row, scroll the history up 5 lines |
| `j` / `<Down>` | Move down; on the bottom row, scroll back down 5 lines |
| `<C-y>` / `<C-e>` | Scroll up / down 5 lines |
| `<C-b>` / `<C-f>` | Scroll up / down 20 lines |
| `<PageUp>` / `<PageDown>` | Scroll up / down 20 lines |
| `gg` / `G` | Scroll to the top of the history / back to the bottom |

rift's own `<C-u>` / `<C-d>` (10 lines) still work, in terminal mode too.
Press `i` and type anything to jump back to the bottom.

rift only has 5- and 20-line scroll steps and no "top of history" action,
so `gg` / `G` page 500 times (enough for rift's 10,000-line history). rift
doesn't capture the mouse wheel.

## Options

```lua
{ "AndrewRoddy/rift-term-scroll", opts = {
  edge_scroll = true,               -- k/j scroll at the top/bottom row
  buffer_key = "<A-a>",             -- opens the history; false to disable
  jump = true,                      -- gg / G; false to disable
  jump_steps = 500,                 -- 20-line pages gg / G scroll
  keys = {
    ["<C-b>"] = false,              -- drop a default map
    ["<A-k>"] = "terminal:scroll_up",
  },
} },
```

## Install

rift-term-scroll installs through riftpm. Install riftpm first from
[Monster0506/riftpm](https://github.com/Monster0506/riftpm) (see its README),
then add rift-term-scroll to your `plugins.lua` spec:

```lua
{ "AndrewRoddy/rift-term-scroll" },
```

Run `:PluginSync` to clone it.

Tested with rift 0.7.8 (`bash tests/buffer.sh`).
