" Russian keyboard mappings
set langmap=ё№йцукенгшщзхъфывапролджэячсмитьбюЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ;`#qwertyuiop[]asdfghjkl\\;'zxcvbnm\\,.~QWERTYUIOP{}ASDFGHJKL:\\"ZXCVBNM<>

nmap Ж :
" yank
nmap Н Y
nmap з p
nmap ф a
nmap щ o
nmap г u
nmap З P

" Copy to system clipboard
vmap <C-c> "+y

" Move in Insert mode
"" Not using left, up, and down motions because <C-h> in NeoVim is treated as
"" terminal shortcut and deletes one character to the left. Up and down motions
"" can be used, but really only right motion is needed to escape from paired
"" objects ("(", "[", etc.)
" inoremap <C-h> <Left>
" inoremap <C-j> <C-o>gj
" inoremap <C-k> <C-o>gk
inoremap <C-l> <Right>

" Move between buffers
if exists('g:vscode')
  " Simulate same TAB behavior in VSCode
  nmap <Tab> :Tabnext<CR>
  nmap <S-Tab> :Tabprev<CR>
else
  " TAB in general mode will move to text buffer
  nnoremap <silent> <TAB> :bnext<CR>
  " SHIFT-TAB will go back
  nnoremap <silent> <S-TAB> :bprevious<CR>
endif

" Move selected line / block of text in visual mode
" shift + k to move up
" shift + j to move down
xnoremap K :move '<-2<CR>gv-gv
xnoremap J :move '>+1<CR>gv-gv

" Better window navigation
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" Use alt + hjkl to resize windows
nnoremap <silent> <M-j>    :resize -2<CR>
nnoremap <silent> <M-k>    :resize +2<CR>
nnoremap <silent> <M-h>    :vertical resize -2<CR>
nnoremap <silent> <M-l>    :vertical resize +2<CR>

" Alternate way to save
nnoremap <C-s> :w<CR>
inoremap <C-s> <C-o>:w<CR>

" Go into completion list with <TAB>
inoremap <silent> <expr><TAB> pumvisible() ? "\<C-n>" : "\<TAB>"

