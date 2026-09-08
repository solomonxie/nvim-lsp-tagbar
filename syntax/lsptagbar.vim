" Syntax for the nvim-lsp-tagbar buffer (filetype 'lsptagbar').
" Labels match config.defaults.kinds in lua/nvim-lsp-tagbar/config.lua.

if exists('b:current_syntax')
  finish
endif

syntax match lsptagbarClass  "\[C\]"
syntax match lsptagbarMethod "\[M\]"
syntax match lsptagbarFunc   "\[F\]"
syntax match lsptagbarConst  "\[K\]"
syntax match lsptagbarStruct "\[S\]"

highlight default link lsptagbarClass  Type
highlight default link lsptagbarMethod Function
highlight default link lsptagbarFunc   Function
highlight default link lsptagbarConst  Constant
highlight default link lsptagbarStruct Structure

let b:current_syntax = 'lsptagbar'
