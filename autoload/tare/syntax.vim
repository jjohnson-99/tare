"=================================================
" File: autoload/tare/syntax.vim
" Description: Syntax colour for removed lines, from a parse of the base side.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" The parse is lua/tare/syntax.lua's; this file decides when to run it and
" keeps what it returns. Columns are bytes, as in tare#chunks.


" Avoid installing twice.
if exists('g:autoloaded_tare_syntax')
    finish
endif
let g:autoloaded_tare_syntax = 0

" Spans by '<merge-base>:<filetype>:<path>' ('filetype' holds no colon).
" Content at a SHA never changes; an entry goes once no repository's base is it.
let s:spans = {}

" A base side larger than this is left plain: the parse costs about 1 ms per
" KiB, all at once on the first render.
let s:MAX_BYTES = 256 * 1024


"=================================================
" The highlight spans of `path` at `mb` read as `filetype`: one list per line
" of [start, end, groups], or [] with g:tare_SyntaxDeleted off, a file too
" large, or no parser, query or parse to be had.
function! tare#syntax#spans(root, mb, path, filetype) abort
    if !g:tare_SyntaxDeleted || empty(a:filetype)
        return []
    endif
    let key = a:mb . ':' . a:filetype . ':' . a:path
    if !has_key(s:spans, key)
        let live = map(tare#git#roots(), 'tare#git#cached(v:val).mb')
        call filter(s:spans, {k, _ -> index(live, matchstr(k, '^[^:]*')) >= 0})
        let lines = tare#git#show(a:root, a:mb, a:path)
        let spans = strlen(join(lines, "\n")) >= s:MAX_BYTES ? v:null
            \ : luaeval('require("tare.syntax").spans(_A[1], _A[2])', [lines, a:filetype])
        let s:spans[key] = spans is v:null ? [] : spans
    endif
    return s:spans[key]
endfunction

" vim: set et fdm=marker sts=4 sw=4:
