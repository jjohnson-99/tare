"=================================================
" File: test/ops.vim
" Description: tare#ops against the goldens in test/fixtures (DESIGN.md 4, 10).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded. Each
" <name>.base / <name>.work pair goes through tare#ops at width 80 and tabstop
" 8, and must serialise to <name>.expected. With $TARE_UPDATE set, the goldens
" are rewritten instead. Failures are left in v:errors.

let s:dir = expand('<sfile>:p:h') . '/fixtures'

" Split as git and the view split a file: on NL only, a final newline adding
" no empty last line.
function! s:read(path) abort
    let lines = readfile(a:path, 'b')
    if !empty(lines) && lines[-1] ==# ''
        call remove(lines, -1)
    endif
    return lines
endfunction

" One line per op, then its removed lines quoted so the padding shows.
function! s:serialise(ops) abort
    let out = []
    for op in a:ops
        call add(out, printf('%-12s row %d  count %d', op.kind, op.row, op.count))
        call extend(out, map(copy(op.text), '''  "'' . v:val . ''"'''))
    endfor
    return empty(out) ? ['(no ops)'] : out
endfunction

let s:names = map(glob(s:dir . '/*.base', 1, 1), 'fnamemodify(v:val, ":t:r")')
call assert_true(len(s:names) >= 14, 'fixtures missing')
for s:name in s:names
    let s:stem = s:dir . '/' . s:name
    let s:got = s:serialise(tare#ops(s:read(s:stem . '.base'), s:read(s:stem . '.work'), 80))
    if !empty($TARE_UPDATE)
        call writefile(s:got, s:stem . '.expected')
    else
        call assert_equal(readfile(s:stem . '.expected', 'b')[:-2], s:got, s:name)
    endif
endfor

" A tabstop other than the default moves the tab stops.
call assert_equal('a   b' . repeat(' ', 75), tare#ops(["a\tb"], [], 80, 4)[0].text[0], 'tabstop 4')

" vim: set et fdm=marker sts=4 sw=4:
