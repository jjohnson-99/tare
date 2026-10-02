"=================================================
" File: test/git.vim
" Description: The git layer against throwaway repositories (DESIGN.md 5, 10).
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded and git and
" stdpath('data') pointed away from the user's own. Failures are left in
" v:errors.

if empty($XDG_DATA_HOME) || stridx(stdpath('data'), $XDG_DATA_HOME) != 0
    throw 'refusing to run against the real stdpath("data")'
endif

let s:plugin = expand('<sfile>:p:h:h')
let s:STORE = stdpath('data') . '/tare/bases.json'

" git reports real paths, and the temporary directory may sit behind a symlink.
let s:tmp = tempname()
call mkdir(s:tmp, 'p')
let s:tmp = resolve(s:tmp)

function! s:sh(dir, ...) abort
    let out = system(['git', '-C', a:dir] + a:000)
    call assert_equal(0, v:shell_error, 'git ' . join(a:000) . ': ' . out)
    return trim(out)
endfunction

function! s:repo(name) abort
    let dir = s:tmp . '/' . a:name
    call mkdir(dir, 'p')
    call s:sh(dir, 'init', '-q', '-b', 'main')
    return dir
endfunction

" Writes each file (a list of lines or a Blob), commits all, returns the SHA.
function! s:commit(dir, files, msg) abort
    for [name, content] in items(a:files)
        call writefile(content, a:dir . '/' . name)
    endfor
    call s:sh(a:dir, 'add', '-A')
    call s:sh(a:dir, 'commit', '-q', '-m', a:msg)
    return s:sh(a:dir, 'rev-parse', 'HEAD')
endfunction

" What `F` throws, '' when it returns.
function! s:thrown(F) abort
    try
        call a:F()
    catch
        return v:exception
    endtry
    return ''
endfunction

function! s:stored() abort
    return json_decode(join(readfile(s:STORE), "\n"))
endfunction

function! s:file(status, path, old, added, removed, binary, untracked) abort
    return {'status': a:status, 'path': a:path, 'old': a:old, 'added': a:added,
        \ 'removed': a:removed, 'binary': a:binary, 'untracked': a:untracked}
endfunction


"=================================================
" The listing: one of each kind of change.

let s:L = s:repo('listing')
let s:Lmb = s:commit(s:L, {'mod.txt': ['a', 'b', 'c'], 'del.txt': ['x'],
    \ 'old.txt': ['1', '2', '3', '4', '5'], 'sp ace.txt': ['q'], 'staged.txt': ['s'],
    \ 'bin.dat': 0z000102, 'empty.txt': [], '.gitignore': ['*.log']}, 'init')
call writefile(['x', 'y'], s:L . '/nonl.txt', 'b')
let s:Lmb = s:commit(s:L, {}, 'no final newline')

call writefile(['a', 'B', 'c', 'd'], s:L . '/mod.txt')
call delete(s:L . '/del.txt')
call s:sh(s:L, 'mv', 'old.txt', 'new.txt')
call writefile(['1', '2', '3', '4', 'five'], s:L . '/new.txt')
call writefile(0z00030205, s:L . '/bin.dat')
call writefile(['q', 'r'], s:L . '/sp ace.txt')
call writefile(['S'], s:L . '/staged.txt')
call writefile(['n'], s:L . '/added.txt')
call s:sh(s:L, 'add', 'staged.txt', 'added.txt')
call writefile(['u', 'v'], s:L . '/untracked.txt')
call writefile(0z00FF, s:L . '/untracked.bin')
call writefile(['ignored'], s:L . '/x.log')

call assert_equal([
    \ s:file('A', 'added.txt', '', 1, 0, 0, 0),
    \ s:file('M', 'bin.dat', 'bin.dat', 0, 0, 1, 0),
    \ s:file('D', 'del.txt', 'del.txt', 0, 1, 0, 0),
    \ s:file('M', 'mod.txt', 'mod.txt', 2, 1, 0, 0),
    \ s:file('R', 'new.txt', 'old.txt', 1, 1, 0, 0),
    \ s:file('M', 'sp ace.txt', 'sp ace.txt', 1, 0, 0, 0),
    \ s:file('M', 'staged.txt', 'staged.txt', 1, 1, 0, 0),
    \ s:file('A', 'untracked.bin', '', 0, 0, 1, 1),
    \ s:file('A', 'untracked.txt', '', 2, 0, 0, 1),
    \ ], tare#git#changes(s:L, s:Lmb), 'listing')

call assert_equal(['a', 'b', 'c'], tare#git#show(s:L, s:Lmb, 'mod.txt'), 'show')
call assert_equal(['1', '2', '3', '4', '5'], tare#git#show(s:L, s:Lmb, 'old.txt'), 'rename base')
call assert_equal(['q'], tare#git#show(s:L, s:Lmb, 'sp ace.txt'), 'show, space')
call assert_equal(['x', 'y'], tare#git#show(s:L, s:Lmb, 'nonl.txt'), 'show, no final newline')
call assert_equal([], tare#git#show(s:L, s:Lmb, 'empty.txt'), 'show, empty')

" A fetched blob is served from the cache once git can no longer answer.
call rename(s:L . '/.git', s:L . '/.git-off')
call assert_equal(['a', 'b', 'c'], tare#git#show(s:L, s:Lmb, 'mod.txt'), 'cached show')
call assert_match('^tare: ', s:thrown({-> tare#git#show(s:L, s:Lmb, 'del.txt')}), 'uncached show')
call rename(s:L . '/.git-off', s:L . '/.git')

" One cat-file for many paths fills the cache as show would.
let s:P = s:repo('prefetch')
let s:Pmb = s:commit(s:P, {'a.txt': ['a', 'b'], 'blank.txt': ['a', ''], 'nonl.txt': 0z780A79,
    \ 'empty.txt': [], 'sp ace.txt': ['q'], 'cr.txt': 0z610D0A, 'nul.txt': 0z610A0062}, 'init')
let s:names = ['a.txt', 'blank.txt', 'nonl.txt', 'empty.txt', 'sp ace.txt', 'cr.txt', 'nul.txt']
call tare#git#prefetch(s:P, s:Pmb, s:names + ['missing.txt'])
call rename(s:P . '/.git', s:P . '/.git-off')
call assert_equal([['a', 'b'], ['a', ''], ['x', 'y'], [], ['q'], ["a\r"], ['a', "\nb"]],
    \ map(copy(s:names), 'tare#git#show(s:P, s:Pmb, v:val)'), 'prefetch')
call assert_match('^tare: ', s:thrown({-> tare#git#show(s:P, s:Pmb, 'missing.txt')}), 'prefetch, missing')
call rename(s:P . '/.git-off', s:P . '/.git')


"=================================================
" Base resolution. main: A - C; feature: A - B.

let s:B = s:repo('base')
let s:A = s:commit(s:B, {'f.txt': ['1']}, 'A')
call s:sh(s:B, 'checkout', '-q', '-b', 'feature')
call s:commit(s:B, {'g.txt': ['feature']}, 'B')
call s:sh(s:B, 'checkout', '-q', 'main')
let s:C = s:commit(s:B, {'f.txt': ['1', 'upstream']}, 'C')
call s:sh(s:B, 'checkout', '-q', 'feature')

call assert_equal(s:B, tare#git#root(bufadd(s:B . '/sub/not/yet/x.txt')), 'root of a new file')
call assert_match('not a git repository',
    \ s:thrown({-> tare#git#root(bufadd(s:tmp . '/x.txt'))}), 'not a repository')

let s:base = tare#git#resolve(s:B)
call assert_equal({'ref': 'main', 'pinned': v:false, 'default': v:true, 'mb': s:A},
    \ s:base, 'first default')
call assert_equal([s:file('A', 'g.txt', '', 1, 0, 0, 0)], tare#git#changes(s:B, s:A),
    \ 'upstream commits HEAD lacks are not removals')

call s:sh(s:B, 'update-ref', 'refs/remotes/origin/main', s:C)
call assert_equal('origin/main', tare#git#resolve(s:B).ref, 'origin/main before main')
call s:sh(s:B, 'update-ref', 'refs/remotes/upstream/main', s:C)
call assert_equal('upstream/main', tare#git#resolve(s:B).ref, 'upstream/main first')

let s:defaults = g:tare_DefaultBases
let g:tare_DefaultBases = ['nope']
call assert_equal('tare: none of nope exists; set a base with :TareBase',
    \ s:thrown({-> tare#git#resolve(s:B)}), 'no default found')
let g:tare_DefaultBases = s:defaults

call assert_equal('tare: unknown ref nope', s:thrown({-> tare#git#set(s:B, 'nope', 0)}), 'unknown ref')
call assert_equal('tare: unknown ref -p', s:thrown({-> tare#git#set(s:B, '-p', 0)}), 'option-like ref')

call s:sh(s:B, 'checkout', '-q', '--detach')
call assert_equal(s:A, tare#git#resolve(s:B).mb, 'detached HEAD')
call s:sh(s:B, 'checkout', '-q', 'feature')


"=================================================
" A ref follows its branch; a pin does not.

call assert_equal({'ref': 'main', 'pinned': v:false, 'default': v:false, 'mb': s:A},
    \ tare#git#set(s:B, 'main', 0), 'set')
call assert_equal({s:B: {'ref': 'main', 'pinned': v:false}}, s:stored(), 'stored ref')
call s:sh(s:B, 'merge', '-q', '--no-edit', 'main')
call assert_equal(s:C, tare#git#resolve(s:B).mb, 'ref followed')

call assert_equal({'ref': s:C, 'pinned': v:true, 'default': v:false, 'mb': s:C},
    \ tare#git#set(s:B, '', 1), 'pin current')
call assert_equal({s:B: {'ref': s:C, 'pinned': v:true}}, s:stored(), 'stored pin')
call s:sh(s:B, 'checkout', '-q', 'main')
let s:D = s:commit(s:B, {'f.txt': ['1', 'upstream', 'D']}, 'D')
call s:sh(s:B, 'checkout', '-q', 'feature')
call s:sh(s:B, 'merge', '-q', '--no-edit', 'main')
call assert_equal(s:C, tare#git#resolve(s:B).mb, 'pin held')
call assert_equal(s:D, tare#git#set(s:B, 'main', 0).mb, 'ref again')

" FocusGained re-resolves every repository seen.
runtime autoload/tare.vim
call s:sh(s:B, 'checkout', '-q', 'main')
let s:E = s:commit(s:B, {'f.txt': ['E']}, 'E')
call s:sh(s:B, 'checkout', '-q', 'feature')
call s:sh(s:B, 'merge', '-q', '--no-edit', '-X', 'theirs', 'main')
doautocmd FocusGained
call assert_equal(s:E, tare#git#cached(s:B).mb, 'FocusGained')


"=================================================
" Persistence, per toplevel: a second worktree of the same repository keeps
" its own base, and a fresh Neovim reads both back.

let s:W = s:tmp . '/base-wt'
call s:sh(s:B, 'worktree', 'add', '-q', '-b', 'wt', s:W, 'main')
call assert_equal('upstream/main', tare#git#resolve(s:W).ref, 'other worktree unaffected')
call tare#git#set(s:W, 'feature', 0)
call assert_equal({s:B: {'ref': 'main', 'pinned': v:false},
    \ s:W: {'ref': 'feature', 'pinned': v:false}}, s:stored(), 'both stored')
call assert_equal([s:STORE], glob(fnamemodify(s:STORE, ':h') . '/*', 1, 1), 'no temp file left')

let s:out = system(['nvim', '--headless', '-u', 'NONE', '--cmd', 'set rtp^=' . s:plugin,
    \ '-c', 'runtime plugin/tare.vim', '-c', printf('echo tare#git#resolve(%s).ref '
    \ . '.. "," .. tare#git#resolve(%s).ref', string(s:B), string(s:W)), '-c', 'qa!'])
call assert_match('main,feature', s:out, 'read back after restart')

" A file that is not an object reads as empty; bad entries are dropped.
for s:junk in ['not json{', '[]', '']
    call writefile([s:junk], s:STORE)
    let s:msgs = execute('let g:tare_test = tare#git#resolve(s:B)')
    call assert_true(g:tare_test.default, 'corrupt store: ' . s:junk)
    call assert_match('ignoring unreadable', s:msgs, 'corrupt store warns: ' . s:junk)
endfor
call writefile([json_encode({s:B: {'ref': 3}, s:W: {'ref': 'feature', 'pinned': 'yes'}})], s:STORE)
call assert_true(tare#git#resolve(s:B).default, 'malformed entry dropped')
call assert_equal({'ref': 'feature', 'pinned': v:false, 'default': v:false, 'mb': s:E},
    \ tare#git#resolve(s:W), 'malformed pinned is not a pin')
call tare#git#set(s:B, 'main', 0)
call assert_equal({s:B: {'ref': 'main', 'pinned': v:false},
    \ s:W: {'ref': 'feature', 'pinned': v:false}}, s:stored(), 'rewritten clean')
unlet g:tare_test


"=================================================
" HEAD with no commits, and HEAD unrelated to the base.

let s:O = s:repo('orphan')
call assert_match('none of', s:thrown({-> tare#git#resolve(s:O)}), 'empty repository')
call s:commit(s:O, {'f.txt': ['1']}, 'A')
call s:sh(s:O, 'checkout', '-q', '--orphan', 'lone')
call assert_equal('tare: HEAD has no commits yet', s:thrown({-> tare#git#resolve(s:O)}), 'unborn')
call s:commit(s:O, {'f.txt': ['2']}, 'lone')
call assert_equal('tare: HEAD and main have no common ancestor',
    \ s:thrown({-> tare#git#resolve(s:O)}), 'unrelated')


"=================================================
" Commands, completion and the status line, from a buffer in the repository.

exe 'edit ' . fnameescape(s:B . '/f.txt')
call assert_equal("\ntare: base main, merge-base " . s:E[:7], execute('TareBase'), ':TareBase')
call assert_match('tare: unknown ref nope', execute('TareBase nope'), ':TareBase bad ref')
call assert_equal("\ntare: base pinned at " . s:E[:7], execute('TareBase! main'), ':TareBase!')
call assert_equal({'ref': s:E, 'pinned': v:true}, s:stored()[s:B], ':TareBase! stored')

TareEnable
call assert_equal('tare ↔ ' . s:E[:7] . '  unchanged  ',
    \ nvim_eval_statusline('%{%tare#statusline()%}', {'winid': win_getid()}).str, 'pinned label')
TareDisable
silent TareBase upstream/main
call assert_equal({'ref': 'upstream/main', 'pinned': v:false}, s:stored()[s:B], ':TareBase stored')

call s:sh(s:B, 'tag', 'v1', s:A)
call s:sh(s:B, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
call assert_equal(['feature', 'main', 'wt', 'origin/main', 'upstream/main', 'v1', '-'],
    \ tare#git#complete('', 'TareBase ', 9), 'completion')
call assert_equal(['-'], tare#git#complete('-', 'TareBase -', 10), 'completion of -')

" `-` forgets the repository's base and leaves the other worktree's.
call assert_match("^\ntare: base upstream/main (default), merge-base \\x\\{8}$",
    \ execute('TareBase -'), ':TareBase -')
call assert_equal({s:W: {'ref': 'feature', 'pinned': v:false}}, s:stored(), ':TareBase - stored')
call assert_match("tare: there is no base to pin in '-'", execute('TareBase! -'), ':TareBase! -')
call assert_match("^\ntare: base upstream/main (default), merge-base \\x\\{8}$",
    \ execute('TareBase -'), ':TareBase - again')
call assert_equal(['upstream/main'], tare#git#complete('up', 'TareBase up', 11), 'completion lead')

" Outside a repository the view refuses and leaves nothing behind.
exe 'edit ' . fnameescape(s:tmp . '/x.txt')
call assert_match('not a git repository', execute('TareEnable'), 'enable outside a repository')
call assert_false(exists('b:tare'), 'view left after refusal')
call assert_notmatch('<buffer=', execute('autocmd Tare'), 'autocmds left after refusal')

silent! %bwipeout!
call delete(s:tmp, 'rf')

" vim: set et fdm=marker sts=4 sw=4:
