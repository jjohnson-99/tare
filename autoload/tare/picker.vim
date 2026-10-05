"=================================================
" File: autoload/tare/picker.vim
" Description: The float that picks a base from the branch's commits, or from
"              every branch.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" At most one picker exists: like the file float (tare#popup) it closes on
" WinLeave, and its state is script-local. Text is measured in display cells,
" highlight marks in bytes.


" Avoid installing twice.
if exists('g:autoloaded_tare_picker')
    finish
endif
let g:autoloaded_tare_picker = 0

let s:ns = nvim_create_namespace('tare_picker')

" The open picker, {} when closed: {win, buf, origin, root, base, branch,
" commits, branches, mode, lines, done}. `base` is the current resolution, {}
" for none; `branches` is v:null until first shown; `lines` holds each mode's
" cursor line; `done` is v:null or called once a key has closed the picker.
let s:picker = {}

" Keys in the picker and what they call.
let s:KEYS = {'<CR>': 'use(0)', 'p': 'use(1)', '<Tab>': 'switch()', '/': 'ask()',
    \ '-': 'finish(0, "-")', 'q': 'finish()', '<Esc>': 'finish()'}

" The footer's hints, in order of importance: as many as fit are shown.
let s:HINTS = {
    \ 'commits': ['<CR> use', 'p pin', '<Tab> branches', '/ ref', '- default', 'q close'],
    \ 'branches': ['<CR> use', 'p pin', '<Tab> commits', '/ ref', '- default', 'q close'],
    \ }


"=================================================
function! s:error(msg) abort
    echohl ErrorMsg | echomsg a:msg | echohl None
endfunction

" Seconds before `now` as one unit: 45s 12m 3h 5d 2w 4mo 1y.
function! s:age(time, now) abort
    let secs = max([a:now - a:time, 0])
    for [unit, size] in [['y', 31536000], ['mo', 2592000], ['w', 604800], ['d', 86400],
            \ ['h', 3600], ['m', 60]]
        if secs >= size
            return (secs / size) . unit
        endif
    endfor
    return secs . 's'
endfunction

" `text` cut to `cells`, ending in … when cut.
function! s:clip(text, cells) abort
    if strdisplaywidth(a:text) <= a:cells
        return a:text
    elseif a:cells < 1
        return ''
    endif
    let text = strcharpart(a:text, 0, a:cells)
    while strdisplaywidth(text . '…') > a:cells
        let text = strcharpart(text, 0, strchars(text) - 1)
    endwhile
    return text . '…'
endfunction

" A commit's refs, the current base's ref moved first.
function! s:refs(commit) abort
    let refs = copy(a:commit.refs)
    let base = s:picker.base
    let i = empty(base) || base.pinned ? -1 : index(map(copy(refs), 'v:val.name'), base.ref)
    return i > 0 ? insert(refs, remove(refs, i)) : refs
endfunction

" The ref <CR> stores for a commit: its first, '' for none.
function! s:target(commit) abort
    return get(get(s:refs(a:commit), 0, {}), 'name', '')
endfunction


"=================================================
" Rows. Each is {text, marks}, a mark [start, end, group].

" ` ● <sha>  <age>  <subject> (<refs>) `: the current base's merge-base gets
" the ●. A long subject gives way to the refs down to half the room left.
function! s:commitRows(width) abort
    let p = s:picker
    let now = localtime()
    let ages = map(copy(p.commits), 's:age(v:val.time, now)')
    let wage = max(map(copy(ages), 'strlen(v:val)'))
    let rows = []
    for i in range(len(p.commits))
        let c = p.commits[i]
        let mark = !empty(p.base) && c.sha ==# p.base.mb ? '●' : ' '
        let head = ' ' . mark . ' ' . c.sha[:7] . '  ' . printf('%*s', wage, ages[i]) . '  '
        let names = map(s:refs(c), 'v:val.kind ==# "tag" ? "tag: " . v:val.name : v:val.name')
        if c.head
            call insert(names, empty(p.branch) ? 'HEAD' : 'HEAD -> ' . p.branch)
        endif
        let refs = empty(names) ? '' : ' (' . join(names, ', ') . ')'
        let room = a:width - 1 - strdisplaywidth(head)
        let subject = s:clip(c.subject, max([room - strdisplaywidth(refs), room / 2]))
        let refs = s:clip(refs, room - strdisplaywidth(subject))
        let at = strlen(head) - wage - 2
        let marks = [[1, 1 + strlen(mark), 'TarePickerCurrent'],
            \ [2 + strlen(mark), 10 + strlen(mark), 'TarePickerSha'], [at, at + wage, 'TarePickerAge'],
            \ [strlen(head . subject), strlen(head . subject . refs), 'TarePickerRef']]
        call add(rows, {'text': head . subject . refs, 'marks': marks})
    endfor
    return rows
endfunction

" ` ● <name>  <age>  <subject>`, names padded to the longest, up to half the
" width: the current base's ref gets the ●.
function! s:branchRows(width) abort
    let p = s:picker
    let now = localtime()
    let ages = map(copy(p.branches), 's:age(v:val.time, now)')
    let wage = max(map(copy(ages), 'strlen(v:val)'))
    let wname = min([max(map(copy(p.branches), 'strdisplaywidth(v:val.name)')), a:width / 2])
    let rows = []
    for i in range(len(p.branches))
        let b = p.branches[i]
        let mark = !empty(p.base) && !p.base.pinned && b.name ==# p.base.ref ? '●' : ' '
        let name = s:clip(b.name, wname)
        let head = ' ' . mark . ' ' . name . repeat(' ', wname - strdisplaywidth(name))
            \ . '  ' . printf('%*s', wage, ages[i]) . '  '
        let at = strlen(head) - wage - 2
        let marks = [[1, 1 + strlen(mark), 'TarePickerCurrent'],
            \ [2 + strlen(mark), 2 + strlen(mark) + strlen(name), 'TarePickerRef'],
            \ [at, at + wage, 'TarePickerAge']]
        let subject = s:clip(b.subject, a:width - 1 - strdisplaywidth(head))
        call add(rows, {'text': head . subject, 'marks': marks})
    endfor
    return rows
endfunction

" Fills the picker's buffer for its mode and sizes the picker to it.
function! s:draw() abort
    let p = s:picker
    let width = s:width()
    let rows = p.mode ==# 'commits' ? s:commitRows(width) : s:branchRows(width)
    let lines = empty(rows) ? [' no branches'] : map(copy(rows), 'v:val.text')
    call setbufvar(p.buf, '&modifiable', 1)
    call nvim_buf_set_lines(p.buf, 0, -1, v:true, lines)
    call setbufvar(p.buf, '&modifiable', 0)
    call nvim_buf_clear_namespace(p.buf, s:ns, 0, -1)
    for i in range(len(rows))
        for [start, end, group] in rows[i].marks
            if end > start
                call nvim_buf_set_extmark(p.buf, s:ns, i, start, {'end_col': end, 'hl_group': group})
            endif
        endfor
    endfor
    call nvim_win_set_config(p.win, s:config(width, len(lines)))
endfunction


"=================================================
" The window.

" Cells of text inside the border, as the file float's.
function! s:width() abort
    return max([min([float2nr(&columns * g:tare_FloatWidth), &columns - 2]), 20])
endfunction

" Centred in the editor, `height` capped at 0.6 of it. The title names the
" branch and the current base, the branch cut first; the footer holds the keys.
function! s:config(width, height) abort
    let p = s:picker
    let height = max([min([a:height, float2nr(&lines * 0.6)]), 1])
    let current = ' · current: ' . (empty(p.base) ? 'none' : tare#git#label(p.base)
        \ . (p.base.pinned ? '' : ' @ ' . p.base.mb[:7]))
    let branch = s:clip(empty(p.branch) ? 'HEAD' : p.branch,
        \ max([a:width - 2 - strdisplaywidth('tare base · ' . current), 1]))
    let title = ' ' . s:clip('tare base · ' . branch . current, a:width - 2) . ' '
    let hints = []
    for hint in s:HINTS[p.mode]
        if strdisplaywidth(join(hints + [hint], '  ')) > a:width - 2
            break
        endif
        call add(hints, hint)
    endfor
    return {'relative': 'editor', 'width': a:width, 'height': height,
        \ 'row': max([(&lines - height) / 2 - 1, 0]), 'col': max([(&columns - a:width) / 2 - 1, 0]),
        \ 'border': 'rounded', 'title': [[title, 'TareFloatTitle']], 'title_pos': 'center',
        \ 'footer': ' ' . join(hints, '  ') . ' ', 'footer_pos': 'center'}
endfunction

" A base that does not resolve is reported, and the picker opens to replace it.
function! s:show(root, done) abort
    let origin = win_getid()
    try
        let base = tare#git#resolve(a:root)
    catch /^tare: /
        call s:error(v:exception)
        let base = {}
    endtry
    let log = call('tare#git#log', [a:root] + (get(base, 'default') ? [base.mb] : []))
    let buf = nvim_create_buf(v:false, v:true)
    call setbufvar(buf, '&bufhidden', 'wipe')
    let row = empty(base) ? -1 : index(map(copy(log.commits), 'v:val.sha'), base.mb)
    let s:picker = {'buf': buf, 'origin': origin, 'root': a:root, 'base': base,
        \ 'branch': log.branch, 'commits': log.commits, 'branches': v:null, 'mode': 'commits',
        \ 'lines': {'commits': max([row, 0]) + 1, 'branches': 1}, 'done': a:done}
    let s:picker.win = nvim_open_win(buf, v:true,
        \ extend(s:config(s:width(), 1), {'style': 'minimal'}))
    for [opt, val] in [['cursorline', v:true], ['wrap', v:false], ['foldenable', v:false]]
        call nvim_set_option_value(opt, val, {'win': s:picker.win, 'scope': 'local'})
    endfor
    call s:draw()
    call cursor(s:picker.lines.commits, 1)
    for [lhs, call] in items(s:KEYS)
        exe 'nnoremap <buffer> <nowait> <silent> ' . lhs . ' <Cmd>call <SID>' . call . '<CR>'
    endfor
    augroup Tare
        exe 'au WinLeave <buffer=' . buf . '> call s:close()'
    augroup END
endfunction

" Clears the state first: closing the picker fires its WinLeave.
function! s:close() abort
    let win = get(s:picker, 'win', 0)
    let s:picker = {}
    if win > 0 && nvim_win_is_valid(win)
        call nvim_win_close(win, v:true)
    endif
endfunction


"=================================================
" Keys.

" Closes the picker by a key, back in the window it came from; with [pin, ref]
" sets the base as :TareBase[!] {ref} does. Then calls `done`.
function! s:finish(...) abort
    let p = s:picker
    call s:close()
    if nvim_win_is_valid(p.origin)
        call win_gotoid(p.origin)
    endif
    if a:0
        call tare#Base(a:1, a:2, p.root)
    endif
    if p.done isnot v:null
        call p.done()
    endif
endfunction

" A commit row: its first ref, or with none or `pin`, the commit itself, pinned.
" A branch row: the branch, or with `pin` its merge-base with HEAD, pinned.
function! s:use(pin) abort
    let p = s:picker
    let row = get(p.mode ==# 'commits' ? p.commits : p.branches, line('.') - 1, {})
    if empty(row)
        return
    elseif p.mode ==# 'branches'
        return s:finish(a:pin, row.name)
    endif
    let ref = a:pin ? '' : s:target(row)
    call s:finish(empty(ref), empty(ref) ? row.sha : ref)
endfunction

" The branch list is read when first shown; each mode keeps its cursor line.
function! s:switch() abort
    let p = s:picker
    if p.branches is v:null
        try
            let p.branches = tare#git#branches(p.root)
        catch /^tare: /
            return s:error(v:exception)
        endtry
        let ref = empty(p.base) || p.base.pinned ? '' : p.base.ref
        let p.lines.branches = index(map(copy(p.branches), 'v:val.name'), ref) + 1
    endif
    let p.lines[p.mode] = line('.')
    let p.mode = p.mode ==# 'commits' ? 'branches' : 'commits'
    call s:draw()
    call cursor(max([p.lines[p.mode], 1]), 1)
endfunction

" Asks for a ref, completing the picker's repository's; nothing typed keeps
" the picker open.
function! s:ask() abort
    let ref = input('tare base: ', '', 'customlist,tare#picker#complete')
    if !empty(ref)
        redraw
        call s:finish(0, ref)
    endif
endfunction


"=================================================
" Public.

" :TareBase with no argument. Lists the repository of the current window's
" buffer, as :Tare does; in the picker, closes it.
function! tare#picker#Toggle() abort
    if !empty(s:picker) && nvim_win_is_valid(s:picker.win)
        return s:close()
    endif
    try
        let root = tare#git#root(bufnr('%'))
    catch /^tare: /
        return s:error(v:exception)
    endtry
    call tare#picker#Open(root)
endfunction

" The picker for `root`, as :TareBase and `b` in the file float open it. [done]
" is called once a key has closed it, or when it cannot open; a picker already
" open is replaced.
function! tare#picker#Open(root, ...) abort
    let Done = get(a:000, 0, v:null)
    call s:close()
    try
        call s:show(a:root, Done)
    catch /^tare: /
        call s:close()
        call s:error(v:exception)
        if Done isnot v:null
            call Done()
        endif
    endtry
endfunction

" input() completion for `/`.
function! tare#picker#complete(lead, cmdline, cursorpos) abort
    return tare#git#refs(get(s:picker, 'root', getcwd()), a:lead)
endfunction

" vim: set et fdm=marker sts=4 sw=4:
