"=================================================
" File: plugin/tare.vim
" Description: Changes against a pinned base, shown in the buffer.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD

" Avoid installing twice.
if exists('g:loaded_tare')
    finish
endif
let g:loaded_tare = 1


"=================================================
" refs tried in order for a repository with no base set; the first that exists wins
if !exists('g:tare_DefaultBases')
    let g:tare_DefaultBases = ['upstream/main', 'origin/main', 'main', 'master']
endif

" 'background' tints a changed row's background (see g:tare_BackgroundColor);
" 'text' colours its text instead
if !exists('g:tare_Style')
    let g:tare_Style = 'background'
endif

if !exists('g:tare_Palette')
    let g:tare_Palette = 'github'
endif

" Individual overrides. -1 means "take it from the palette".
if !exists('g:tare_AddColor')
    let g:tare_AddColor = -1
endif

if !exists('g:tare_DeleteColor')
    let g:tare_DeleteColor = -1
endif

" percent of the hue mixed into the background for a changed row
if !exists('g:tare_Blend')
    let g:tare_Blend = 30
endif

" push the hues toward full saturation, 0 for the colour as given
if !exists('g:tare_Vibrance')
    let g:tare_Vibrance = 0
endif

" the terminal's background (e.g. 0x191724) to blend against when `Normal` is
" transparent; without it a transparent window gets the 'text' style
if !exists('g:tare_BackgroundColor')
    let g:tare_BackgroundColor = -1
endif

" milliseconds after an edit before the buffer is diffed again
if !exists('g:tare_Debounce')
    let g:tare_Debounce = 150
endif

" turn the view on for a file opened from the float
if !exists('g:tare_ViewOnOpen')
    let g:tare_ViewOnOpen = 1
endif

" float width as a fraction of 'columns'
if !exists('g:tare_FloatWidth')
    let g:tare_FloatWidth = 0.6
endif

" colour removed lines with their syntax, parsed from the base side by treesitter
if !exists('g:tare_SyntaxDeleted')
    let g:tare_SyntaxDeleted = 1
endif

" Named palettes for g:tare_Palette, as in mdview.
let s:PALETTES = {
    \ 'github':    {'add': 0x3FB950, 'delete': 0xFF5555},
    \ 'rose-pine': {'add': 0x9CCFD8, 'delete': 0xEB6F92},
    \ 'vivid':     {'add': 0x00CC44, 'delete': 0xFF3333},
    \ 'muted':     {'add': 0x7FA87F, 'delete': 0xBE8080},
    \ }


"=================================================
" Colour arithmetic on 24-bit 0xRRGGBB integers, as nvim_get_hl returns them.

" `pct` percent of `over` mixed into `under`.
function! s:blend(under, over, pct) abort
    let l:r = (and(a:under, 0xFF0000) / 0x10000 * (100 - a:pct)
            \  + and(a:over, 0xFF0000) / 0x10000 * a:pct) / 100
    let l:g = (and(a:under, 0x00FF00) / 0x100 * (100 - a:pct)
            \  + and(a:over, 0x00FF00) / 0x100 * a:pct) / 100
    let l:b = (and(a:under, 0x0000FF) * (100 - a:pct)
            \  + and(a:over, 0x0000FF) * a:pct) / 100
    return l:r * 0x10000 + l:g * 0x100 + l:b
endfunction

" Push a colour toward full saturation with its brightest channel fixed, so hue
" and brightness survive; at 100 each channel's gap from the brightest doubles.
function! s:saturate(rgb, pct) abort
    if a:pct <= 0
        return a:rgb
    endif
    let l:r = and(a:rgb, 0xFF0000) / 0x10000
    let l:g = and(a:rgb, 0x00FF00) / 0x100
    let l:b = and(a:rgb, 0x0000FF)
    let l:max = max([l:r, l:g, l:b])
    let l:out = []
    for l:c in [l:r, l:g, l:b]
        call add(l:out, max([0, l:max - (l:max - l:c) * (100 + a:pct) / 100]))
    endfor
    return l:out[0] * 0x10000 + l:out[1] * 0x100 + l:out[2]
endfunction

" The colour to tint against, or -1 for none (no true colour, or a transparent
" `Normal` with no declared substitute). A background is never invented.
function! s:baseBg() abort
    if !has('gui_running') && !&termguicolors
        return -1
    endif
    if g:tare_BackgroundColor >= 0
        return g:tare_BackgroundColor
    endif
    return get(nvim_get_hl(0, {'name': 'Normal', 'link': v:false}), 'bg', -1)
endfunction

" An unknown palette name falls back to 'github'.
function! s:hue(role, override) abort
    let l:raw = a:override >= 0 ? a:override
        \ : get(s:PALETTES, g:tare_Palette, s:PALETTES['github'])[a:role]
    return s:saturate(l:raw, g:tare_Vibrance)
endfunction

function! s:rowHighlight(name, hue) abort
    let l:bg = s:baseBg()
    if g:tare_Style ==# 'background' && l:bg >= 0
        call nvim_set_hl(0, a:name, {'bg': s:blend(l:bg, a:hue, g:tare_Blend)})
    else
        call nvim_set_hl(0, a:name, {'fg': a:hue})
    endif
endfunction


"=================================================
" Computed groups are set outright, never `default`: a `default` definition is
" refused once the group exists and would freeze the first colorscheme's colour.
" Links are `default` so a user's own link wins.
function! s:highlights() abort
    let l:add = s:hue('add', g:tare_AddColor)
    let l:delete = s:hue('delete', g:tare_DeleteColor)
    call s:rowHighlight('TareAdd', l:add)
    call s:rowHighlight('TareDelete', l:delete)
    call nvim_set_hl(0, 'TareAddText', {'fg': l:add})
    call nvim_set_hl(0, 'TareDeleteText', {'fg': l:delete})
    call nvim_set_hl(0, 'TareNew', {'fg': l:add})

    highlight default link TareFloatAdd    TareAddText
    highlight default link TareFloatDelete TareDeleteText
    highlight default link TareFloatStatus Identifier
    highlight default link TareFloatTitle  FloatTitle
endfunction

call s:highlights()


"=================================================
" Window ownership, base refresh and resizing (autoload/tare.vim) need no
" handling before that file loads.
function! s:onWinEnter() abort
    if exists('g:autoloaded_tare')
        call tare#OnWinEnter()
    endif
endfunction

function! s:onWinNew() abort
    if exists('g:autoloaded_tare')
        call tare#OnWinNew()
    endif
endfunction

function! s:onFocusGained() abort
    if exists('g:autoloaded_tare')
        call tare#OnFocusGained()
    endif
endfunction

function! s:onWinResized() abort
    if exists('g:autoloaded_tare')
        call tare#OnWinResized()
    endif
endfunction

" Never cleared by :TareDisable, which clears only its buffer's part of `Tare`.
augroup TarePermanent
    au!
    au ColorScheme * call s:highlights()
    au WinNew      * call s:onWinNew()
    au BufWinEnter,WinEnter * call s:onWinEnter()
    au FocusGained * call s:onFocusGained()
    au WinResized  * call s:onWinResized()
augroup END

" Declared empty so `:autocmd Tare` names a group from startup; enabled buffers
" add their own autocmds to it.
augroup Tare
augroup END


"=================================================
" User commands.
command! -nargs=0 -bar Tare        :call tare#popup#Toggle()
command! -nargs=0 -bar TareToggle  :call tare#Toggle()
command! -nargs=0 -bar TareEnable  :call tare#Enable()
command! -nargs=0 -bar TareDisable :call tare#Disable()
command! -nargs=? -bar -bang -complete=customlist,tare#git#complete
    \ TareBase :call tare#Base(<bang>0, <q-args>)
command! -nargs=0 -bar TareRefresh :call tare#Refresh()

" vim: set et fdm=marker sts=4 sw=4:
