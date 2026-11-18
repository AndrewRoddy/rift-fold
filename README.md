# rift-fold

Indent-based code folding in rift, with Vim's keys.

| Key | Command | Does |
|---|---|---|
| `zc` | `:FoldClose` | Close the block the cursor is on |
| `zo` | `:FoldOpen` | Open the closed fold on the cursor line |
| `za` | `:FoldToggle` | Open it if it's closed, close it otherwise |
| `zR` | `:FoldOpenAll` | Open every fold |
| `zM` | `:FoldCloseAll` | Close every top-level block |

A block is found like Vim's `foldmethod=indent`: the lines under a line that
are indented deeper than it. On a line that isn't followed by deeper lines,
`zc` closes the block around the cursor. A closing `}` / `)` / `]` / `end` /
`</tag>` line at the block's indent is folded too, so a function folds to
its first line:

```
function a() {  ··· 5 lines
```

## How it works, and what that means

rift can't hide lines, so a closed fold **cuts its lines out of the buffer**
and keeps them in the plugin. Opening the fold puts them back. So:

- **Saving while folded is safe.** After every save the plugin writes the
  hidden lines back into the file, so the file on disk always has the full
  text (LF and CRLF files, with or without a final newline).
- Closing or opening a fold is an edit: the buffer shows as modified and
  `:q` will want you to save first. `:wq` is fine.
- Each fold is one undo step. `u` right after `zc` brings the lines back and
  forgets the fold.
- Closing a block that contains closed folds merges them, so opening it
  shows everything open.
- If you delete a fold's first line, the hidden lines stay where they were
  and come back on `zo`/`zR`, or on save.
- Folds last until rift closes the buffer; they aren't remembered between
  sessions.
- Search, `:s` and other plugins only see what's in the buffer, so they
  don't see inside closed folds. `rift-conform` won't format a buffer with
  closed folds (it warns and skips); `zR` first.

## Options

```lua
{ "AndrewRoddy/rift-fold", opts = {
  text = "  ··· %d lines",                   -- after a closed fold; %d = line count
  style = { fg = "#928374", italic = true }, -- colour of that text
  keys = true,                               -- false: commands only, no z maps
} },
```

## Install

rift-fold installs through riftpm. Install riftpm first from
[Monster0506/riftpm](https://github.com/Monster0506/riftpm) (see its README),
then add rift-fold to your `plugins.lua` spec:

```lua
{ "AndrewRoddy/rift-fold" },
```

Run `:PluginSync` to clone it.

Tested with rift 0.7.5.
