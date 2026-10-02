"=================================================
" File: test/view.vim
" Description: The view against a throwaway repository (DESIGN.md 6, 11 M2).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded and git and
" stdpath('data') pointed away from the user's own. Failures are left in
" v:errors.
"
" TextChanged and WinResized fire only from an editor's main loop, never in a
" sourced script, so each is fired here by hand after the change it follows.

let s:ns = nvim_create_namespace('tare')
let s:tmp = resolve(tempname())

function! s:sh(dir, ...) abort
    let out = system(['git', '-C', a:dir] + a:000)
    call assert_equal(0, v:shell_error, 'git ' . join(a:000) . ': ' . out)
    return trim(out)
endfunction

" A repository at `name` with `files` committed on main; returns its path.
function! s:repo(name, files) abort
    let dir = s:tmp . '/' . a:name
    call mkdir(dir, 'p')
    call s:sh(dir, 'init', '-q', '-b', 'main')
    call s:commit(dir, a:files)
    return dir
endfunction

" Writes each file (a list of lines, or a Blob for exact bytes) and commits.
function! s:commit(dir, files) abort
    call s:write(a:dir, a:files)
    call s:sh(a:dir, 'add', '-A')
    call s:sh(a:dir, 'commit', '-q', '-m', 'commit')
    return s:sh(a:dir, 'rev-parse', 'HEAD')
endfunction

function! s:write(dir, files) abort
    for [name, content] in items(a:files)
        call writefile(content, a:dir . '/' . name)
    endfor
endfunction

function! s:open(path) abort
    silent! %bwipeout!
    exe 'edit ' . fnameescape(a:path)
endfunction

" The tare segment as the status line draws it.
function! s:stl() abort
    return nvim_eval_statusline('%{%tare#statusline()%}', {'winid': win_getid()}).str
endfunction

" tare's extmarks: [row, 'add', last row] or [row, 'above'/'below', lines].
function! s:marks() abort
    let out = []
    for [_, row, _, d] in nvim_buf_get_extmarks(0, s:ns, 0, -1, {'details': v:true})
        if has_key(d, 'virt_lines')
            call add(out, [row, d.virt_lines_above ? 'above' : 'below',
                \ map(copy(d.virt_lines), 'v:val[0][0]')])
        else
            call add(out, [row, 'add', d.end_row])
        endif
    endfor
    return out
endfunction

function! s:pad(text) abort
    let width = winwidth(0) - getwininfo(win_getid())[0].textoff
    return a:text . repeat(' ', width - strdisplaywidth(a:text))
endfunction

function! s:messages() abort
    return filter(split(execute('messages'), "\n"), 'v:val =~# "^tare: \\|E\\d\\+:"')
endfunction


"=================================================
" One repository with one file of each kind.

let s:R = s:repo('kinds', {
    \ 'mod.txt': ['one', 'two', 'three', 'four', 'five'],
    \ 'top.txt': map(range(1, 20), 'string(v:val)'),
    \ 'hunks.txt': map(range(1, 10), 'string(v:val)'),
    \ 'crlf.txt': 0z610D0A620D0A630D0A,
    \ 'empty.txt': [], 'nl.txt': [''], 'nonl.txt': 0z780A79,
    \ 'old.txt': ['1', '2', '3', '4', '5'], 'del.txt': ['x'],
    \ 'bin.dat': 0z000102, 'same.bin': 0z000102,
    \ 'tab.txt': ["\tgone", 'kept'], '.gitignore': ['*.log']})
call s:write(s:R, {
    \ 'mod.txt': ['one', 'TWO', 'three', 'four', 'five', 'six'],
    \ 'top.txt': map(range(3, 20), 'string(v:val)'),
    \ 'hunks.txt': ['new', '1', '2', 'three', '4', '6', '7', '8', '9'],
    \ 'crlf.txt': 0z610D0A420D0A630D0A,
    \ 'bin.dat': 0z000103, 'tab.txt': ['kept'],
    \ 'untracked.txt': ['u', 'v', 'w'], 'x.log': ['ignored']})
call s:sh(s:R, 'mv', 'old.txt', 'new.txt')
call writefile(['1', '2', '3', '4', 'five'], s:R . '/new.txt')
call delete(s:R . '/del.txt')

" Modified: a replaced row, an added row at the end.
call s:open(s:R . '/mod.txt')
TareEnable
call assert_equal('tare ↔ main  +2 -1  ', s:stl(), 'modified')
call assert_equal([[1, 'above', [s:pad('two')]], [1, 'add', 1], [5, 'add', 5]], s:marks(),
    \ 'modified marks')
let s:hl = nvim_eval_statusline('%{%tare#statusline()%}',
    \ {'winid': win_getid(), 'highlights': v:true}).highlights
call assert_equal(['TareAddText', 'TareDeleteText'],
    \ filter(map(s:hl, 'v:val.group'), 'v:val =~# "^Tare"'), 'count colours')
let s:m = nvim_buf_get_extmarks(0, s:ns, 0, -1, {'details': v:true})
call assert_equal('TareDelete', s:m[0][3].virt_lines[0][0][1], 'delete group')
call assert_equal('TareAdd', s:m[1][3].line_hl_group, 'add group')

" Width follows the current window; tabs expand at the buffer's 'tabstop'.
vsplit
silent doautocmd WinResized
call assert_equal([[1, 'above', [s:pad('two')]]], s:marks()[0:0], 'narrower window')
call assert_true(winwidth(0) < 60, 'split did not narrow the window')
close
silent doautocmd WinResized
call assert_equal([[1, 'above', [s:pad('two')]]], s:marks()[0:0], 'wider again')
TareDisable
call assert_equal([], s:marks(), 'cleared on disable')

call s:open(s:R . '/tab.txt')
setlocal tabstop=4
TareEnable
call assert_equal([[0, 'above', [s:pad('    gone')]]], s:marks(), 'tabstop 4')
TareDisable

" Top-of-file deletion: the window scrolls to the filler holding it.
call s:open(s:R . '/top.txt')
TareEnable
call assert_equal([[0, 'above', [s:pad('1'), s:pad('2')]]], s:marks(), 'top marks')
call assert_equal(2, winsaveview().topfill, 'top deletion scrolled into view')
TareDisable

" CRLF in the base and a dos buffer: only the changed line differs.
call s:open(s:R . '/crlf.txt')
call assert_equal('dos', &fileformat, 'crlf.txt not read as dos')
TareEnable
call assert_equal('tare ↔ main  +1 -1  ', s:stl(), 'crlf')
call assert_equal([1, 'above', [s:pad('b')]], s:marks()[0], 'crlf removed text')
TareDisable

" Empty file, one empty line, no final newline: unchanged.
for s:name in ['empty.txt', 'nl.txt', 'nonl.txt']
    call s:open(s:R . '/' . s:name)
    TareEnable
    call assert_equal('tare ↔ main  unchanged  ', s:stl(), s:name)
    call assert_equal([], s:marks(), s:name . ' marks')
    TareDisable
endfor

" A line added after the last, with no newline to follow it, is no line.
call s:open(s:R . '/nonl.txt')
setlocal nofixeol noeol
call append('$', '')
TareEnable
call assert_equal('tare ↔ main  unchanged  ', s:stl(), 'noeol, nofixeol')
setlocal fixeol
TareRefresh
call assert_equal('tare ↔ main  +1 -0  ', s:stl(), 'fixeol writes the line')
TareDisable

" Unchanged tracked file: no entry in the listing; edits still count.
call s:open(s:R . '/nl.txt')
TareEnable
call setline(1, 'now text')
call assert_equal('tare ↔ main  unchanged  ', s:stl(), 'before render')
call tare#Hunk(1)
call assert_equal('tare ↔ main  +1 -1  ', s:stl(), 'unsaved edit counted')
TareDisable

" Renamed: diffed against the old path.
call s:open(s:R . '/new.txt')
TareEnable
call assert_equal('tare ↔ main  +1 -1  ', s:stl(), 'rename')
call assert_equal([4, 'above', [s:pad('5')]], s:marks()[0], 'rename base')
TareDisable

" A deleted file's buffer is empty: everything is removed, below the one row.
call s:open(s:R . '/del.txt')
TareEnable
call assert_equal('tare ↔ main  +0 -1  ', s:stl(), 'deleted')
call assert_equal([[0, 'below', [s:pad('x')]]], s:marks(), 'deleted marks')
TareDisable

" New: untracked, ignored, not yet written. Counted, never highlighted.
for [s:name, s:count] in [['untracked.txt', '3 lines'], ['x.log', '1 line'],
        \ ['fresh.txt', '0 lines']]
    call s:open(s:R . '/' . s:name)
    TareEnable
    call assert_equal('tare ↔ main  new · ' . s:count . '  ', s:stl(), s:name)
    call assert_equal([], s:marks(), s:name . ' marks')
    TareDisable
endfor

" Binary, changed or not: refused, nothing left behind.
for s:name in ['bin.dat', 'same.bin']
    call s:open(s:R . '/' . s:name)
    call assert_equal(['tare: ' . s:name . ' is binary'],
        \ filter(split(execute('TareEnable'), "\n"), '!empty(v:val)'), s:name)
    call assert_false(exists('b:tare'), s:name . ' view left')
endfor

enew
call assert_match('tare: this buffer is not a file', execute('TareEnable'), 'no file')


"=================================================
" ]c and [c. Hunks of hunks.txt start on rows 0, 3, 5 and 8 (a pure deletion
" at the end, anchored to the last row).

call s:open(s:R . '/hunks.txt')
TareEnable
for [s:keys, s:from, s:to] in [
    \ [']c', 1, 4], ['2]c', 1, 6], ['9]c', 1, 9], [']c', 9, 9], [']c', 7, 9],
    \ ['[c', 9, 6], ['2[c', 9, 4], ['9[c', 9, 1], ['[c', 1, 1], ['[c', 5, 4]]
    exe 'normal ' . s:from . 'G' . s:keys
    call assert_equal(s:to, line('.'), s:keys . ' from ' . s:from)
endfor
exe "normal 1GV]c\<Esc>"
call assert_equal([1, 4], [line("'<"), line("'>")], 'visual ]c')
silent normal 1Gd]c
call assert_equal(['4', '6'], getline(1, 2), 'd]c is linewise')
silent undo
silent normal 9Gd]c
call assert_equal(9, line('$'), 'd]c with no hunk ahead does nothing')
clearjumps
normal 2G]c
call assert_equal(2, getjumplist()[0][-1].lnum, ']c not in the jumplist')
TareDisable
call assert_equal('', maparg(']c', 'x'), 'visual map left')
call assert_equal('', maparg('[c', 'o'), 'operator map left')


"=================================================
" Debounce: an edit renders once the timer runs; a view gone before then is
" never rendered into.

let g:tare_Debounce = 50
call s:open(s:R . '/mod.txt')
TareEnable
call setline(5, 'FIVE')
silent doautocmd TextChanged
call assert_equal('tare ↔ main  +2 -1  ', s:stl(), 'rendered before the timer')
call assert_true(wait(1000, {-> s:stl() ==# 'tare ↔ main  +3 -2  '}) == 0, 'timer did not render')
call assert_equal([[1, 'above', [s:pad('two')]], [1, 'add', 1],
    \ [4, 'above', [s:pad('five')]], [4, 'add', 5]], s:marks(), 'marks after the timer')

messages clear
call setline(1, 'ONE')
silent doautocmd TextChanged
TareDisable
call wait(200, {-> 0})
call assert_equal([], s:marks(), 'disabled view rendered by its timer')

TareEnable
call setline(1, 'one!')
silent doautocmd TextChanged
bwipeout!
call wait(200, {-> 0})
call assert_equal([], s:messages(), 'timer after disable or wipeout')
let g:tare_Debounce = 150


"=================================================
" A base change re-renders; `:TareBase -` goes back to the default.

let s:M = s:repo('moved', {'f.txt': ['a', 'b', 'c']})
let s:first = s:sh(s:M, 'rev-parse', 'HEAD')
call s:commit(s:M, {'f.txt': ['a', 'B', 'c']})
call s:write(s:M, {'f.txt': ['a', 'B', 'c', 'd']})
call s:open(s:M . '/f.txt')
TareEnable
call assert_equal('tare ↔ main  +1 -0  ', s:stl(), 'base main')
silent exe 'TareBase ' . s:first
call assert_equal('tare ↔ ' . s:first . '  +2 -1  ', s:stl(), 'base moved')
silent TareBase -
call assert_equal('tare ↔ main  +1 -0  ', s:stl(), 'base reset')
" A view out of sight takes the change too, and draws it when shown.
exe 'edit ' . s:M . '/g.txt'
silent exe 'TareBase ' . s:first
buffer #
call assert_equal('tare ↔ ' . s:first . '  +2 -1  ', s:stl(), 'hidden view, base moved')
call assert_equal(3, len(s:marks()), 'hidden view drawn when shown')
silent TareBase -
TareDisable

" git failing for the base side: refused with git's reason.
let s:B = s:repo('broken', {'f.txt': ['a']})
call s:write(s:B, {'f.txt': ['b']})
let s:blob = s:sh(s:B, 'rev-parse', 'HEAD:f.txt')
call delete(s:B . '/.git/objects/' . s:blob[:1] . '/' . s:blob[2:])
call s:open(s:B . '/f.txt')
call assert_match('^\ntare: ', execute('TareEnable'), 'git failure')
call assert_false(exists('b:tare'), 'view left after git failure')

silent! %bwipeout!
call delete(s:tmp, 'rf')

" vim: set et fdm=marker sts=4 sw=4:
