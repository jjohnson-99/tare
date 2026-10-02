"=================================================
" File: test/highlight.vim
" Description: Computed highlight groups follow g:tare_Style and the colorscheme.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD
"
" Sourced by test/run.lua with plugin/tare.vim already loaded. Failures are
" left in v:errors.

function! s:hl(name) abort
    return nvim_get_hl(0, {'name': a:name})
endfunction

" 30% of github's add (0x3FB950) into 0x101010, channel by channel.
let s:ADD_ON_101010 = 0x1E4223

set termguicolors
let g:tare_Style = 'background'
highlight Normal guibg=#101010
doautocmd ColorScheme
call assert_equal({'bg': s:ADD_ON_101010}, s:hl('TareAdd'), 'blended background')
call assert_equal({'fg': 0x3FB950}, s:hl('TareAddText'), 'status line text')
call assert_equal({'fg': 0xFF5555}, s:hl('TareDeleteText'), 'status line text')

" A transparent Normal degrades to the text style, or blends against the
" declared background.
highlight Normal guibg=NONE
doautocmd ColorScheme
call assert_equal({'fg': 0x3FB950}, s:hl('TareAdd'), 'no background to blend')
let g:tare_BackgroundColor = 0x101010
doautocmd ColorScheme
call assert_equal({'bg': s:ADD_ON_101010}, s:hl('TareAdd'), 'declared background')
let g:tare_BackgroundColor = -1

let g:tare_Style = 'text'
highlight Normal guibg=#101010
doautocmd ColorScheme
call assert_equal({'fg': 0xFF5555}, s:hl('TareDelete'), 'text style')
let g:tare_Style = 'background'

" :colorscheme clears every group, then the ColorScheme event re-sets them.
colorscheme default
call assert_true(has_key(s:hl('TareAdd'), 'bg'), 'TareAdd lost on :colorscheme')
call assert_equal({'link': 'TareAddText'}, s:hl('TareFloatAdd'), 'float link')

set notermguicolors
doautocmd ColorScheme
call assert_false(has_key(s:hl('TareAdd'), 'bg'), 'background without true colour')

" vim: set et fdm=marker sts=4 sw=4:
