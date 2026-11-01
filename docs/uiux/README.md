# UI/UX mockups — nvim-lsp-tagbar

The interface is one bottom split of text. Drawn as built today.

Glyphs follow the `uiux` skill (`references/notation.md` +
`text-figma.md`): `←` annotation · `▔▔▔` window border · `▌` the cursor
line.

## Surface map

```
 any buffer
   ft  /  :LspTagbarToggle  ─▶ the bar opens at the bottom, cursor already
   │                            on the symbol you are in
   ├ <CR>       jump to the symbol, close the bar
   ├ p          move to the enclosing symbol's line, inside the bar
   ├ q / <Esc>  close
   └ :LspTagbarDebug  ─▶ :messages, for troubleshooting
```

## Files

| File | Covers |
|---|---|
| `bar.md` | the bar itself: layout, labels, states, config surface |
