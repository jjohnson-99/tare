"=================================================
" File: autoload/tare/git.vim
" Description: Repository, base and changed-file queries, answered by git.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" git is only read (DESIGN.md 1.3.5), and with --no-optional-locks, so not even
" the index's stat cache is rewritten. Failures throw 'tare: <reason>'.


" Avoid installing twice.
if exists('g:autoloaded_tare_git')
    finish
endif
let g:autoloaded_tare_git = 0

" Last resolution of each repository, by toplevel: {ref, pinned, default, mb}.
let s:bases = {}

" Base-side file contents by '<merge-base>:<path>'. Content at a SHA never
" changes; an entry goes only when no repository's base is that SHA any more.
let s:blobs = {}


"=================================================
" Running git. A job, not systemlist(), because only a job keeps stderr apart
" from stdout; jobwait() keeps it synchronous.

" [exit code, stdout, stderr], each stream a list of lines as a job delivers it.
" [input] is a list of lines for git's stdin.
function! s:run(root, args, ...) abort
    if !executable('git')
        throw 'tare: git is not installed'
    endif
    let opts = {'stdin': a:0 ? 'pipe' : 'null', 'stdout_buffered': v:true,
        \ 'stderr_buffered': v:true}
    let job = jobstart(['git', '--no-optional-locks', '-C', a:root] + a:args, opts)
    if a:0
        call chansend(job, a:1 + [''])
        call chanclose(job, 'stdin')
    endif
    let code = jobwait([job])[0]
    if code < 0
        call jobstop(job)
        throw 'tare: git interrupted'
    endif
    return [code, opts.stdout, opts.stderr]
endfunction

" git's first message line, without its 'fatal: ' or 'error: ' label.
function! s:reason(err) abort
    let lines = filter(copy(a:err), '!empty(v:val)')
    return empty(lines) ? 'git failed' : substitute(lines[0], '^\l\+: ', '', '')
endfunction

function! s:git(root, args, ...) abort
    let [code, out, err] = call('s:run', [a:root, a:args] + a:000)
    if code != 0
        throw 'tare: ' . s:reason(err)
    endif
    return out
endfunction

" The fields of -z output. A NUL arrives as NL inside an item and a real NL
" (only ever inside a path) as an item break, so both can be told apart.
function! s:fields(out) abort
    return split(join(map(copy(a:out), 'tr(v:val, "\n", "\x01")'), "\n"), "\x01")
endfunction

" The full SHA of the commit `rev` names, or '' for none.
function! s:verify(root, rev) abort
    if a:rev =~# '^-'
        return ''
    endif
    let [code, out] = s:run(a:root, ['rev-parse', '--verify', '--quiet', a:rev . '^{commit}'])[0:1]
    return code == 0 ? out[0] : ''
endfunction


" The toplevel of the repository holding buffer `bufnr`'s file; for a buffer
" with no file, the current directory's. A deleted file's base-side buffer
" (tare#popup) belongs to the repository it was taken from.
function! tare#git#root(bufnr) abort
    let deleted = getbufvar(a:bufnr, 'tare_deleted', {})
    if !empty(deleted)
        return deleted.root
    endif
    let name = bufname(a:bufnr)
    let dir = empty(name) || !empty(getbufvar(a:bufnr, '&buftype'))
        \ ? getcwd() : fnamemodify(name, ':p:h')
    " A new file's directory may not exist yet.
    while !isdirectory(dir) && dir !=# fnamemodify(dir, ':h')
        let dir = fnamemodify(dir, ':h')
    endwhile
    let [code, out, err] = s:run(dir, ['rev-parse', '--show-toplevel'])
    if code != 0
        throw 'tare: ' . fnamemodify(dir, ':~') . ': ' . s:reason(err)
    endif
    return out[0]
endfunction


"=================================================
" Persistence: stdpath('data')/tare/bases.json, {toplevel: {ref, pinned}}.
" Read on every resolution, so a base set in another Neovim is picked up.

function! s:storePath() abort
    return stdpath('data') . '/tare/bases.json'
endfunction

" A file that is not a JSON object reads as empty; malformed entries are dropped.
function! s:load() abort
    let path = s:storePath()
    if !filereadable(path)
        return {}
    endif
    try
        let data = json_decode(join(readfile(path), "\n"))
    catch
        let data = v:null
    endtry
    if type(data) != v:t_dict
        echohl WarningMsg | echomsg 'tare: ignoring unreadable ' . path | echohl None
        return {}
    endif
    call filter(data, {_, v -> type(v) == v:t_dict
        \ && type(get(v, 'ref')) == v:t_string && !empty(v.ref)})
    return map(data, {_, v -> {'ref': v.ref,
        \ 'pinned': get(v, 'pinned') is v:true ? v:true : v:false}})
endfunction

" Written to a temporary file and renamed over, so no reader sees half a file.
" An empty entry removes the repository's.
function! s:store(root, entry) abort
    let data = s:load()
    if !empty(a:entry)
        let data[a:root] = a:entry
    elseif has_key(data, a:root)
        call remove(data, a:root)
    else
        return
    endif
    let path = s:storePath()
    let tmp = path . '.' . getpid()
    try
        call mkdir(fnamemodify(path, ':h'), 'p')
        if writefile([json_encode(data)], tmp) != 0 || rename(tmp, path) != 0
            throw 'failed'
        endif
    catch
        call delete(tmp)
        throw 'tare: cannot write ' . path
    endtry
endfunction


"=================================================
" Base resolution.

" The first of g:tare_DefaultBases that names a commit.
function! s:defaultRef(root) abort
    for ref in g:tare_DefaultBases
        if !empty(s:verify(a:root, ref))
            return ref
        endif
    endfor
    throw 'tare: none of ' . join(g:tare_DefaultBases, ', ')
        \ . ' exists; set a base with :TareBase'
endfunction

" A pinned SHA as is; otherwise where HEAD and the ref diverged, so upstream
" commits HEAD lacks never show as removals.
function! s:mergeBase(root, ref, pinned) abort
    if a:pinned
        let sha = s:verify(a:root, a:ref)
        if empty(sha)
            throw 'tare: pinned base ' . a:ref[:7] . ' no longer exists'
        endif
        return sha
    endif
    if a:ref =~# '^-'
        throw 'tare: unknown ref ' . a:ref
    endif
    let [code, out] = s:run(a:root, ['merge-base', 'HEAD', a:ref])[0:1]
    if code == 0
        return out[0]
    elseif empty(s:verify(a:root, 'HEAD'))
        throw 'tare: HEAD has no commits yet'
    elseif empty(s:verify(a:root, a:ref))
        throw 'tare: unknown ref ' . a:ref
    endif
    throw 'tare: HEAD and ' . a:ref . ' have no common ancestor'
endfunction

function! s:remember(root, base) abort
    let s:bases[a:root] = a:base
    let live = map(values(s:bases), 'v:val.mb')
    call filter(s:blobs, {key, _ -> index(live, matchstr(key, '^[^:]*')) >= 0})
    return a:base
endfunction

" Resolves `root`'s base now: the stored one, else the first default that
" exists. A failure leaves the last good resolution in place.
function! tare#git#resolve(root) abort
    let entry = get(s:load(), a:root, {})
    let default = empty(entry) ? v:true : v:false
    if default
        let entry = {'ref': s:defaultRef(a:root), 'pinned': v:false}
    endif
    return s:remember(a:root, extend(entry,
        \ {'default': default, 'mb': s:mergeBase(a:root, entry.ref, entry.pinned)}))
endfunction

" Sets and stores `root`'s base. Pinning stores the merge-base, which then never
" moves; an empty `ref` pins the current one.
function! tare#git#set(root, ref, pin) abort
    let mb = empty(a:ref) ? tare#git#resolve(a:root).mb : s:mergeBase(a:root, a:ref, v:false)
    let entry = a:pin || empty(a:ref) ? {'ref': mb, 'pinned': v:true}
        \ : {'ref': a:ref, 'pinned': v:false}
    call s:store(a:root, entry)
    return s:remember(a:root, extend(entry, {'default': v:false, 'mb': mb}))
endfunction

" Forgets `root`'s stored base, so it takes the first default again.
function! tare#git#reset(root) abort
    call s:store(a:root, {})
    return tare#git#resolve(a:root)
endfunction

" The last resolution for `root`, {} for none; runs no git, for status lines.
function! tare#git#cached(root) abort
    return get(s:bases, a:root, {})
endfunction

function! tare#git#roots() abort
    return keys(s:bases)
endfunction

" A base as the user sees it named: its ref, or a pinned base's short SHA.
function! tare#git#label(base) abort
    return a:base.pinned ? a:base.mb[:7] : a:base.ref
endfunction


"=================================================
" Changed files.

" Every file that differs between `mb` and the working tree, sorted by path:
"   {status, path, old, added, removed, binary, untracked}
" `old` is the path at `mb`: '' when added, the source path for a rename.
" Statuses and counts come from one `git diff`, so they describe one tree.
function! tare#git#changes(root, mb) abort
    let fields = s:fields(s:git(a:root, ['diff', '--no-color', '--no-ext-diff',
        \ '--no-textconv', '-M', '-z', '--raw', '--numstat', a:mb, '--']))
    let files = []
    let counts = {}
    let i = 0
    while i < len(fields)
        let field = fields[i]
        if field[0] ==# ':'
            " ':<modes> <SHAs> <status><score>', then a path, two for R and C.
            let status = field[strridx(field, ' ') + 1]
            let two = status =~# '[RC]'
            call add(files, {'status': status, 'path': fields[i + 1 + two],
                \ 'old': status ==# 'A' ? '' : fields[i + 1], 'untracked': 0})
            let i += 2 + two
        else
            " '<added>\t<removed>\t<path>'; a rename has no path, its two follow.
            " Both counts are '-' for a binary file.
            let [added, removed, path] = matchlist(field, '^\(\S*\)\t\(\S*\)\t\(.*\)')[1:3]
            if empty(path)
                let path = fields[i + 2]
                let i += 2
            endif
            let counts[path] = [added, removed]
            let i += 1
        endif
    endwhile
    for file in files
        let [added, removed] = get(counts, file.path, ['0', '0'])
        call extend(file, {'added': str2nr(added), 'removed': str2nr(removed),
            \ 'binary': added ==# '-'})
    endfor

    for path in s:fields(s:git(a:root, ['ls-files', '-z', '--others', '--exclude-standard']))
        call add(files, s:untracked(a:root, path))
    endfor
    return sort(files, {a, b -> a.path ==# b.path ? 0 : a.path ># b.path ? 1 : -1})
endfunction

" Binary as git judges it: a NUL in the first 8000 bytes.
function! s:untracked(root, path) abort
    let file = a:root . '/' . a:path
    let readable = filereadable(file)
    let binary = readable && index(readblob(file, 0, 8000), 0) >= 0
    return {'status': 'A', 'path': a:path, 'old': '', 'untracked': 1,
        \ 'added': readable && !binary ? len(readfile(file)) : 0, 'removed': 0,
        \ 'binary': binary}
endfunction


"=================================================
" The lines of `path` at `mb`, split as a buffer holds them: a final newline
" adds no empty last line.
function! tare#git#show(root, mb, path) abort
    let key = a:mb . ':' . a:path
    if !has_key(s:blobs, key)
        let lines = s:git(a:root, ['show', key])
        if empty(lines[-1])
            call remove(lines, -1)
        endif
        let s:blobs[key] = lines
    endif
    return copy(s:blobs[key])
endfunction

" Fills the blob cache for `paths` at `mb` from one `git cat-file --batch`,
" which reads one name per line: a path holding a newline is left to
" tare#git#show.
function! tare#git#prefetch(root, mb, paths) abort
    let keys = filter(map(copy(a:paths), 'a:mb . ":" . v:val'),
        \ '!has_key(s:blobs, v:val) && stridx(v:val, "\n") < 0')
    if empty(keys)
        return
    endif
    let out = s:git(a:root, ['cat-file', '--batch'], keys)
    let i = 0
    for key in keys
        " '<sha> blob <size>', then <size> bytes and a newline; or '<key> missing'.
        let size = matchstr(get(out, i, ''), '^\x\+ blob \zs\d\+$')
        let i += 1
        if empty(size)
            continue
        endif
        let [lines, left] = [[], str2nr(size) + 1]
        while left > 0 && i < len(out)
            call add(lines, out[i])
            let left -= strlen(out[i]) + 1
            let i += 1
        endwhile
        if left != 0
            return
        endif
        if empty(lines[-1])
            call remove(lines, -1)
        endif
        let s:blobs[key] = lines
    endfor
endfunction

" Local branches, remote branches and tags of `root` that start with `lead`,
" then `-` for the default. Symbolic refs such as origin/HEAD are left out.
function! tare#git#refs(root, lead) abort
    try
        let refs = s:git(a:root, ['for-each-ref',
            \ '--format=%(if)%(symref)%(then)%(else)%(refname:short)%(end)',
            \ 'refs/heads', 'refs/remotes', 'refs/tags'])
    catch /^tare: /
        return []
    endtry
    return filter(refs + ['-'], {_, ref -> !empty(ref) && stridx(ref, a:lead) == 0})
endfunction

" :TareBase completion, for the current buffer's repository.
function! tare#git#complete(lead, cmdline, cursorpos) abort
    try
        return tare#git#refs(tare#git#root(bufnr('%')), a:lead)
    catch /^tare: /
        return []
    endtry
endfunction

" vim: set et fdm=marker sts=4 sw=4:
