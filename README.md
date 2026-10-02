### Description

See what your branch has changed against a base, without leaving the file.

A scale's tare zeroes it against a reference. tare zeroes a git working tree
against a base -- by default `upstream/main` -- and shows only the difference:

- **A float**, harpoon-style, listing every changed file with its status and
  `+N -M`. Pick one to open it.
- **A view**, toggled per buffer: added lines get a tinted background, removed
  lines are drawn in place as virtual lines in their own syntax colours, and
  the status line shows `+N -M`. No split; the buffer is the real file and
  stays editable.

The base side is the merge-base of `HEAD` and the base ref, as a pull request
shows it; the other side is the working tree, unsaved edits included. tare
never writes to the buffer, the index or any ref.

It is a sibling of [diffview.nvim](https://github.com/sindrets/diffview.nvim),
not a replacement: diffview is two panes and a file panel; tare is one pane and
a pop-up.

Needs Neovim 0.11+, `git`, and `termguicolors`. Full documentation is in
`:help tare`.

### Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim), from a local checkout:

```lua
{
    "jjohnson-99/tare",
    -- Colour options are read as plugin/tare.vim is sourced: init, not config.
    init = function()
        vim.g.tare_BackgroundColor = 0x191724   -- see "Changing colours"
    end,
    config = function()
        vim.keymap.set("n", "<leader>zf", vim.cmd.Tare)
        vim.keymap.set("n", "<leader>zd", vim.cmd.TareToggle)
        vim.keymap.set("n", "<leader>zb", ":TareBase ")
    end
}
```

tare maps no keys of its own outside the float and the view. Run
`:helptags ALL` after installing.

### Usage

| Command | Effect |
| --- | --- |
| `:Tare` | Open or close the float for the current repository. |
| `:TareToggle` / `:TareEnable` / `:TareDisable` | The view in the current buffer. |
| `:TareBase` | Show the base and merge-base. |
| `:TareBase {ref}` | Compare against `{ref}`; follows it after a fetch. |
| `:TareBase! [{ref}]` | Pin the merge-base as a fixed commit. |
| `:TareBase -` | Back to the default base. |
| `:TareRefresh` | Re-resolve the base and redraw. |

```
╭──────────── tare ↔ upstream/main @ 8c6a30f3 ─────────────╮
│ M  src/planner/union.cpp                      +212   -14 │
│ A  src/op/union_all.cpp                       +340       │
│ D  src/op/old_union.cpp                              -88 │
│ R  include/x.hpp → include/y.hpp                +3    -3 │
╰──────────────────────────────────────────────────────────╯
```

In the float: `<CR>` opens with the view on, `o` opens without it, `b`
changes the base, `r` refreshes, `q` / `<Esc>` closes. A deleted file opens
as a read-only copy of its base version.

In the view: `]c` / `[c` jump between changes. The status line reads
`tare ↔ upstream/main  +212 -14`, or `new · 340 lines`, `deleted · 88 lines`,
`unchanged`.

The base is remembered per repository top level (so per worktree) in
`stdpath('data')/tare/bases.json`. With none set, the first of
`g:tare_DefaultBases` that exists is used.

### Options

```vim
let g:tare_DefaultBases    = ['upstream/main', 'origin/main', 'main', 'master']
let g:tare_Style           = 'background'  " or 'text'
let g:tare_Palette         = 'github'      " github | rose-pine | vivid | muted
let g:tare_AddColor        = -1            " 0xRRGGBB; -1 = from the palette
let g:tare_DeleteColor     = -1
let g:tare_Blend           = 30            " percent of the hue in the background
let g:tare_Vibrance        = 0             " percent toward full saturation
let g:tare_BackgroundColor = -1            " colour to blend against, 0xRRGGBB
let g:tare_SyntaxDeleted   = 1             " syntax colours on removed lines
let g:tare_Debounce        = 150           " ms after an edit before re-diffing
let g:tare_ViewOnOpen      = 1             " <CR> in the float turns the view on
let g:tare_FloatWidth      = 0.6           " fraction of 'columns'
```

The colour options are read when the highlight groups are computed: as the
plugin loads and on every `ColorScheme`. Set them in `init`. To try one live:

```vim
:let g:tare_Blend = 40 | doautocmd ColorScheme
```

### Changing colours

A tinted row is a hue (`g:tare_Palette`, or `g:tare_AddColor` /
`g:tare_DeleteColor`), mixed `g:tare_Blend` percent into a background after
being saturated `g:tare_Vibrance` percent.

**Transparent backgrounds.** Neovim cannot read the terminal's background.
With a transparent `Normal`, set `g:tare_BackgroundColor` to the terminal's
colour, or the `'background'` style falls back to `'text'`.

**Grey or purple tints.** A tint that reads as grey needs more saturation:
raise `g:tare_Vibrance` before `g:tare_Blend`. A removed row that reads as
purple has a pink hue (rose-pine's love, `0xEB6F92`); use a red.

Samples, with the backgrounds they produce against rose-pine's `0x191724`:

| Look | `init` settings | Add | Delete |
| --- | --- | --- | --- |
| Subtle, GitHub-like | `Palette = "github"` | `#244731` | `#5E2932` |
| Clearly green / red | `Palette = "github"`, `Blend = 40`, `Vibrance = 50` | `#0F5720` | `#750D15` |
| Saturated | `Palette = "vivid"`, `Blend = 35` | `#10562F` | `#692029` |
| rose-pine's own | `Palette = "rose-pine"`, `Blend = 25` | `#394551` | `#4D2D3F` |
| Green / rose-pine pink | `Palette = "github"`, `DeleteColor = 0xEB6F92` | `#244731` | `#583145` |

To try one live, paste its line in a buffer with the view on. Each line sets
every colour option, so they can be tried in any order:

```vim
" Subtle, GitHub-like
:let g:tare_Style = 'background' | let g:tare_Palette = 'github' | let g:tare_AddColor = -1 | let g:tare_DeleteColor = -1 | let g:tare_Blend = 30 | let g:tare_Vibrance = 0 | doau ColorScheme
" Clearly green / red
:let g:tare_Style = 'background' | let g:tare_Palette = 'github' | let g:tare_AddColor = -1 | let g:tare_DeleteColor = -1 | let g:tare_Blend = 40 | let g:tare_Vibrance = 50 | doau ColorScheme
" Saturated
:let g:tare_Style = 'background' | let g:tare_Palette = 'vivid' | let g:tare_AddColor = -1 | let g:tare_DeleteColor = -1 | let g:tare_Blend = 35 | let g:tare_Vibrance = 0 | doau ColorScheme
" rose-pine's own
:let g:tare_Style = 'background' | let g:tare_Palette = 'rose-pine' | let g:tare_AddColor = -1 | let g:tare_DeleteColor = -1 | let g:tare_Blend = 25 | let g:tare_Vibrance = 0 | doau ColorScheme
" Green / rose-pine pink
:let g:tare_Style = 'background' | let g:tare_Palette = 'github' | let g:tare_AddColor = -1 | let g:tare_DeleteColor = 0xEB6F92 | let g:tare_Blend = 30 | let g:tare_Vibrance = 0 | doau ColorScheme
" Your own hues
:let g:tare_Style = 'background' | let g:tare_Palette = 'github' | let g:tare_AddColor = 0x2EA043 | let g:tare_DeleteColor = 0xF85149 | let g:tare_Blend = 35 | let g:tare_Vibrance = 0 | doau ColorScheme
" Text instead of backgrounds
:let g:tare_Style = 'text' | let g:tare_Palette = 'github' | let g:tare_AddColor = -1 | let g:tare_DeleteColor = -1 | doau ColorScheme
```

These assume `g:tare_BackgroundColor` is already set. They last until restart;
to keep one, move its values into `init`. For example, the second:

```lua
init = function()
    vim.g.tare_BackgroundColor = 0x191724
    vim.g.tare_Palette         = "github"
    vim.g.tare_Blend           = 40
    vim.g.tare_Vibrance        = 50
end,
```

Your own hues:

```lua
vim.g.tare_AddColor    = 0x2EA043
vim.g.tare_DeleteColor = 0xF85149
vim.g.tare_Blend       = 35
```

Text instead of backgrounds, to keep a transparent window clear: added rows in
the add hue, removed rows in the delete hue with their syntax adding only bold
and italic.

```lua
vim.g.tare_Style = "text"
```

**Exact colours.** `TareAdd` and `TareDelete` are computed and set again on
every `ColorScheme`, so a plain `:highlight` lasts only until the next one. Set
them from your own `ColorScheme` autocmd, declared after tare loads so it runs
second, and once directly:

```lua
config = function()
    local function colours()
        vim.api.nvim_set_hl(0, "TareAdd",    { bg = "#1f3a2a" })
        vim.api.nvim_set_hl(0, "TareDelete", { bg = "#4a1f28" })
        -- or the colorscheme's own: { link = "DiffAdd" }, { link = "DiffDelete" }
    end
    colours()
    vim.api.nvim_create_autocmd("ColorScheme", { callback = colours })
end
```

### Highlight groups

| Group | Used for | Kind |
| --- | --- | --- |
| `TareAdd` | added rows | computed |
| `TareDelete` | removed rows (drawn over their syntax colours) | computed |
| `TareAddText` | `+N` in the status line | computed |
| `TareDeleteText` | `-M`, `deleted · N lines` | computed |
| `TareNew` | `new · N lines` | computed |
| `TareFloatAdd` / `TareFloatDelete` | counts in the float | link to the two above |
| `TareFloatStatus` | `M A D R` in the float | link to `Identifier` |
| `TareFloatTitle` | the float's title | link to `FloatTitle` |

### Limitations

- Removed lines longer than the window are cut off, not wrapped.
- `gg` does not reach removed lines above the first line; `<C-y>` or `<C-b>`
  does. tare scrolls them into view on enable.
- A file whose only change is its final newline or LF to CRLF shows
  `unchanged`; `git diff` counts it.
- With one buffer in two windows of different widths, removed-line
  backgrounds are padded for the current one.
- `:set number` and other text-width changes without a resize apply at the
  next edit or window entry.
- Repositories with checkout filters or line-ending conversion can show
  unchanged lines as changed. Submodules are listed but cannot be viewed.
