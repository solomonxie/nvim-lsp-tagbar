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
syntax match lsptagbarMarker "\[@\]"
syntax match lsptagbarAdd    "\[+\]"
syntax match lsptagbarChange "\[\~\]"
syntax match lsptagbarDelete "\[-\]"
syntax match lsptagbarCaller "↑"
syntax match lsptagbarCallerLoc "\S\+:\d\+\( (\d\+ calls)\)\?\( (via .*)\)\?$"
syntax match lsptagbarCallerNote "^\s*(.*)$"
" File tree: names, git colors and the (ign)/(sym)/(hard)/(exc) tags are
" painted with extmarks from lua/nvim-lsp-tagbar/files.lua, not here. The
" rules above only touch a file line whose name itself looks like a label
" (`[+]`), a caller location (`foo:12`) or starts with `(`.
syntax match lsptagbarFileArrow "[▸▾]"

" `?` help block: whole lines starting with ", defined last so they win over
" the label and caller rules above; section titles have no indent.
syntax match lsptagbarHelp "^\".*$"
syntax match lsptagbarHelpTitle "^\" \S.*$"

highlight default link lsptagbarClass  Type
highlight default link lsptagbarMethod Function
highlight default link lsptagbarFunc   Function
highlight default link lsptagbarConst  Constant
highlight default link lsptagbarStruct Structure
highlight default link lsptagbarHead   Title
highlight default link lsptagbarMarker Todo
" winbar tab strip: the current view stands out, the others are dim
highlight default link lsptagbarTab    Comment
highlight default link lsptagbarTabSel TabLineSel
highlight default link lsptagbarLocked WarningMsg
highlight default link lsptagbarAdd    Added
highlight default link lsptagbarChange Changed
highlight default link lsptagbarDelete Removed
highlight default link lsptagbarCaller Special
highlight default link lsptagbarCallerLoc Comment
highlight default link lsptagbarCallerNote Comment
highlight default link lsptagbarFileArrow Directory
highlight default link lsptagbarHelp Comment
" header above the tree (virtual lines): folder or file, then dim `branch` /
" `target` labels with their values; lsptagbarHeaderFolder is set in files.lua
highlight default link lsptagbarHeaderLabel Comment
highlight default link lsptagbarHeaderValue Normal
highlight default link lsptagbarHelpTitle Statement

let b:current_syntax = 'lsptagbar'
