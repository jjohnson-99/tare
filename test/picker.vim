"=================================================
" File: test/picker.vim
" Description: The base picker (DESIGN.md 14, picker).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded and git and
" stdpath('data') pointed away from the user's own. Failures are left in
" v:errors. Keys are typed with :normal, which applies the picker's maps, or
" with feedkeys() where they prompt.

let s:tmp = resolve(tempname())
call mkdir(s:tmp, 'p')
let s:STORE = stdpath('data') . '/tare/bases.json'
set columns=100

function! s:sh(dir, ...) abort
    let out = system(['git', '-C', a:dir] + a:000)
    call assert_equal(0, v:shell_error, 'git ' . join(a:000) . ': ' . out)
    return trim(out)
endfunction

" Commits are dated `days` before now, so git's date order and the ages are
" fixed.
function! s:commit(dir, days, msg) abort
    let $GIT_AUTHOR_DATE = printf('%d +0000', localtime() - a:days * 86400)
    let $GIT_COMMITTER_DATE = $GIT_AUTHOR_DATE
    call writefile([a:msg], a:dir . '/' . a:msg . '.txt')
    call s:sh(a:dir, 'add', '-A')
    call s:sh(a:dir, 'commit', '-q', '-m', a:msg)
    return s:sh(a:dir, 'rev-parse', 'HEAD')
endfunction

function! s:floats() abort
    return filter(nvim_list_wins(), '!empty(nvim_win_get_config(v:val).relative)')
endfunction

function! s:config() abort
    return nvim_win_get_config(s:floats()[0])
endfunction

function! s:reset() abort
    silent! %bwipeout!
    silent! only!
endfunction

function! s:open(path) abort
    call s:reset()
    exe 'edit ' . fnameescape(a:path)
endfunction

function! s:stored() abort
    return get(json_decode(join(readfile(s:STORE), "\n")), s:R, {})
endfunction

" The row whose text contains `text`, 0 for none.
function! s:row(text) abort
    return index(map(getline(1, '$'), 'stridx(v:val, a:text) >= 0'), 1) + 1
endfunction

" Everything opening and closing the picker may touch.
function! s:snapshot() abort
    let out = {'au': execute('autocmd Tare'), 'wins': [], 'bufs': [],
        \ 'global': [&g:cursorline, &g:wrap, &g:foldenable, &g:statusline],
        \ 'maps': map(['<CR>', 'p', '<Tab>', '/', '-', 'q', '<Esc>'], 'maparg(v:val, "n", 0, 1)')}
    for info in getwininfo()
        call add(out.wins, [info.winid, info.bufnr, getwinvar(info.winid, '&cursorline'),
            \ getwinvar(info.winid, '&wrap'), getwinvar(info.winid, '&foldenable'),
            \ getwinvar(info.winid, '&statusline')])
    endfor
    for info in getbufinfo()
        call add(out.bufs, [info.bufnr, info.name, info.listed])
    endfor
    return out
endfunction


"=================================================
" main: A - B - C, origin/main at B. side forks from A, older than B; feat
" forks from B and merges side:
"
"   A(30) - B(20) ---- F1(15) - M(10) - F2(5)   feat, HEAD
"     \                        /
"      S1(25) ------- S2(12)                    side
"
" (days ago). Hidden: backup/feat, archive/s1 and origin/backup/side.

let s:R = s:tmp . '/repo'
call mkdir(s:R, 'p')
call s:sh(s:R, 'init', '-q', '-b', 'main')
let s:A = s:commit(s:R, 30, 'A')
let s:B = s:commit(s:R, 20, 'B')
call s:sh(s:R, 'checkout', '-q', '-b', 'side', s:A)
let s:S1 = s:commit(s:R, 25, 'S1')
let s:S2 = s:commit(s:R, 12, 'S2')
call s:sh(s:R, 'checkout', '-q', '-b', 'feat', s:B)
let s:F1 = s:commit(s:R, 15, 'F1')
let $GIT_COMMITTER_DATE = printf('%d +0000', localtime() - 10 * 86400)
let $GIT_AUTHOR_DATE = $GIT_COMMITTER_DATE
call s:sh(s:R, 'merge', '-q', '--no-ff', '-m', 'M merge side', 'side')
let s:M = s:sh(s:R, 'rev-parse', 'HEAD')
let s:F2 = s:commit(s:R, 5, 'F2')
call s:sh(s:R, 'checkout', '-q', 'main')
let s:C = s:commit(s:R, 11, 'C')
call s:sh(s:R, 'checkout', '-q', 'feat')
for [s:ref, s:sha] in [['refs/remotes/origin/main', s:B], ['refs/remotes/origin/feat', s:F1],
        \ ['refs/remotes/origin/side', s:S1], ['refs/remotes/origin/backup/side', s:S2],
        \ ['refs/heads/backup/feat', s:F2], ['refs/heads/archive/s1', s:S1],
        \ ['refs/tags/v1', s:F1]]
    call s:sh(s:R, 'update-ref', s:ref, s:sha)
endfor
call s:sh(s:R, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
unlet $GIT_AUTHOR_DATE $GIT_COMMITTER_DATE

" git's default order, not --first-parent or topological: S2 and F1 by date,
" and the merge-base B last although S1 is older.
let s:LIST = [
    \ '  ' . s:F2[:7] . '  5d  F2 (HEAD -> feat)',
    \ '  ' . s:M[:7] . '  1w  M merge side',
    \ '  ' . s:S2[:7] . '  1w  S2 (side)',
    \ '  ' . s:F1[:7] . '  2w  F1 (origin/feat, tag: v1)',
    \ '  ' . s:S1[:7] . '  3w  S1 (origin/side)',
    \ '● ' . s:B[:7] . '  2w  B (origin/main)',
    \ ]
let s:BRANCHES = [
    \ '  feat         5d  F2',
    \ '  main         1w  C',
    \ '  side         1w  S2',
    \ '  origin/feat  2w  F1',
    \ '● origin/main  2w  B',
    \ '  origin/side  3w  S1',
    \ ]


"=================================================
" The listing.

call s:open(s:R . '/F2.txt')
let s:before = s:snapshot()
let s:origin = win_getid()
TareBase
call assert_equal(1, len(s:floats()), 'one float')
call assert_equal(map(copy(s:LIST), '" " . v:val'), getline(1, '$'), 'listing')
call assert_equal(' tare base · feat · current: origin/main @ ' . s:B[:7] . ' ', s:config().title[0][0],
    \ 'title')
call assert_equal(' <CR> use  p pin  <Tab> branches  / ref  - default  q close ',
    \ s:config().footer[0][0], 'footer')
call assert_equal(6, line('.'), 'cursor on the merge-base')
call assert_equal(['nofile', 0], [&buftype, &modifiable], 'picker buffer')

" The text under each highlight on F1's row.
let s:hl = []
for [_, _, s:col, s:d] in nvim_buf_get_extmarks(0, -1, [3, 0], [3, -1], {'details': v:true})
    call add(s:hl, [s:d.hl_group, getline(4)[s:col : s:d.end_col - 1]])
endfor
call assert_equal([['TarePickerCurrent', ' '], ['TarePickerSha', s:F1[:7]], ['TarePickerAge', '2w'],
    \ ['TarePickerRef', ' (origin/feat, tag: v1)']], s:hl, 'highlights')

normal q
call assert_equal([], s:floats(), 'q')
call assert_equal(s:origin, win_getid(), 'q went back')
call assert_equal(s:before, s:snapshot(), 'open and close left state')

TareBase
exe "normal \<Esc>"
call assert_equal(s:before, s:snapshot(), '<Esc>')

TareBase
wincmd p
call assert_equal(s:before, s:snapshot(), 'WinLeave')

TareBase
TareBase
call assert_equal(s:before, s:snapshot(), ':TareBase from the picker')

" The branches, newest first; hidden ones and origin/HEAD are left out.
TareBase
call cursor(4, 1)
call feedkeys("\<Tab>", 'xt')
call assert_equal(map(copy(s:BRANCHES), '" " . v:val'), getline(1, '$'), 'branches')
call assert_equal(5, line('.'), 'cursor on the base branch')
call assert_match('<Tab> commits', s:config().footer[0][0], 'branches footer')
call feedkeys("\<Tab>", 'xt')
call assert_equal(4, line('.'), 'commits kept their line')
normal q

call assert_equal(['feat', 'main', 'side', 'origin/feat', 'origin/main', 'origin/side', 'v1', '-'],
    \ tare#git#complete('', 'TareBase ', 9), ':TareBase completion hides refs')

" A narrow picker cuts refs to … and keeps the hints that fit.
set columns=40
TareBase
call assert_equal('   ' . s:F1[:7] . '  2w  F1 (o…', getline(4), 'narrow')
call assert_equal(' <CR> use  p pin ', s:config().footer[0][0], 'narrow footer')
call assert_equal(24, strdisplaywidth(s:config().title[0][0]), 'narrow title')
normal q
set columns=84
TareBase
call assert_equal(' tare base · f… · current: origin/main @ ' . s:B[:7] . ' ', s:config().title[0][0],
    \ 'the branch is cut first')
normal q
set columns=100


"=================================================
" Keys.

call s:open(s:R . '/F2.txt')
TareEnable
let s:viewbuf = bufnr('%')

" <CR> takes the row's ref.
TareBase
call cursor(s:row('F1 '), 1)
silent exe "normal \<CR>"
call assert_equal([], s:floats(), '<CR> closed')
call assert_equal({'ref': 'origin/feat', 'pinned': v:false}, s:stored(), '<CR> stores the ref')
call assert_equal(s:F1, getbufvar(s:viewbuf, 'tare').mb, 'view reloaded')

" On the base's merge-base it now marks F1, and keeps the base's ref first.
TareBase
call assert_equal(s:row('F1 '), line('.'), 'cursor on the new base')
call assert_match('^ ●', getline('.'), 'marker on the new base')
call assert_match('current: origin/feat @ ', s:config().title[0][0], 'title after <CR>')
call assert_equal('   ' . s:B[:7] . '  2w  B (origin/main)', getline('$'), 'still to the default base')
call cursor(s:row('M merge'), 1)
silent exe "normal \<CR>"
call assert_equal({'ref': s:M, 'pinned': v:true}, s:stored(), '<CR> with no ref pins')
call assert_match('tare ↔ ' . s:M[:7], nvim_eval_statusline(&l:statusline, {}).str,
    \ 'status line follows')

" p always pins, even a row with refs; the title then has no ` @ `.
TareBase
call assert_match('current: ' . s:M[:7] . ' $', s:config().title[0][0], 'pinned title')
call cursor(s:row('F1 '), 1)
silent normal p
call assert_equal({'ref': s:F1, 'pinned': v:true}, s:stored(), 'p')

" HEAD's own branch is not a ref to store: its row is pinned.
TareBase
call cursor(1, 1)
silent exe "normal \<CR>"
call assert_equal({'ref': s:F2, 'pinned': v:true}, s:stored(), '<CR> on HEAD')

" From the branches: <CR> follows, p pins the merge-base.
TareBase
call feedkeys("\<Tab>", 'xt')
call cursor(s:row('side '), 1)
silent exe "normal \<CR>"
call assert_equal({'ref': 'side', 'pinned': v:false}, s:stored(), '<CR> on a branch')
TareBase
call feedkeys("\<Tab>", 'xt')
call assert_equal(s:row('side '), line('.'), 'cursor on the base branch')
call assert_match('^ ●', getline('.'), 'marker on the base branch')
silent normal p
call assert_equal({'ref': s:S2, 'pinned': v:true}, s:stored(), 'p on a branch')

" / asks; nothing typed keeps the picker.
TareBase
silent call feedkeys("/\<Esc>", 'xt')
call assert_equal(1, len(s:floats()), '/ cancelled')
call assert_equal(['v1'], tare#picker#complete('v', '', 0), '/ completion')
silent call feedkeys("/v1\<CR>", 'xt')
call assert_equal([], s:floats(), '/ closed')
call assert_equal({'ref': 'v1', 'pinned': v:false}, s:stored(), '/')

TareBase
silent normal -
call assert_equal({}, s:stored(), '-')
call assert_equal('origin/main', getbufvar(s:viewbuf, 'tare').label, '- reloaded')

" Unchanged by q.
TareBase
call cursor(2, 1)
normal q
call assert_equal({}, s:stored(), 'q stores nothing')
TareDisable


"=================================================
" From the file float: `b` opens the picker, which brings the float back.

call s:open(s:R . '/F2.txt')
let s:before = s:snapshot()
Tare
call cursor(s:row('F1.txt'), 1)
normal b
call assert_equal(1, len(s:floats()), 'b: one float')
call assert_match('^ tare base · ', s:config().title[0][0], 'b opened the picker')
normal q
call assert_match('^ tare ↔ origin/main @ ', s:config().title[0][0], 'q: the float is back')
call assert_equal(s:row('F1.txt'), line('.'), 'q: on its file')
normal b
call cursor(s:row('S2 '), 1)
silent exe "normal \<CR>"
call assert_equal(1, len(s:floats()), 'pick: one float')
call assert_match('^ tare ↔ side @ ' . s:S2[:7], s:config().title[0][0], 'pick: float refreshed')
call assert_equal(0, s:row('S1.txt'), 'pick: listed against the new base')
call assert_equal(s:row('F1.txt'), line('.'), 'pick: on its file')
normal q
call assert_equal(s:before, s:snapshot(), 'b, pick, q left state')
silent TareBase -


"=================================================
" Fallbacks: HEAD's latest commits, at most 50.

call s:sh(s:R, 'checkout', '-q', 'main')
let g:tare_DefaultBases = ['main']
call s:open(s:R . '/C.txt')
TareBase
call assert_equal(['C', 'B', 'A'], map(getline(1, '$'), 'matchstr(v:val, "  \\zs\\u\\>")'),
    \ 'on the default base')
call assert_match(' (HEAD -> main)$', getline(1), 'HEAD on main')
call assert_equal(1, line('.'), 'cursor on the merge-base, HEAD')
normal q

let g:tare_DefaultBases = ['nope']
let s:msgs = execute('TareBase')
call assert_match('tare: none of nope exists', s:msgs, 'no default base reported')
call assert_match(' current: none ', s:config().title[0][0], 'no default base title')
call assert_equal(3, line('$'), 'no default base listing')
call assert_equal(-1, stridx(join(getline(1, '$')), '●'), 'no default base, no marker')
normal q
let g:tare_DefaultBases = ['upstream/main', 'origin/main', 'main', 'master']

" A long branch is listed whole.
call s:sh(s:R, 'checkout', '-q', '--detach')
for s:i in range(50)
    call s:sh(s:R, 'commit', '-q', '--allow-empty', '-m', 'e' . s:i)
endfor
TareBase
call assert_equal(52, line('$'), 'no limit with a default base')
normal q
let g:tare_DefaultBases = ['nope']
silent TareBase
let g:tare_DefaultBases = ['upstream/main', 'origin/main', 'main', 'master']
call assert_equal(50, line('$'), 'at most 50')
call assert_match(' (HEAD)$', getline(1), 'detached HEAD')
call assert_match('^ tare base · HEAD · ', s:config().title[0][0], 'detached title')
normal q
call s:sh(s:R, 'checkout', '-q', 'feat')

" Errors: a message, no float, nothing left.
call s:reset()
exe 'cd ' . fnameescape(s:tmp)
let s:before = s:snapshot()
call assert_match('not a git repository', execute('TareBase'), 'not a repository')
call assert_equal(s:before, s:snapshot(), 'state after an error')
exe 'cd ' . fnameescape(fnamemodify(s:tmp, ':h'))

call s:reset()
set columns=80
call delete(s:tmp, 'rf')

" vim: set et fdm=marker sts=4 sw=4:
