"=================================================
" File: test/syntax.vim
" Description: Syntax colour on removed lines (DESIGN.md 14, M2.5).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded, git and
" stdpath('data') pointed away from the user's own, and only Neovim's bundled
" parsers and queries on 'runtimepath'. Each fixtures/syntax/<filetype>.base /
" .work pair goes through tare#ops and tare#chunks at width 40 and must
" serialise to <filetype>.expected; $TARE_UPDATE rewrites the goldens instead.
" Failures are left in v:errors.

let s:dir = expand('<sfile>:p:h') . '/fixtures/syntax'
let s:ns = nvim_create_namespace('tare')
let s:tmp = resolve(tempname())

function! s:spans(lines, filetype) abort
    return luaeval('require("tare.syntax").spans(_A[1], _A[2])', [a:lines, a:filetype])
endfunction

" One line per removed line, then one per chunk: its text quoted, its groups.
function! s:serialise(base, ops, spans) abort
    let out = []
    for op in filter(copy(a:ops), 'v:val.kind !=# "add"')
        call add(out, printf('%-12s row %d  from %d', op.kind, op.row, op.from))
        for i in range(len(op.text))
            let chunks = tare#chunks(a:base[op.from + i], a:spans[op.from + i], 40)
            call assert_equal(op.text[i], join(map(copy(chunks), 'v:val[0]'), ''),
                \ 'chunks join to the op text')
            call add(out, '  line ' . (op.from + i + 1))
            for [text, hl] in chunks
                call add(out, '    "' . text . '" ' . (type(hl) == v:t_list ? join(hl) : hl))
            endfor
        endfor
    endfor
    return out
endfunction


"=================================================
" Goldens: a block comment and a raw string cut by a removal, an injected
" language, tabs, and multibyte text.

let s:names = map(glob(s:dir . '/*.base', 1, 1), 'fnamemodify(v:val, ":t:r")')
call assert_equal(['c', 'lua'], s:names, 'syntax fixtures')
for s:ft in s:names
    let s:base = readfile(s:dir . '/' . s:ft . '.base')
    let s:spans = s:spans(s:base, s:ft)
    call assert_equal(v:t_list, type(s:spans), s:ft . ': no spans')
    let s:got = s:serialise(s:base,
        \ tare#ops(s:base, readfile(s:dir . '/' . s:ft . '.work'), 40), s:spans)
    if !empty($TARE_UPDATE)
        call writefile(s:got, s:dir . '/' . s:ft . '.expected')
    else
        call assert_equal(readfile(s:dir . '/' . s:ft . '.expected'), s:got, s:ft)
    endif
endfor

" Nothing to colour with: no spans, and a line with none is today's one chunk.
for s:ft in ['', 'tare-no-such-filetype', 'text']
    call assert_equal(v:null, s:spans(['int x;'], s:ft), 'spans for "' . s:ft . '"')
endfor
call assert_equal([['        x' . repeat(' ', 11), 'TareDelete']], tare#chunks("\tx", [], 20),
    \ 'no spans')
" A span past the line's end (a CR stripped from a dos base) is cut at it.
call assert_equal([['ab', ['G', 'TareDelete']], ['  ', 'TareDelete']],
    \ tare#chunks('ab', [[0, 3, ['G']]], 4), 'span past the end')


"=================================================
" The view: chunks carry captures; one parse per base file whatever renders.

function! s:sh(dir, ...) abort
    let out = system(['git', '-C', a:dir] + a:000)
    call assert_equal(0, v:shell_error, 'git ' . join(a:000) . ': ' . out)
endfunction

" The groups of every chunk of every removed line, '' for plain TareDelete.
function! s:groups() abort
    let out = []
    for [_, _, _, d] in nvim_buf_get_extmarks(0, s:ns, 0, -1, {'details': v:true})
        for line in get(d, 'virt_lines', [])
            call extend(out, map(copy(line), 'type(v:val[1]) == v:t_list ? join(v:val[1]) : ""'))
        endfor
    endfor
    return out
endfunction

call mkdir(s:tmp, 'p')
call s:sh(s:tmp, 'init', '-q', '-b', 'main')
call writefile(readfile(s:dir . '/c.base'), s:tmp . '/f.c')
call writefile(readfile(s:dir . '/c.base'), s:tmp . '/f.zzz')
call writefile(['int x;'] + repeat([repeat('/', 1023)], 256), s:tmp . '/big.c')
call s:sh(s:tmp, 'add', '-A')
call s:sh(s:tmp, 'commit', '-q', '-m', 'base')
call writefile(readfile(s:dir . '/c.work'), s:tmp . '/f.c')
call writefile(readfile(s:dir . '/c.work'), s:tmp . '/f.zzz')
call writefile(repeat([repeat('/', 1023)], 256), s:tmp . '/big.c')

lua << EOF
local syntax = require("tare.syntax")
_G.tare_test = { parses = 0, spans = syntax.spans }
syntax.spans = function(...)
    _G.tare_test.parses = _G.tare_test.parses + 1
    return _G.tare_test.spans(...)
end
EOF

silent! %bwipeout!
exe 'edit ' . s:tmp . '/f.c'
setlocal filetype=c
messages clear
TareEnable
call assert_true(index(s:groups(), '@comment.c TareDelete') >= 0, 'comment captured')
call assert_true(index(s:groups(), '@keyword.return.c TareDelete') >= 0, 'keyword captured')

" Edits, a resize, a refresh and a second buffer on the same base file.
call setline(1, '/* Adds */')
call tare#Hunk(1)
vsplit
silent doautocmd WinResized
close
silent doautocmd WinResized
TareRefresh
call assert_equal(1, luaeval('_G.tare_test.parses'), 'parsed once')
call assert_true(index(s:groups(), '@comment.c TareDelete') >= 0, 'captures after edits')

" Off, read when the view next renders; on again from the cache.
let g:tare_SyntaxDeleted = 0
doautocmd WinEnter
call assert_equal([''], uniq(sort(s:groups())), 'g:tare_SyntaxDeleted 0')
let g:tare_SyntaxDeleted = 1
doautocmd WinEnter
call assert_true(index(s:groups(), '@comment.c TareDelete') >= 0, 'on again')
call assert_equal(1, luaeval('_G.tare_test.parses'), 'parsed once, toggled')
TareDisable

" A filetype with no parser: today's plain chunks, parsed for nothing once.
exe 'edit ' . s:tmp . '/f.zzz'
setlocal filetype=zzz
TareEnable
call setline(1, '/* Adds */')
call tare#Hunk(1)
call assert_equal([''], uniq(sort(s:groups())), 'no parser')
call assert_equal(2, luaeval('_G.tare_test.parses'), 'unknown filetype parsed once')
TareDisable

" A base side of 256 KiB or more is not parsed.
exe 'edit ' . s:tmp . '/big.c'
setlocal filetype=c
TareEnable
call assert_equal(['tare ↔ main  +0 -1  '], [nvim_eval_statusline('%{%tare#statusline()%}',
    \ {'winid': win_getid()}).str], 'big file')
call assert_equal([''], uniq(sort(s:groups())), 'big file plain')
call assert_equal(2, luaeval('_G.tare_test.parses'), 'big file parsed')
TareDisable
call assert_equal([], filter(split(execute('messages'), "\n"), 'v:val =~# "E\\d\\+:\\|tare: "'),
    \ 'messages')

lua require("tare.syntax").spans = _G.tare_test.spans; _G.tare_test = nil
silent! %bwipeout!
call delete(s:tmp, 'rf')

" vim: set et fdm=marker sts=4 sw=4:
