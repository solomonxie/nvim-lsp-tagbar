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
syntax match lsptagbarHead   "\[H\d\]"
syntax match lsptagbarCaller "↑"
syntax match lsptagbarCallerLoc "\S\+:\d\+\( (\d\+ calls)\)\?\( (via .*)\)\?$"
syntax match lsptagbarCallerNote "^\s*(.*)$"

highlight default link lsptagbarClass  Type
highlight default link lsptagbarMethod Function
highlight default link lsptagbarFunc   Function
highlight default link lsptagbarConst  Constant
highlight default link lsptagbarStruct Structure
highlight default link lsptagbarHead   Title
highlight default link lsptagbarCaller Special
highlight default link lsptagbarCallerLoc Comment
highlight default link lsptagbarCallerNote Comment

let b:current_syntax = 'lsptagbar'
