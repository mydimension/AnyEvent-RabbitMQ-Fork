let s:path = fnamemodify(resolve(expand('<sfile>:p')), ':h')

" tell perlcritic to use our custom profile
let $PERLCRITIC = s:path . '/.perlcriticrc'

let g:syntastic_perl_lib_path = [ s:path . '/lib' ]
