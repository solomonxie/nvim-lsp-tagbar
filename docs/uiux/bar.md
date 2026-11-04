# The bar

A `botright 20 split` of a scratch buffer (`filetype=lsptagbar`, `nofile`,
no line numbers, no wrap, `winfixheight` so `<C-w>=` can't shrink it).

```
┌ your file ───────────────────────────────────────────────────┐
│ 41   function M.refresh()                                    │
│ 42 ▌   if not (M.buf and M.src_buf) then                     │ ← cursor here
│ 43       return                                              │
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
│ [C] TagbarModule                                             │ ← two-space
│   [F] setup                                                  │   indent per
│   [F] toggle                                                 │   depth
│ ▌ [F] refresh                                                │ ← opens with
│     [F] render                                               │   the cursor
│   [K] DEFAULT_HEIGHT                                         │   already on
│ [U] LspTagbarToggle                                          │   the symbol
│ [U] LspTagbarDebug                                           │   you're in,
└──────────────────────────────────────────────────────────────┘   and follows
                                                                   it as you
                                                                   move
```

Labels are the whole visual language — one bracketed tag per kind, so a
line reads as `label name` at any depth:

```
 [C] class            [M] method / constructor      [F] function
 [K] constant         [S] struct
 [H1] … [H6]          a markdown heading, at that level
 [U]                  yours, from a treesitter query in `queries`
 a kind not in `kinds` is dropped — imports and bare references included
```

The shipped `syntax/lsptagbar.vim` highlights exactly those default labels;
a custom `kinds` or query `label` is plain text unless you add a rule.

## States — one line, always saying which nothing this is

```
 Loading symbols...     the request is out
 No LSP attached yet    nothing to ask
 No symbols             the server answered with nothing
 No matching symbols    it answered, but every kind was filtered out
 No headings            a `heading_filetypes` buffer with no `#` lines
```

Four different reasons for an empty bar, four different lines — one generic
"no symbols" would leave the user guessing whether to wait, configure, or
attach a server.

## What a markup buffer shows instead

```
 [H1] LSP Symbol Bar
   [H2] Requirements
   [H2] Install
   [H2] Config defaults
     [H3] Custom entries
```

No LSP is queried at all for `markdown`, `rmd`, `quarto`, `vimwiki`; code
fences are ignored, so a `# comment` inside a fence never becomes a
heading.

## Config surface

```lua
{
  keymap = nil,           -- a key to toggle the bar, e.g. 'ft'; none by default
  height = 20,
  heading_filetypes = { 'markdown', 'rmd', 'quarto', 'vimwiki' },
  heading_label = '[H%d]',
  queries = {},           -- filetype -> { { label, query } }
  kinds = { [5]='[C]', [6]='[M]', [9]='[M]', [12]='[F]', [14]='[K]', [23]='[S]' },
}
```

A query needs `@name` (the text shown, and where `<CR>` jumps) and may add
`@scope` (the range that highlights while the cursor is inside it). Matches
merge under the deepest symbol whose range contains them, then siblings
re-sort by line — so document order always reads top to bottom. A query
that fails to parse is reported once via `vim.notify` and skipped.
