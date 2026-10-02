"=================================================
" File: autoload/tare/popup.vim
" Description: The float listing every file changed against the base.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" At most one float exists: it closes on WinLeave, so it never outlives a move
" to another window or tab page, and its state is script-local.


" Avoid installing twice.
if exists('g:autoloaded_tare_popup')
    finish
endif
let g:autoloaded_tare_popup = 0

let s:ns = nvim_create_namespace('tare_popup')

" The open float: {win, buf, origin, root, base, entries}, {} when closed.
" `entries` holds the listing a row shows, one per buffer line.
let s:float = {}

" Keys in the float and what they call.
let s:KEYS = {'<CR>': 'open(1)', 'o': 'open(0)', 'b': 'base()', 'r': 'refresh()',
    \ 'q': 'close()', '<Esc>': 'close()'}


"=================================================
function! s:error(msg) abort
    echohl ErrorMsg | echomsg a:msg | echohl None
endfunction

" The buffer whose name is `name` once resolved, or -1. bufnr() would read
" `name` as a pattern.
function! s:findBuf(name) abort
    for info in getbufinfo()
        if info.name ==# a:name || resolve(fnamemodify(info.name, ':p')) ==# a:name
            return info.bufnr
        endif
    endfor
    return -1
endfunction

" The path of buffer `bufnr` in `root`, '' for none.
function! s:path(bufnr, root) abort
    let deleted = getbufvar(a:bufnr, 'tare_deleted', {})
    if !empty(deleted)
        return deleted.path
    endif
    let file = resolve(fnamemodify(bufname(a:bufnr), ':p'))
    return stridx(file, a:root . '/') == 0 ? file[len(a:root) + 1 :] : ''
endfunction


"=================================================
" The listing. Counts are the view's for the file as saved, not git's numstat:
" a changed final newline, or CRLF for LF, is no change.

" Whether `entry` is diffed against a base side: not added, deleted or binary.
function! s:recounted(entry) abort
    return !empty(a:entry.old) && a:entry.status !=# 'D' && !a:entry.binary
endfunction

" Splits the saved file as the view splits a buffer read from it; a file read
" as dos has no CRs on either side.
function! s:recount(root, mb, entry) abort
    let file = a:root . '/' . a:entry.path
    if !filereadable(file)
        return
    endif
    let base = tare#git#show(a:root, a:mb, a:entry.old)
    if match(base, "\n") >= 0
        let a:entry.binary = 1
        return
    endif
    let work = readfile(file, 'b')
    if !empty(work) && work[-1] ==# ''
        call remove(work, -1)
    endif
    if &fileformats =~# 'dos' && !empty(work) && match(work, '[^\r]$\|^$') < 0
        call map(work, 'v:val[:-2]')
        call map(base, 'substitute(v:val, "\r$", "", "")')
    endif
    let [a:entry.added, a:entry.removed] = [0, 0]
    for op in tare#ops(base, work, 0)
        let a:entry.added += op.count
        let a:entry.removed += len(op.text)
    endfor
endfunction

" The changes in `root` against `base`.
function! s:list(root, base) abort
    let entries = tare#git#changes(a:root, a:base.mb)
    let recounted = filter(copy(entries), 's:recounted(v:val)')
    call tare#git#prefetch(a:root, a:base.mb, map(copy(recounted), 'v:val.old'))
    for entry in recounted
        try
            call s:recount(a:root, a:base.mb, entry)
        catch /^tare: /
            " git's own counts, then.
        endtry
    endfor
    return entries
endfunction

" One row per entry, `width` display cells wide: ` M  path  +N  -M `, the
" counts flush right. Each is {text, marks}, a mark [start, end, group] in bytes.
function! s:rows(entries, width) abort
    let cells = []
    for e in a:entries
        let path = e.status =~# '[RC]' ? e.old . ' → ' . e.path : e.path
        call add(cells, {'status': e.status, 'path': path . (e.untracked ? '  (untracked)' : ''),
            \ 'added': e.added ? '+' . e.added : '', 'removed': e.removed ? '-' . e.removed : '',
            \ 'word': e.binary ? 'bin' : s:recounted(e) && !e.added && !e.removed ? 'unchanged' : ''})
    endfor
    let wa = max(map(copy(cells), 'strlen(v:val.added)'))
    let wr = max(map(copy(cells), 'strlen(v:val.removed)'))
    let wcounts = max([wa + 2 + wr] + map(copy(cells), 'strlen(v:val.word)'))
    let room = a:width - wcounts - 7
    let rows = []
    for cell in cells
        let path = cell.path
        while strdisplaywidth(path) > room && strchars(path) > 1
            let path = '…' . strcharpart(path, 2)
        endwhile
        let head = ' ' . cell.status . '  ' . path
        let head .= repeat(' ', a:width - 1 - wcounts - strdisplaywidth(head))
        " The counts are ASCII: from here on bytes and cells agree.
        let at = strlen(head)
        let marks = [[1, 2, 'TareFloatStatus']]
        if !empty(cell.word)
            let counts = printf('%*s', wcounts, cell.word)
        else
            let counts = printf('%*s  %*s', wcounts - wr - 2, cell.added, wr, cell.removed)
            let [a, r] = [at + wcounts - wr - 2, at + wcounts]
            call add(marks, [a - strlen(cell.added), a, 'TareFloatAdd'])
            call add(marks, [r - strlen(cell.removed), r, 'TareFloatDelete'])
        endif
        call add(rows, {'text': head . counts . ' ', 'marks': marks})
    endfor
    return rows
endfunction

" Fills the float's buffer and sizes the float to it.
function! s:draw() abort
    let f = s:float
    let width = s:width()
    let rows = s:rows(f.entries, width)
    let lines = empty(rows) ? [' no changes vs ' . tare#git#label(f.base)]
        \ : map(copy(rows), 'v:val.text')
    call setbufvar(f.buf, '&modifiable', 1)
    call nvim_buf_set_lines(f.buf, 0, -1, v:true, lines)
    call setbufvar(f.buf, '&modifiable', 0)
    call nvim_buf_clear_namespace(f.buf, s:ns, 0, -1)
    for i in range(len(rows))
        for [start, end, group] in rows[i].marks
            if end > start
                call nvim_buf_set_extmark(f.buf, s:ns, i, start, {'end_col': end, 'hl_group': group})
            endif
        endfor
    endfor
    call nvim_win_set_config(f.win, s:config(width, len(lines)))
endfunction


"=================================================
" The window.

" Cells of text inside the border.
function! s:width() abort
    return max([min([float2nr(&columns * g:tare_FloatWidth), &columns - 2]), 20])
endfunction

" Centred in the editor, `height` capped at 0.6 of it.
function! s:config(width, height) abort
    let height = max([min([a:height, float2nr(&lines * 0.6)]), 1])
    let label = tare#git#label(s:float.base)
    let title = ' tare ↔ ' . label . (s:float.base.pinned ? '' : ' @ ' . s:float.base.mb[:7]) . ' '
    return {'relative': 'editor', 'width': a:width, 'height': height,
        \ 'row': max([(&lines - height) / 2 - 1, 0]), 'col': max([(&columns - a:width) / 2 - 1, 0]),
        \ 'border': 'rounded', 'title': [[title, 'TareFloatTitle']], 'title_pos': 'center'}
endfunction

function! s:show(root) abort
    let origin = win_getid()
    let base = tare#git#resolve(a:root)
    let entries = s:list(a:root, base)
    let buf = nvim_create_buf(v:false, v:true)
    call setbufvar(buf, '&bufhidden', 'wipe')
    let s:float = {'buf': buf, 'origin': origin, 'root': a:root, 'base': base,
        \ 'entries': entries}
    let s:float.win = nvim_open_win(buf, v:true,
        \ extend(s:config(s:width(), 1), {'style': 'minimal'}))
    for [opt, val] in [['cursorline', v:true], ['wrap', v:false], ['foldenable', v:false]]
        call nvim_set_option_value(opt, val, {'win': s:float.win, 'scope': 'local'})
    endfor
    call s:draw()
    let here = s:path(winbufnr(origin), a:root)
    let row = index(map(copy(entries), 'v:val.path'), here)
    call cursor(max([row, 0]) + 1, 1)
    for [lhs, call] in items(s:KEYS)
        exe 'nnoremap <buffer> <nowait> <silent> ' . lhs . ' <Cmd>call <SID>' . call . '<CR>'
    endfor
    augroup Tare
        exe 'au WinLeave <buffer=' . buf . '> call s:close()'
    augroup END
endfunction

" Clears the state first: closing the float fires its WinLeave.
function! s:close() abort
    let win = get(s:float, 'win', 0)
    let s:float = {}
    if win > 0 && nvim_win_is_valid(win)
        call nvim_win_close(win, v:true)
    endif
endfunction


"=================================================
" Keys.

" Opens the file on the cursor row in the window the float came from, with the
" view when `view` and g:tare_ViewOnOpen. A file already loaded keeps its buffer.
function! s:open(view) abort
    let f = s:float
    let entry = get(f.entries, line('.') - 1, {})
    if empty(entry)
        return
    endif
    call s:close()
    if nvim_win_is_valid(f.origin)
        call win_gotoid(f.origin)
    endif
    try
        if entry.status ==# 'D'
            call s:showDeleted(f.root, f.base, entry)
        else
            let file = f.root . '/' . entry.path
            let buf = s:findBuf(resolve(file))
            exe buf > 0 ? 'buffer ' . buf : 'edit ' . fnameescape(file)
        endif
    catch /^tare: \|^Vim\%((\a\+)\)\=:E/
        return s:error(substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', ''))
    endtry
    if a:view && g:tare_ViewOnOpen && !entry.binary
        call tare#Enable()
    endif
endfunction

" A deleted file in the current window: a read-only scratch buffer of its base
" side, named tare://<mb>/<path> and wiped once no window shows it.
function! s:showDeleted(root, base, entry) abort
    if a:entry.binary
        throw 'tare: ' . a:entry.path . ' is binary'
    endif
    let name = 'tare://' . a:base.mb . '/' . a:entry.path
    let buf = s:findBuf(name)
    if buf > 0
        exe 'buffer ' . buf
        return
    endif
    let text = tare#git#show(a:root, a:base.mb, a:entry.path)
    if match(text, "\n") >= 0
        throw 'tare: ' . a:entry.path . ' is binary'
    endif
    let buf = nvim_create_buf(v:true, v:true)
    try
        call nvim_buf_set_name(buf, name)
        call nvim_buf_set_lines(buf, 0, -1, v:true, text)
        for [opt, val] in [['bufhidden', 'wipe'], ['modified', 0], ['modifiable', 0]]
            call setbufvar(buf, '&' . opt, val)
        endfor
        call setbufvar(buf, 'tare_deleted', {'root': a:root, 'mb': a:base.mb,
            \ 'label': tare#git#label(a:base), 'path': a:entry.path})
        exe 'buffer ' . buf
    catch
        " Never shown, so never hidden: 'bufhidden' would not wipe it.
        exe 'bwipeout! ' . buf
        throw 'tare: ' . substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '')
    endtry
    " Set with the buffer in its window, where a filetype plugin expects it.
    let ft = luaeval('(function(a) local ft, on_detect = vim.filetype.match(a)'
        \ . ' if ft and on_detect then on_detect(a.buf) end return ft or "" end)(_A)',
        \ {'buf': buf, 'filename': a:root . '/' . a:entry.path})
    if !empty(ft)
        let &l:filetype = ft
    endif
endfunction

" Asks for a new base, completing refs of the float's repository.
function! s:base() abort
    let root = s:float.root
    let ref = input('tare base: ', '', 'customlist,tare#popup#complete')
    if empty(ref)
        return
    endif
    redraw
    call tare#Base(0, ref, root)
    call s:relist()
endfunction

function! s:refresh() abort
    call tare#Refresh(s:float.root)
    call s:relist()
endfunction

" Lists again against the repository's latest base; the cursor stays on its file.
function! s:relist() abort
    let f = s:float
    let path = get(get(f.entries, line('.') - 1, {}), 'path', '')
    let base = tare#git#cached(f.root)
    try
        let f.entries = s:list(f.root, base)
    catch /^tare: /
        return s:error(v:exception)
    endtry
    let f.base = base
    call s:draw()
    let row = index(map(copy(f.entries), 'v:val.path'), path)
    call cursor(row >= 0 ? row + 1 : min([line('.'), line('$')]), 1)
endfunction


"=================================================
" Public.

" :Tare. Lists the repository of the current window's buffer; for a buffer
" with no file, of the current directory.
function! tare#popup#Toggle() abort
    if !empty(s:float) && nvim_win_is_valid(s:float.win)
        return s:close()
    endif
    try
        call s:show(tare#git#root(bufnr('%')))
    catch /^tare: /
        call s:close()
        call s:error(v:exception)
    endtry
endfunction

" input() completion for `b`.
function! tare#popup#complete(lead, cmdline, cursorpos) abort
    return tare#git#refs(get(s:float, 'root', getcwd()), a:lead)
endfunction

" vim: set et fdm=marker sts=4 sw=4:
