"=================================================
" File: autoload/tare.vim
" Description: Changes against a pinned base, shown in the buffer.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD


" Avoid installing twice.
if exists('g:autoloaded_tare')
    finish
endif
let g:autoloaded_tare = 0

let s:ns = nvim_create_namespace('tare')

" Put in front of a window's own status line. A local 'statusline' that starts
" with it is still tare's.
let s:SEGMENT = '%{%tare#statusline()%}'

" Neovim's built-in line (with 'ruler'), for an empty local and global value.
let s:DEFAULT_STL = '%<%f %h%w%m%r%=%-14.(%l,%c%V%) %P'

" Hunk keys and their direction, in every mode a motion is.
let s:KEYS = {']c': 1, '[c': -1}
let s:MODES = ['n', 'x', 'o']

" Set while a view renders: jobwait() and timers may call back into it.
let s:rendering = 0

" Each window's local 'statusline' from before tare first set it, by window id.
" Kept until the window closes: Neovim replays window options per buffer, so a
" window back on an enabled buffer already reports tare's value.
let s:saved = {}

" The window tare last took over while standing in it. A window opened from it
" by `:tab split` or a float inherits its 'statusline' with `winnr('#')` at 0.
let s:lastwin = 0


"=================================================
function! s:new(obj) abort
    let newobj = deepcopy(a:obj)
    call newobj.Init()
    return newobj
endfunction

" The view of a buffer, or {} when the view is off for it.
function! s:get(bufnr) abort
    return getbufvar(a:bufnr, 'tare', {})
endfunction

function! s:error(msg) abort
    echohl ErrorMsg | echomsg a:msg | echohl None
endfunction

" The buffer's file relative to `root`, which git gives with symlinks resolved.
function! s:relpath(bufnr, root) abort
    let name = bufname(a:bufnr)
    let file = resolve(fnamemodify(name, ':p'))
    if stridx(file, a:root . '/') != 0
        throw 'tare: ' . fnamemodify(name, ':~') . ' is outside ' . fnamemodify(a:root, ':~')
    endif
    return file[len(a:root) + 1 :]
endfunction

" Cells for text in the current window when it shows the buffer, else in the
" first that does; -1 for none. Extmarks are per buffer, so one width serves all.
function! s:width(bufnr) abort
    let wins = win_findbuf(a:bufnr)
    if empty(wins)
        return -1
    endif
    let info = getwininfo(index(wins, win_getid()) >= 0 ? win_getid() : wins[0])[0]
    return info.width - info.textoff
endfunction

" Re-reads the base side of every view in `root` after its base or files moved.
function! s:reload(root) abort
    let views = filter(map(getbufinfo(), 's:get(v:val.bufnr)'),
        \ '!empty(v:val) && v:val.root ==# a:root')
    if empty(views)
        return
    endif
    let changes = tare#git#changes(a:root, tare#git#cached(a:root).mb)
    for view in views
        try
            call view.Load(changes)
            call view.Render(1)
        catch /^tare: /
            call s:error(v:exception)
        endtry
    endfor
endfunction


"=================================================
" The op contract (DESIGN.md 4). Pure: lists of lines and cell counts in, op
" records and chunks out; widths are display cells, rows 0-based buffer rows.

" Tabs to spaces at `ts`-cell stops, as the buffer draws them, for text that
" starts [col] cells into its line.
function! s:expand(line, ts, ...) abort
    let col = get(a:000, 0, 0)
    let parts = split(a:line, "\t", 1)
    let out = parts[0]
    for part in parts[1:]
        let out .= repeat(' ', a:ts - (col + strdisplaywidth(out)) % a:ts) . part
    endfor
    return out
endfunction

" A removed line padded to `width`, so its background runs to the window edge.
" A wider line is left whole; the window cuts it off.
function! s:removed(line, width, ts) abort
    let text = s:expand(a:line, a:ts)
    return text . repeat(' ', a:width - strdisplaywidth(text))
endfunction

" What vim.diff compares. A NUL is NL inside a line and would split it.
function! s:text(lines) abort
    let lines = match(a:lines, "\n") < 0 ? a:lines
        \ : map(copy(a:lines), 'tr(v:val, "\n", "\x01")')
    return empty(lines) ? '' : join(lines, "\n") . "\n"
endfunction

" The ops turning `base` into `lines`, ordered by row, for a window with `width`
" cells of text; [tabstop] defaults to 8. One op carries all of a hunk's removed
" lines, above its replacement, or above the row after a pure deletion; `from`
" is the index in `base` of the first of them, -1 for an add.
function! tare#ops(base, lines, width, ...) abort
    let ts = get(a:000, 0, 8)
    let ops = []
    for [sa, ca, sb, cb] in luaeval('vim.diff(_A[1], _A[2],'
            \ . ' {result_type = "indices", algorithm = "histogram"})',
            \ [s:text(a:base), s:text(a:lines)])
        if ca > 0
            let op = {'row': cb > 0 ? sb - 1 : sb, 'kind': 'delete_above', 'count': 0,
                \ 'from': sa - 1,
                \ 'text': map(a:base[sa - 1 : sa + ca - 2], {_, l -> s:removed(l, a:width, ts)})}
            if op.row >= len(a:lines)
                let op.row = max([len(a:lines) - 1, 0])
                let op.kind = 'delete_below'
            endif
            call add(ops, op)
        endif
        if cb > 0
            call add(ops, {'row': sb - 1, 'kind': 'add', 'count': cb, 'from': -1, 'text': []})
        endif
    endfor
    return ops
endfunction

" A removed line as virt_lines chunks, cut at the byte columns of `spans`
" (tare#syntax#spans: [start, end, groups] in order) and joining to the text
" tare#ops gives it; [tabstop] defaults to 8. TareDelete comes after a span's
" groups, so its background wins, and in the 'text' style its colour too.
function! tare#chunks(line, spans, width, ...) abort
    let ts = get(a:000, 0, 8)
    let n = strlen(a:line)
    let [pieces, at] = [[], 0]
    for [start, end, groups] in a:spans
        let [start, end] = [min([start, n]), min([end, n])]
        if start > at
            call add(pieces, [a:line[at : start - 1], 'TareDelete'])
        endif
        if end > start
            call add(pieces, [a:line[start : end - 1], groups + ['TareDelete']])
            let at = end
        endif
    endfor
    call add(pieces, [a:line[at :], 'TareDelete'])
    let cells = 0
    for piece in pieces
        let piece[0] = s:expand(piece[0], ts, cells)
        let cells += strdisplaywidth(piece[0])
    endfor
    " Padding carries no syntax group, which could underline it.
    let pieces[-1][0] .= repeat(' ', a:width - cells)
    if empty(pieces[-1][0]) && len(pieces) > 1
        call remove(pieces, -1)
    endif
    return pieces
endfunction


"=================================================
" Window ownership of 'statusline'. The option is global-local, so every read
" and write here is scope 'local': a plain set would change the global value too.

function! s:localStl(winid) abort
    return nvim_get_option_value('statusline', {'win': a:winid, 'scope': 'local'})
endfunction

function! s:setLocalStl(winid, value) abort
    call nvim_set_option_value('statusline', a:value, {'win': a:winid, 'scope': 'local'})
endfunction

" A `%!` line is an expression for the whole option, so the segment goes inside
" the expression's result; the expression keeps its own window context.
function! s:compose(saved) abort
    let l:stl = !empty(a:saved) ? a:saved : &g:statusline
    if empty(l:stl)
        return s:SEGMENT . s:DEFAULT_STL
    elseif l:stl =~# '^%!'
        return "%!'" . s:SEGMENT . "' . (" . l:stl[2:] . ')'
    endif
    return s:SEGMENT . l:stl
endfunction

function! s:isOwned(stl) abort
    return stridx(a:stl, s:SEGMENT) == 0 || stridx(a:stl, "%!'" . s:SEGMENT) == 0
endfunction

" A window reporting tare's line, or what tare last handed back, keeps its
" record; anything else was set by someone since and is what to restore now.
function! s:ownWin(winid) abort
    if !nvim_win_is_valid(a:winid)
        return
    endif
    let now = s:localStl(a:winid)
    if !has_key(s:saved, a:winid) || (!s:isOwned(now) && now !=# s:saved[a:winid])
        let s:saved[a:winid] = now
    endif
    call s:setLocalStl(a:winid, s:compose(s:saved[a:winid]))
    if a:winid == win_getid()
        let s:lastwin = a:winid
    endif
endfunction

" Puts back only a line tare still holds, which also makes a second release free.
function! s:releaseWin(winid) abort
    if s:isOwned(s:localStl(a:winid))
        call s:setLocalStl(a:winid, s:saved[a:winid])
    endif
endfunction

" Release remembered windows not showing an enabled buffer; forget closed ones.
function! s:syncWins() abort
    for key in keys(s:saved)
        let winid = str2nr(key)
        if !nvim_win_is_valid(winid)
            call remove(s:saved, key)
        elseif empty(s:get(nvim_win_get_buf(winid)))
            call s:releaseWin(winid)
        endif
    endfor
endfunction


"=================================================
" One view per buffer, b:tare: what it shows follows the text, not the layout.

let s:view = {}

" Throws, leaving no view, for a buffer tare cannot show: outside a repository,
" with no base, binary, or with a base side git cannot show.
function! s:view.Init() abort
    let self.bufnr = bufnr('%')
    if (empty(bufname(self.bufnr)) || !empty(&buftype)) && !exists('b:tare_deleted')
        throw 'tare: this buffer is not a file'
    endif
    let self.root = tare#git#root(self.bufnr)
    " Per mode and key: the buffer-local map tare displaced ({} for none) and
    " tare's own.
    let self.maps = {}
    let self.timer = -1
    " What the ops were computed for: [changedtick, mb, width, tabstop,
    " filetype or '' with g:tare_SyntaxDeleted off].
    let self.key = []
    let self.ops = []
    let self.added = 0
    let self.removed = 0
    " Removed lines above the first row at the last render.
    let self.top = 0
    call self.Load(tare#git#changes(self.root, tare#git#resolve(self.root).mb))
endfunction

" Takes the base side from `changes` (tare#git#changes) and the repository's
" last resolution. All or nothing: a throw leaves the view as it was.
function! s:view.Load(changes) abort
    " A deleted file's base-side buffer (tare#popup) stays at the base it was
    " taken from.
    let deleted = getbufvar(self.bufnr, 'tare_deleted', {})
    if !empty(deleted)
        call extend(self, {'mb': deleted.mb, 'label': deleted.label, 'path': deleted.path,
            \ 'kind': 'deleted', 'key': [],
            \ 'base': tare#git#show(self.root, deleted.mb, deleted.path)})
        return
    endif
    let path = s:relpath(self.bufnr, self.root)
    let base = tare#git#cached(self.root)
    let entry = get(filter(copy(a:changes), 'v:val.path ==# path'), 0, {})
    if get(entry, 'binary', 0)
        throw 'tare: ' . path . ' is binary'
    endif
    let [kind, old, text] = ['modified', get(entry, 'old', path), []]
    if get(entry, 'status', '') ==# 'A'
        let [kind, old] = ['new', '']
    elseif !empty(entry)
        let text = tare#git#show(self.root, base.mb, old)
    else
        " Unchanged since the base, or untracked and ignored.
        try
            let text = tare#git#show(self.root, base.mb, path)
        catch /^tare: /
            let [kind, old] = ['new', '']
        endtry
    endif
    if match(text, "\n") >= 0
        throw 'tare: ' . path . ' is binary'
    endif
    " A buffer read as dos holds no CR; a base committed with CRLF does.
    if getbufvar(self.bufnr, '&fileformat') ==# 'dos'
        call map(text, 'substitute(v:val, "\r$", "", "")')
    endif
    call extend(self, {'mb': base.mb, 'label': tare#git#label(base), 'path': old,
        \ 'kind': kind, 'base': text, 'key': []})
endfunction

" The buffer's lines as git would split the file it writes, so a missing final
" newline is no change. One empty line is also how an empty file reads, and
" stands for whichever of the two the base has.
function! s:view.Lines() abort
    let lines = nvim_buf_get_lines(self.bufnr, 0, -1, v:true)
    if lines ==# ['']
        return self.base ==# [''] ? lines : []
    endif
    let eol = getbufvar(self.bufnr, '&endofline')
        \ || (!getbufvar(self.bufnr, '&binary') && getbufvar(self.bufnr, '&fixendofline'))
    if !eol && lines[-1] ==# ''
        call remove(lines, -1)
    endif
    return lines
endfunction

" Diffs and redraws, unless nothing the drawing depends on has changed; [force]
" redraws regardless. A buffer in no window is drawn when it is next shown.
function! s:view.Render(...) abort
    let width = s:width(self.bufnr)
    if s:rendering || width < 0 || !bufloaded(self.bufnr)
        return
    endif
    let force = get(a:000, 0, 0)
    let ts = getbufvar(self.bufnr, '&tabstop')
    let ft = g:tare_SyntaxDeleted ? getbufvar(self.bufnr, '&filetype') : ''
    let key = [nvim_buf_get_changedtick(self.bufnr), self.mb, width, ts, ft]
    if key ==# self.key && !force
        return
    endif
    let s:rendering = 1
    try
        let self.ops = tare#ops(self.base, self.Lines(), width, ts)
        let self.key = key
        let self.added = 0
        let self.removed = 0
        for op in self.ops
            let self.added += op.count
            let self.removed += len(op.text)
        endfor
        call nvim_buf_clear_namespace(self.bufnr, s:ns, 0, -1)
        if self.kind ==# 'modified'
            call self.Place(force, width, ts, ft)
        endif
    finally
        let s:rendering = 0
    endtry
endfunction

function! s:view.Place(force, width, ts, ft) abort
    let spans = v:null
    for op in self.ops
        if op.kind ==# 'add'
            let opts = {'end_row': op.row + op.count - 1, 'line_hl_group': 'TareAdd'}
        else
            if spans is v:null
                let spans = tare#syntax#spans(self.root, self.mb, self.path, a:ft)
            endif
            let lines = empty(spans) ? map(copy(op.text), '[[v:val, "TareDelete"]]')
                \ : map(range(op.from, op.from + len(op.text) - 1),
                \   {_, i -> tare#chunks(self.base[i], get(spans, i, []), a:width, a:ts)})
            let opts = {'virt_lines': lines, 'virt_lines_above': op.kind ==# 'delete_above'}
        endif
        call nvim_buf_set_extmark(self.bufnr, s:ns, op.row, 0, opts)
    endfor
    " Lines above the first row show only as filler a window has scrolled to
    " (topfill). A window at the top scrolls to them when they first appear.
    let first = get(self.ops, 0, {})
    let top = get(first, 'kind', '') ==# 'delete_above' && first.row == 0 ? len(first.text) : 0
    if top > 0 && (top != self.top || a:force)
        for winid in win_findbuf(self.bufnr)
            if getwininfo(winid)[0].topline == 1
                call win_execute(winid, 'call winrestview({"topfill": ' . top . '})')
            endif
        endfor
    endif
    let self.top = top
endfunction

" Restarts the wait after an edit, so a burst of typing renders once.
function! s:view.Schedule() abort
    call timer_stop(self.timer)
    let self.timer = timer_start(g:tare_Debounce, function('s:fire', [self.bufnr]))
endfunction

" A timer outlives nothing: a view gone or replaced since does not answer it.
function! s:fire(bufnr, timer) abort
    let view = s:get(a:bufnr)
    if empty(view) || view.timer != a:timer
        return
    endif
    let view.timer = -1
    call view.Render()
endfunction

" All enabled buffers share the Tare group, so only this buffer's autocmds are
" ever cleared. `:bdelete` keeps buffer-local autocmds, hence BufDelete.
function! s:view.BindAu() abort
    augroup Tare
        exe 'au! * <buffer=' . self.bufnr . '>'
        exe 'au BufDelete,BufWipeout <buffer=' . self.bufnr . '>'
            \ . ' call tare#OnBufDelete(str2nr(expand("<abuf>")))'
        exe 'au TextChanged,TextChangedI,TextChangedP <buffer=' . self.bufnr . '>'
            \ . ' call tare#OnTextChanged(str2nr(expand("<abuf>")))'
    augroup END
endfunction

" Called with the buffer current: maparg() and mapset() act on no other.
" Every mode's prior map is read before any is displaced, which would split it.
function! s:view.MapKeys() abort
    for [lhs, dir] in items(s:KEYS)
        let priors = map(copy(s:MODES), 'maparg(lhs, v:val, 0, 1)')
        for [mode, prior] in map(copy(s:MODES), '[v:val, priors[v:key]]')
            exe mode . 'noremap <buffer> <silent> <expr> ' . lhs . ' tare#Hunk(' . dir . ')'
            let self.maps[mode . lhs] = {
                \ 'prior': get(prior, 'buffer', 0) ? prior : {},
                \ 'ours': maparg(lhs, mode, 0, 1)}
        endfor
    endfor
endfunction

" A key remapped since enable belongs to whoever remapped it and is left alone.
" A prior map displaced in every mode it shares with tare's is restored whole,
" so one map over several modes comes back as one.
function! s:view.UnmapKeys() abort
    let priors = {}
    for [key, saved] in items(self.maps)
        let [mode, lhs] = [key[0], key[1:]]
        let freed = maparg(lhs, mode, 0, 1) ==# saved.ours
        if freed
            exe mode . 'unmap <buffer> ' . lhs
        endif
        if !empty(saved.prior)
            let id = string(saved.prior)
            let priors[id] = get(priors, id, {'map': saved.prior, 'kept': 0, 'freed': []})
            if freed
                call add(priors[id].freed, mode)
            else
                let priors[id].kept = 1
            endif
        endif
    endfor
    for prior in values(priors)
        if !prior.kept
            call mapset(prior.map)
        else
            for mode in prior.freed
                call mapset(mode, 0, prior.map)
            endfor
        endif
    endfor
endfunction

" Everything but the maps, which only the buffer's own Disable can reach.
function! s:detach(bufnr) abort
    let view = s:get(a:bufnr)
    if empty(view)
        return
    endif
    call timer_stop(view.timer)
    if bufloaded(a:bufnr)
        call nvim_buf_clear_namespace(a:bufnr, s:ns, 0, -1)
    endif
    augroup Tare
        exe 'au! * <buffer=' . a:bufnr . '>'
    augroup END
    call nvim_buf_del_var(a:bufnr, 'tare')
    " After the view is gone, so its windows no longer count as enabled.
    call s:syncWins()
endfunction


"=================================================
" User command functions.

function! tare#Enable() abort
    if !empty(s:get(bufnr('%')))
        return
    endif
    try
        let b:tare = s:new(s:view)
    catch /^tare: /
        return s:error(v:exception)
    endtry
    call b:tare.BindAu()
    call b:tare.MapKeys()
    for winid in win_findbuf(b:tare.bufnr)
        call s:ownWin(winid)
    endfor
    call b:tare.Render(1)
endfunction

function! tare#Disable() abort
    let view = s:get(bufnr('%'))
    if empty(view)
        return
    endif
    call view.UnmapKeys()
    call s:detach(view.bufnr)
endfunction

function! tare#Toggle() abort
    if empty(s:get(bufnr('%')))
        call tare#Enable()
    else
        call tare#Disable()
    endif
endfunction

" The tare segment of a status line, '' for a buffer with the view off. Public
" for a user who builds a status line of their own.
function! tare#statusline() abort
    let view = s:get(bufnr('%'))
    if empty(view)
        return ''
    endif
    let line = 'tare ↔ ' . substitute(view.label, '%', '%%', 'g') . '  '
    if view.kind !=# 'modified'
        let [group, n] = view.kind ==# 'new' ? ['TareNew', view.added]
            \ : ['TareDeleteText', len(view.base)]
        let line .= '%#' . group . '#' . view.kind . ' · ' . n
            \ . (n == 1 ? ' line' : ' lines') . '%*'
    elseif empty(view.ops)
        let line .= 'unchanged'
    else
        let line .= '%#TareAddText#+' . view.added . '%* %#TareDeleteText#-'
            \ . view.removed . '%*'
    endif
    return line . '  '
endfunction

" The keys ]c and [c type: to the first row of the [count]th hunk after or
" before the cursor, or the furthest one there is. Linewise after an operator,
" which no hunk to go to cancels.
function! tare#Hunk(dir) abort
    let view = s:get(bufnr('%'))
    if empty(view)
        return ''
    endif
    call view.Render()
    let here = line('.') - 1
    let rows = filter(uniq(map(copy(view.ops), 'v:val.row')),
        \ a:dir > 0 ? 'v:val > here' : 'v:val < here')
    let mode = mode(1)
    if empty(rows)
        return mode =~# '^no' ? "\<Esc>" : ''
    endif
    let lnum = 1 + (a:dir > 0 ? rows[min([v:count1, len(rows)]) - 1]
        \ : rows[max([len(rows) - v:count1, 0])])
    let move = printf("\<Cmd>call cursor(%d, %d)\<CR>", lnum,
        \ max([match(getline(lnum), '\S'), 0]) + 1)
    if mode ==# 'no'
        return 'V' . move
    endif
    return mode ==# 'n' ? "\<Cmd>normal! m'\<CR>" . move : move
endfunction

" :TareBase[!] [ref], for the current buffer's repository or [root]. With
" neither a ref nor a bang it only reports; `-` goes back to the defaults.
function! tare#Base(pin, ref, ...) abort
    try
        let root = a:0 ? a:1 : tare#git#root(bufnr('%'))
        if a:ref ==# '-'
            if a:pin
                throw "tare: there is no base to pin in '-'"
            endif
            let base = tare#git#reset(root)
        else
            let base = !a:pin && empty(a:ref) ? tare#git#resolve(root)
                \ : tare#git#set(root, a:ref, a:pin)
        endif
        call s:reload(root)
    catch /^tare: /
        return s:error(v:exception)
    endtry
    if base.pinned
        echo 'tare: base pinned at ' . base.mb[:7]
    else
        echo 'tare: base ' . base.ref . (base.default ? ' (default)' : '')
            \ . ', merge-base ' . base.mb[:7]
    endif
endfunction

" For the current buffer's repository or [root].
function! tare#Refresh(...) abort
    try
        let root = a:0 ? a:1 : tare#git#root(bufnr('%'))
        call tare#git#resolve(root)
        call s:reload(root)
    catch /^tare: /
        call s:error(v:exception)
    endtry
endfunction


"=================================================
" Autocmd handlers.

" Fires for every window entered: the window that has stopped showing an
" enabled buffer is the only place `:e other` can be caught.
function! tare#OnWinEnter() abort
    call s:syncWins()
    let view = s:get(bufnr('%'))
    if !empty(view)
        call s:ownWin(win_getid())
        call view.Render()
    endif
endfunction

" A new window inherits its source's 'statusline', so it inherits the source's
" record too; s:syncWins() keeps or releases it by what the window goes on to
" show. A window not holding tare's line inherited nothing and gets no record.
function! tare#OnWinNew() abort
    let winid = win_getid()
    if !s:isOwned(s:localStl(winid))
        return
    endif
    let source = winnr('#') ? win_getid(winnr('#')) : s:lastwin
    if has_key(s:saved, source)
        let s:saved[winid] = s:saved[source]
    endif
endfunction

" Removed lines are padded to the text width; a view whose width is unchanged
" does nothing.
function! tare#OnWinResized() abort
    for bufnr in uniq(sort(tabpagebuflist()))
        let view = s:get(bufnr)
        if !empty(view)
            call view.Render()
        endif
    endfor
endfunction

" A fetch may have moved a base ref while Neovim was in the background.
function! tare#OnFocusGained() abort
    for root in filter(tare#git#roots(), 'isdirectory(v:val)')
        try
            let mb = tare#git#cached(root).mb
            if tare#git#resolve(root).mb !=# mb
                call s:reload(root)
            endif
        catch /^tare: /
            call s:error(v:exception)
        endtry
    endfor
endfunction

function! tare#OnTextChanged(bufnr) abort
    let view = s:get(a:bufnr)
    if !empty(view)
        call view.Schedule()
    endif
endfunction

" Neovim drops the buffer's maps, variables and extmarks itself.
function! tare#OnBufDelete(bufnr) abort
    call s:detach(a:bufnr)
endfunction

" vim: set et fdm=marker sts=4 sw=4:
