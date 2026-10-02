"=================================================
" File: test/invariant.vim
" Description: Toggling the view leaves no state behind (DESIGN.md 1.3.2).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded. Failures are
" left in v:errors; every scenario starts from a single empty window.

let s:dir = fnamemodify(tempname(), ':h') . '/tare-invariant'
call mkdir(s:dir, 'p')
let s:A = s:dir . '/a.txt'
let s:B = s:dir . '/b.txt'
call writefile(['one', 'two', 'three'], s:A)
call writefile(['other'], s:B)
" The view needs a repository with a base; 'main' is the first default found.
for s:args in [['init', '-q', '-b', 'main'], ['add', '.'], ['commit', '-q', '-m', 'init']]
    call system(['git', '-C', s:dir] + s:args)
endfor
" Changed since the base, so the view has extmarks of its own to clear.
call writefile(['one', 'TWO', 'three', 'four'], s:A)

let s:foreign = nvim_create_namespace('tare-test-foreign')
let s:SEGMENT = '%{%tare#statusline()%}'


"=================================================
" Everything the view may touch, for every window and buffer in the session.
" Windows and buffers are named by position and file, never by id, so that two
" runs of one scenario compare equal.
function! s:snapshot() abort
    let out = {'global': &g:statusline, 'au': execute('autocmd Tare'),
        \ 'here': map(['n', 'x', 'o'], '[maparg("]c", v:val, 0, 1), maparg("[c", v:val, 0, 1)]'),
        \ 'wins': [], 'bufs': {}}
    for info in getwininfo()
        call add(out.wins, [info.tabnr, info.winnr, bufname(info.bufnr),
            \ nvim_get_option_value('statusline', {'win': info.winid, 'scope': 'local'})])
    endfor
    for buf in getbufinfo({'bufloaded': 1})
        let out.bufs[buf.name] = {
            \ 'maps': map(['n', 'x', 'o', 's'], {_, mode -> map(nvim_buf_get_keymap(buf.bufnr, mode),
            \   'extend(v:val, {"buffer": 1})')}),
            \ 'marks': nvim_buf_get_extmarks(buf.bufnr, -1, 0, -1, {'details': v:true}),
            \ 'var': has_key(buf.variables, 'tare')}
    endfor
    return out
endfunction

function! s:reset() abort
    silent! %bwipeout!
    silent! only!
    silent! tabonly!
    set statusline&
    setlocal statusline=
endfunction

function! s:owned(winid) abort
    return stridx(nvim_get_option_value('statusline',
        \ {'win': a:winid, 'scope': 'local'}), s:SEGMENT) >= 0
endfunction

function! s:start(setup) abort
    call s:reset()
    exe 'edit ' . s:A
    call nvim_buf_set_extmark(0, s:foreign, 1, 0, {'virt_text': [['x', 'Comment']]})
    for cmd in a:setup
        exe cmd
    endfor
endfunction

" Runs `body` (its asserts aside) once as is and once with the view toggled on before it and off
" after it, then on and off again; both runs must end in the same state. Every
" body ends in the window it started in.
function! s:scenario(name, setup, body) abort
    call s:start(a:setup)
    for cmd in filter(copy(a:body), 'v:val !~# "^call assert"')
        exe cmd
    endfor
    let expected = s:snapshot()

    call s:start(a:setup)
    TareToggle
    call assert_true(s:owned(win_getid()), a:name . ': status line not taken')
    call assert_true(get(maparg(']c', 'n', 0, 1), 'buffer', 0), a:name . ': ]c not mapped')
    call assert_match('BufDelete', execute('autocmd Tare'), a:name . ': no autocmd')
    for cmd in a:body
        exe cmd
    endfor
    TareToggle
    call assert_equal(expected, s:snapshot(), a:name)
    TareToggle
    TareToggle
    call assert_equal(expected, s:snapshot(), a:name . ' (second toggle)')
endfunction


"=================================================
" Scenarios.

for [s:label, s:setup] in [
    \ ['default', []],
    \ ['global line', ['set statusline=GLOBAL%f']],
    \ ['local line', ['setlocal statusline=LOCAL%f']],
    \ ['expression line', ['set statusline=%!''EXPR''']],
    \ ['prior map', ['nnoremap <buffer> ]c :echo "mine"<CR>']],
    \ ['prior map, all modes', ['noremap <buffer> ]c :echo "mine"<CR>']],
    \ ['global map', ['nnoremap ]c :echo "global"<CR>']],
    \ ]
    call s:scenario(s:label, s:setup, [])

    call s:scenario(s:label . ', split', s:setup,
        \ ['split', 'call assert_true(s:owned(win_getid()), "split not taken")'])

    call s:scenario(s:label . ', :e other / :b#', s:setup,
        \ ['edit ' . s:B,
        \  'call assert_false(s:owned(win_getid()), ":e other kept tare''s line")',
        \  'buffer #',
        \  'call assert_true(s:owned(win_getid()), ":b# lost tare''s line")'])

    call s:scenario(s:label . ', split then :e other', s:setup,
        \ ['split', 'edit ' . s:B, 'wincmd p'])

    " Disabled once after its timer has rendered the edit, once before.
    call s:scenario(s:label . ', edit', s:setup,
        \ ['call setline(1, "ONE")', 'silent doautocmd TextChanged', 'call wait(400, {-> 0})'])
    call s:scenario(s:label . ', edit, timer pending', s:setup,
        \ ['call setline(1, "ONE")', 'silent doautocmd TextChanged'])

    call s:scenario(s:label . ', tab split and float', s:setup,
        \ ['tab split', 'tabprevious',
        \  'call nvim_open_win(bufnr(), v:true, {"relative": "editor",'
        \  . ' "row": 1, "col": 1, "width": 20, "height": 2})', 'wincmd p'])
    silent! unmap ]c
endfor

" The global line, unchanged, also after the window comes back to a.txt.
call s:reset()
exe 'edit ' . s:A
exe 'edit ' . s:B
let s:beforeB = s:snapshot()
buffer #
let s:before = s:snapshot()
TareToggle
exe 'edit ' . s:B
buffer #
TareToggle
exe 'edit ' . s:B
call assert_equal(s:beforeB, s:snapshot(), ':b# after disable')
buffer #
call assert_equal(s:before, s:snapshot(), ':b# back after disable')

" Disabling one buffer leaves another's autocmds alone.
call s:reset()
exe 'edit ' . s:B
TareEnable
exe 'edit ' . s:A
TareEnable
TareDisable
call assert_match('<buffer=' . bufnr(s:B) . '>', execute('autocmd Tare'),
    \ 'disabling a.txt cleared b.txt''s autocmds')
call assert_notmatch('<buffer=' . bufnr(s:A) . '>', execute('autocmd Tare'),
    \ 'a.txt''s autocmds survived disable')

" :bdelete of an enabled buffer drops its autocmds and hands its window back.
call s:reset()
exe 'edit ' . s:B
exe 'edit ' . s:A
let s:winid = win_getid()
TareEnable
exe 'bdelete ' . bufnr(s:A)
call assert_equal('', execute('autocmd Tare') =~# '<buffer=' ? 'leftover' : '',
    \ ':bdelete left autocmds in Tare')
call assert_false(s:owned(s:winid), ':bdelete left tare''s line')

" The composed line renders, the expression form included.
call s:reset()
exe 'edit ' . s:A
set statusline=%!'EXPR'
TareEnable
call assert_equal('tare ↔ main  +2 -1  EXPR',
    \ nvim_eval_statusline(&l:statusline, {'winid': win_getid()}).str, 'expression render')
TareDisable
set statusline&
TareEnable
call assert_match('^tare ↔ main  .*a\.txt',
    \ nvim_eval_statusline(&l:statusline, {'winid': win_getid()}).str, 'default render')
TareDisable

call s:reset()
call delete(s:dir, 'rf')

" vim: set et fdm=marker sts=4 sw=4:
