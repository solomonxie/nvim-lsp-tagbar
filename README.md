# LSP Symbol Bar

A bottom bar of the current buffer's classes, functions, and methods —
built entirely from `textDocument/documentSymbol`. No ctags, no external
process, no other plugin dependency.

- Nested by real hierarchy when the server provides it, or by
  `containerName` when it only returns a flat list (e.g. pylsp).
- Filtered to a small set of useful kinds; imports and other bare
  references to a name are dropped, not just definitions.
- The bar opens with the cursor already on the symbol you're in, and keeps
  following it as you move — no need to hunt for where you are.
- Markdown (and other markup filetypes) get a section outline from their
  `#` headings instead — no LSP needed, code fences ignored.
- Anything the server misses can be matched with your own treesitter
  queries and merged into the tree (see [Custom entries](#custom-entries)).

## Requirements

- Neovim >= 0.8
- An LSP client attached to the buffer that supports
  `textDocument/documentSymbol` — except for `heading_filetypes`, which need
  nothing at all

## Install

```lua
-- lazy.nvim
{ 'solomonxie/nvim-lsp-tagbar' }
```
```lua
-- packer.nvim
use 'solomonxie/nvim-lsp-tagbar'
```
```vim
" vim-plug
Plug 'solomonxie/nvim-lsp-tagbar'
```

Works out of the box — `ft` toggles the bar. Call `setup()` only to change
the defaults:

```lua
require('nvim-lsp-tagbar').setup({
  keymap = 'ft',   -- false to disable the default mapping
  height = 20,
})
```

## Usage

- `ft` (or `:LspTagbarToggle`) — toggle the bar
- Inside the bar:
  - `<CR>` — jump to the symbol and close the bar
  - `p` — jump to the enclosing symbol's line, within the bar
  - `q` / `<Esc>` — close the bar
- `:LspTagbarDebug` — print internal state (buf/win validity, jump count)
  for troubleshooting, with the bar open and cursor inside a symbol

## Config defaults

```lua
{
  keymap = 'ft',
  height = 20,
  heading_filetypes = { 'markdown', 'rmd', 'quarto', 'vimwiki' },
  heading_label = '[H%d]',
  queries = {},
  kinds = {
    [5] = '[C]',   -- Class
    [6] = '[M]',   -- Method
    [9] = '[M]',   -- Constructor
    [12] = '[F]',  -- Function
    [14] = '[K]',  -- Constant
    [23] = '[S]',  -- Struct
  },
}
```

`heading_filetypes` are outlined from their `#` headings (nested by level,
`%d` in `heading_label` is that level) and never query an LSP; set it to `{}`
to always use LSP symbols.

`kinds` maps an [LSP `SymbolKind`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind)
number to the label shown in the bar; a kind not listed here is dropped.
The shipped `syntax/lsptagbar.vim` highlights the default `[C]`/`[M]`/`[F]`/`[K]`/`[S]`/`[H1-6]`
labels specifically — overriding `kinds` loses that highlighting unless you
also adjust the syntax file.

## Custom entries

Servers disagree on what deserves a symbol — `lua_ls` names an anonymous
callback after the call it's passed to, `emmylua_ls` omits it entirely. Add
`queries` to match those yourself:

```lua
require('nvim-lsp-tagbar').setup({
  queries = {
    lua = {
      { label = '[U]', query = [[
        ((function_call
           name: (_) @fn
           (#eq? @fn "vim.api.nvim_create_user_command")
           arguments: (arguments (string content: (string_content) @name))) @scope)
      ]] },
    },
  },
})
```

```
[U] LspTagbarToggle
[U] LspTagbarDebug
```

- `@name` (required) — the text shown, and where `<CR>` jumps to.
- `@scope` (optional) — the entry's range, so the bar highlights it while
  the cursor is anywhere inside; defaults to `@name`'s own node.

Matches are merged into the server's tree under the deepest symbol whose
range contains them, then siblings are re-sorted by line — so a match inside
a function nests under it, and one at file scope sits in document order
among the real symbols. A query that fails to parse is reported once via
`vim.notify` and skipped.

`label` is yours to choose and won't be highlighted by the shipped syntax
file unless you add a rule for it.

## Screenshot

![nvim-lsp-tagbar](./screenshot.png)
