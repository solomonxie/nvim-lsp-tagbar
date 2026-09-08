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

## Screenshot

_(coming soon)_

## Requirements

- Neovim >= 0.8
- An LSP client attached to the buffer that supports
  `textDocument/documentSymbol`

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

`kinds` maps an [LSP `SymbolKind`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind)
number to the label shown in the bar; a kind not listed here is dropped.
The shipped `syntax/lsptagbar.vim` highlights the default `[C]`/`[M]`/`[F]`/`[K]`/`[S]`
labels specifically — overriding `kinds` loses that highlighting unless you
also adjust the syntax file.
