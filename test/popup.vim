"=================================================
" File: test/popup.vim
" Description: The float and deleted-file buffers (DESIGN.md 7, 11 M3).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded and git and
" stdpath('data') pointed away from the user's own. Failures are left in
" v:errors. Keys are typed with :normal, which applies the float's maps.

let s:tmp = resolve(tempname())
call mkdir(s:tmp, 'p')
" Not 'lines': headless 0.11.4 crashes in :redraw after 'lines' changes once
" output has scrolled.
set columns=80

function! s:sh(dir, ...) abort
    let out = system(['git', '-C', a:dir] + a:000)
    call assert_equal(0, v:shell_error, 'git ' . join(a:000) . ': ' . out)
    return trim(out)
endfunction

" Writes each file (a list of lines, or a Blob for exact bytes).
function! s:write(dir, files) abort
    for [name, content] in items(a:files)
        call writefile(content, a:dir . '/' . name)
    endfor
endfunction

function! s:commit(dir, files) abort
    call s:write(a:dir, a:files)
    call s:sh(a:dir, 'add', '-A')
    call s:sh(a:dir, 'commit', '-q', '-m', 'commit')
    return s:sh(a:dir, 'rev-parse', 'HEAD')
endfunction

function! s:repo(name, files) abort
    let dir = s:tmp . '/' . a:name
    call mkdir(dir, 'p')
    call s:sh(dir, 'init', '-q', '-b', 'main')
    call s:commit(dir, a:files)
    return dir
endfunction

function! s:floats() abort
    return filter(nvim_list_wins(), '!empty(nvim_win_get_config(v:val).relative)')
endfunction

function! s:title() abort
    return nvim_win_get_config(s:floats()[0]).title[0][0]
endfunction

function! s:reset() abort
    silent! %bwipeout!
    silent! only!
endfunction

function! s:open(path) abort
    call s:reset()
    exe 'edit ' . fnameescape(a:path)
endfunction

" The row listing `path`, 0 for none.
function! s:row(path) abort
    return index(map(getline(1, '$'), 'matchstr(v:val, "^ .  \\zs\\S*")'), a:path) + 1
endfunction

function! s:stl() abort
    return nvim_eval_statusline('%{%tare#statusline()%}', {'winid': win_getid()}).str
endfunction

" Everything opening and closing the float may touch.
function! s:snapshot() abort
    let out = {'au': execute('autocmd Tare'), 'wins': [], 'bufs': [],
        \ 'global': [&g:cursorline, &g:statusline, &g:number, &g:list, &g:fillchars],
        \ 'maps': maparg('<CR>', 'n', 0, 1)}
    for info in getwininfo()
        call add(out.wins, [info.winid, info.bufnr, getwinvar(info.winid, '&cursorline'),
            \ getwinvar(info.winid, '&statusline'), getwinvar(info.winid, '&number')])
    endfor
    for info in getbufinfo()
        call add(out.bufs, [info.bufnr, info.name, info.listed])
    endfor
    return out
endfunction


"=================================================
" One file of each kind. v0 is the first commit; main adds later.txt.

let s:R = s:repo('float', {'mod.txt': ['one', 'two', 'three', 'four', 'five'],
    \ 'old.txt': ['1', '2', '3', '4', '5'], 'del.py': ['x = 1', 'y = 2', 'z = 3'],
    \ 'bin.dat': 0z000102, 'eol.txt': 0z610A62, 'dos.txt': ['p', 'q']})
call s:sh(s:R, 'tag', 'v0')
let s:mb = s:commit(s:R, {'later.txt': ['l']})
call s:write(s:R, {'mod.txt': ['one', 'TWO', 'three', 'four', 'five', 'six'],
    \ 'bin.dat': 0z000103, 'eol.txt': 0z610A620A, 'dos.txt': 0z700D0A710D0A,
    \ 'untracked.txt': ['u', 'v'],
    \ 'added.txt': ['n']})
call s:sh(s:R, 'mv', 'old.txt', 'new.txt')
call writefile(['1', '2', '3', '4', 'five'], s:R . '/new.txt')
call delete(s:R . '/del.py')
call s:sh(s:R, 'add', 'added.txt')

let s:LIST = [
    \ ' A  added.txt                            +1     ',
    \ ' M  bin.dat                                 bin ',
    \ ' D  del.py                                   -3 ',
    \ ' M  dos.txt                           unchanged ',
    \ ' M  eol.txt                           unchanged ',
    \ ' M  mod.txt                              +2  -1 ',
    \ ' R  old.txt → new.txt                    +1  -1 ',
    \ ' A  untracked.txt  (untracked)           +2     ',
    \ ]


"=================================================
" Rendering.

call s:open(s:R . '/mod.txt')
let s:before = s:snapshot()
let s:origin = win_getid()
Tare
call assert_equal(1, len(s:floats()), 'one float')
call assert_equal(s:LIST, getline(1, '$'), 'listing')
call assert_equal(' tare ↔ main @ ' . s:mb[:7] . ' ', s:title(), 'title')
call assert_equal([48, len(s:LIST)], [winwidth(0), winheight(0)], 'size')
call assert_equal(s:row('mod.txt'), line('.'), 'cursor on the current file')
call assert_equal('nofile', &buftype, 'float buffer')
call assert_false(&modifiable, 'float modifiable')

" The text under each highlight on the mod.txt row.
let s:hl = []
for [_, _, s:col, s:d] in nvim_buf_get_extmarks(0, -1, [line('.') - 1, 0], [line('.') - 1, -1],
        \ {'details': v:true})
    call add(s:hl, [s:d.hl_group, getline('.')[s:col : s:d.end_col - 1]])
endfor
call assert_equal([['TareFloatStatus', 'M'], ['TareFloatAdd', '+2'], ['TareFloatDelete', '-1']],
    \ s:hl, 'highlights')

normal q
call assert_equal([], s:floats(), 'q')
call assert_equal(s:before, s:snapshot(), 'open and close left state')

Tare
exe "normal \<Esc>"
call assert_equal(s:before, s:snapshot(), '<Esc>')

Tare
wincmd p
call assert_equal(s:before, s:snapshot(), 'WinLeave')

Tare
Tare
call assert_equal(s:before, s:snapshot(), ':Tare from the float')

" The counts column grows for wide counts; long paths lose their start.
call s:open(s:R . '/mod.txt')
set columns=40
Tare
call assert_equal(' D  del.py           -3 ', getline(3), 'narrow row')
call assert_equal(' R  …new.txt     +1  -1 ', getline(s:row('…new.txt')), 'narrow rename')
normal q
set columns=80

" A clean repository.
let s:C = s:repo('clean', {'f.txt': ['a']})
call s:open(s:C . '/f.txt')
Tare
call assert_equal([' no changes vs main'], getline(1, '$'), 'empty listing')
exe "normal \<CR>"
call assert_equal(1, len(s:floats()), '<CR> on no row')
normal q


"=================================================
" Opening files.

call s:open(s:R . '/new.txt')
let s:origin = win_getid()
split
call assert_true(win_getid() != s:origin, 'split')
call win_gotoid(s:origin)
Tare
call cursor(s:row('mod.txt'), 1)
exe "normal \<CR>"
call assert_equal([], s:floats(), '<CR> closed the float')
call assert_equal(s:origin, win_getid(), '<CR> went back')
call assert_equal(s:R . '/mod.txt', expand('%:p'), '<CR> opened')
call assert_equal('tare ↔ main  +2 -1  ', s:stl(), '<CR> enabled the view')
let s:modbuf = bufnr('%')

wincmd w
Tare
call cursor(s:row('mod.txt'), 1)
exe "normal \<CR>"
call assert_equal(s:modbuf, bufnr('%'), 'loaded buffer reused')
call assert_equal(1, len(filter(getbufinfo(), 'v:val.name =~# "mod.txt$"')), 'one mod.txt')
TareDisable

Tare
call cursor(s:row('untracked.txt'), 1)
normal o
call assert_equal(s:R . '/untracked.txt', expand('%:p'), 'o opened')
call assert_false(exists('b:tare'), 'o enabled the view')

let g:tare_ViewOnOpen = 0
Tare
call cursor(s:row('old.txt'), 1)
exe "normal \<CR>"
call assert_equal(s:R . '/new.txt', expand('%:p'), 'rename opened')
call assert_false(exists('b:tare'), 'g:tare_ViewOnOpen 0')
let g:tare_ViewOnOpen = 1

Tare
call cursor(s:row('bin.dat'), 1)
exe "normal \<CR>"
call assert_equal(s:R . '/bin.dat', expand('%:p'), 'binary opened')
call assert_false(exists('b:tare'), 'view on a binary')

" git counts a changed final newline, and CRLF for LF, as changed lines; the
" float agrees with the view instead.
for s:name in ['eol.txt', 'dos.txt']
    Tare
    call cursor(s:row(s:name), 1)
    exe "normal \<CR>"
    call assert_equal('tare ↔ main  unchanged  ', s:stl(), s:name . ' view')
    TareDisable
endfor
call assert_match('^2\t2\tdos.txt\n1\t1\teol.txt$', s:sh(s:R, 'diff', '--numstat', 'main',
    \ '--', 'eol.txt', 'dos.txt'), 'git numstat')


"=================================================
" A deleted file: a scratch buffer of its base side, gone once out of sight.

call s:open(s:R . '/mod.txt')
let s:winstl = &l:statusline
Tare
call cursor(s:row('del.py'), 1)
exe "normal \<CR>"
call assert_equal('tare://' . s:mb . '/del.py', bufname('%'), 'deleted name')
call assert_equal(['x = 1', 'y = 2', 'z = 3'], getline(1, '$'), 'deleted text')
call assert_equal(['nofile', 'wipe', 0, 0, 'python'],
    \ [&buftype, &bufhidden, &modifiable, &modified, &filetype], 'deleted options')
call assert_equal('tare ↔ main  deleted · 3 lines  ', s:stl(), 'deleted status')
call assert_equal([], nvim_buf_get_extmarks(0, -1, 0, -1, {}), 'deleted highlights')
let s:delbuf = bufnr('%')
TareDisable
call assert_equal(s:winstl, &l:statusline, 'deleted view off')
call assert_notmatch('<buffer=' . s:delbuf . '>', execute('autocmd Tare'), 'deleted view autocmds')
TareEnable
call assert_equal('tare ↔ main  deleted · 3 lines  ', s:stl(), 'deleted view on again')

" From the deleted buffer: its repository, its row; reopening reuses it.
call assert_equal(s:R, tare#git#root(s:delbuf), 'deleted root')
split
Tare
call assert_equal(s:row('del.py'), line('.'), 'cursor on the deleted file')
exe "normal \<CR>"
call assert_equal(s:delbuf, bufnr('%'), 'deleted buffer reused')
close

exe 'edit ' . s:R . '/mod.txt'
call assert_false(bufexists(s:delbuf), 'deleted buffer not wiped')
call assert_notmatch('<buffer=' . s:delbuf . '>', execute('autocmd Tare'), 'deleted autocmds')
call assert_equal(s:winstl, &l:statusline, 'deleted status line left')


"=================================================
" Changing the base, refreshing; completion follows the float's repository.

call s:open(s:R . '/mod.txt')
exe 'cd ' . fnameescape(s:tmp)
Tare
call assert_equal(['v0'], tare#popup#complete('v', '', 0), 'completion repository')
silent call feedkeys("bv0\<CR>", 'xt')
call assert_equal(1, len(s:floats()), 'float after b')
call assert_match('^ tare ↔ v0 @ ', s:title(), 'title after b')
call assert_equal(' A  later.txt                            +1     ', getline(s:row('later.txt')),
    \ 'listing after b')
call assert_equal(s:row('mod.txt'), line('.'), 'cursor kept its file')
silent call feedkeys("b-\<CR>", 'xt')
call assert_match('^ tare ↔ main @ ', s:title(), 'title after b -')
silent call feedkeys("b\<Esc>", 'xt')
call assert_match('^ tare ↔ main @ ', s:title(), 'b cancelled')

call writefile(['f'], s:R . '/fresh.txt')
normal r
call assert_equal(' A  fresh.txt  (untracked)               +1     ', getline(s:row('fresh.txt')), 'r')
normal q
call delete(s:R . '/fresh.txt')

" From a buffer with no file: the current directory's repository.
call s:reset()
exe 'cd ' . fnameescape(s:R)
setlocal buftype=nofile
Tare
call assert_equal(s:LIST, getline(1, '$'), 'from a nofile buffer')
call assert_equal(1, line('.'), 'cursor with no file')
normal q
cd -


"=================================================
" Errors: a message, no float, nothing left.

call s:reset()
exe 'cd ' . fnameescape(s:tmp)
let s:before = s:snapshot()
call assert_match('not a git repository', execute('Tare'), 'not a repository')
call assert_equal(s:before, s:snapshot(), 'state after an error')

call s:open(s:R . '/mod.txt')
let g:tare_DefaultBases = ['nope']
let s:before = s:snapshot()
call assert_match('tare: none of nope exists', execute('Tare'), 'no base')
call assert_equal(s:before, s:snapshot(), 'state after no base')
let g:tare_DefaultBases = ['upstream/main', 'origin/main', 'main', 'master']
cd -

call s:reset()
call delete(s:tmp, 'rf')

" vim: set et fdm=marker sts=4 sw=4:
