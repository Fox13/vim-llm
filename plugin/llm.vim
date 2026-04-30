" llm.vim — chat with any OpenAI-compatible endpoint or Claude API
" \a   ask about current file
" \s   ask about visual selection  (visual mode)
" \r   replace visual selection    (visual mode)
" \ac  add current file to context
" \sc  add visual selection to context  (visual mode)
" \cc  clear context
" \ht  toggle conversation history on/off
" \hc  clear conversation history
"
" OpenAI-compatible (local or remote):
"   let g:llm_url     = 'http://localhost:8080'   (default)
"   let g:llm_model   = 'mlx-community/...'
"   let g:llm_api_key = ''                        (or set for remote)
"
" Claude:
"   let g:llm_url   = 'https://api.anthropic.com'
"   let g:llm_model = 'claude-sonnet-4-6'
"   set ANTHROPIC_API_KEY in environment (or let g:llm_api_key = '...')

if !has('python3')
    finish
endif
if !has('job')
    finish
endif

let g:llm_url       = get(g:, 'llm_url',       'http://localhost:8080')
let g:llm_model     = get(g:, 'llm_model',     'mlx-community/gemma-4-e4b-it-4bit')
let g:llm_sys       = get(g:, 'llm_sys',       'Concise coding assistant. No explanations unless asked.')
let g:llm_api_key   = get(g:, 'llm_api_key',   '')
let g:llm_ctx_files = get(g:, 'llm_ctx_files', ['CLAUDE.md', 'AGENTS.md', '.llm-context'])
let g:llm_history   = get(g:, 'llm_history',   1)

let s:ctx_loaded_dir      = ''
let s:llm_buf             = -1
let s:llm_mode            = 'ask'
let s:llm_replace         = {}
let s:history             = []
let s:pending_user_msg    = ''
let s:response_start_line = 1

" --- write Python helper to a temp file at load time ---

python3 << PYEOF
import tempfile, vim

_src = r"""
import json, os, sys, urllib.request

args      = json.loads(sys.argv[1])
url       = args['url']
model     = args['model']
sys_msg   = args['sys']
key       = args['key'] or os.environ.get('ANTHROPIC_API_KEY', '')
context   = args['context']
question  = args['question']
history   = args['history']
anthropic = 'anthropic.com' in url

content = '\n\n'.join(filter(None, [context, question]))

if anthropic:
    endpoint = url + '/v1/messages'
    body = json.dumps({
        'model': model, 'max_tokens': 4096, 'stream': True,
        'system': sys_msg,
        'messages': history + [{'role': 'user', 'content': content}],
    }).encode()
    headers = {
        'Content-Type': 'application/json',
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
    }
else:
    endpoint = url + '/v1/chat/completions'
    body = json.dumps({
        'model': model, 'max_tokens': 4096, 'stream': True,
        'messages': [{'role': 'system', 'content': sys_msg}] + history + [{'role': 'user', 'content': content + ' /no_think'}],
    }).encode()
    headers = {'Content-Type': 'application/json'}
    if key:
        headers['Authorization'] = 'Bearer ' + key

try:
    req = urllib.request.Request(endpoint, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith('data: '):
                continue
            d = line[6:]
            if d == '[DONE]':
                break
            if anthropic:
                ev = json.loads(d)
                if ev.get('type') != 'content_block_delta':
                    continue
                text = ev['delta'].get('text', '')
            else:
                text = json.loads(d)['choices'][0]['delta'].get('content', '')
            if text:
                sys.stdout.write(text)
                sys.stdout.flush()
except Exception as e:
    sys.stdout.write('\n[error: {}]'.format(e))
    sys.stdout.flush()
"""

_path = tempfile.mktemp(suffix='.py')
with open(_path, 'w') as f:
    f.write(_src.lstrip())
vim.vars['_llm_helper_py'] = _path
PYEOF

let s:helper_py = g:_llm_helper_py
unlet g:_llm_helper_py

" --- context buffer ---

function! s:CtxBuf()
    let bnr = bufnr('__llm_ctx__')
    if bnr == -1
        execute 'badd __llm_ctx__'
        let bnr = bufnr('__llm_ctx__')
        call setbufvar(bnr, '&buftype',   'nofile')
        call setbufvar(bnr, '&buflisted', 0)
        call setbufvar(bnr, '&swapfile',  0)
    endif
    return bnr
endfunction

function! s:CtxAdd(lines)
    let bnr = s:CtxBuf()
    let existing = getbufline(bnr, 1, '$')
    if existing == [''] | let existing = [] | endif
    call setbufline(bnr, 1, existing + a:lines + [''])
endfunction

function! s:CtxGet()
    let lines = getbufline(s:CtxBuf(), 1, '$')
    return lines == [''] ? '' : join(lines, "\n")
endfunction

function! s:AddFileToCTX()
    let header = ['### ' . expand('%'), '']
    call s:CtxAdd(header + getline(1, '$'))
    echo 'Added ' . expand('%') . ' to context'
endfunction

function! s:AddSelToCtx() range
    call s:CtxAdd(['### ' . expand('%') . ':' . a:firstline . '-' . a:lastline, '']
                \ + getline(a:firstline, a:lastline))
    echo 'Added selection to context'
endfunction

function! s:ClearCtx()
    call setbufline(s:CtxBuf(), 1, [''])
    let s:ctx_loaded_dir = ''
    echo 'Context cleared'
endfunction

function! s:AutoLoadCtx()
    let dir = getcwd()
    if s:ctx_loaded_dir ==# dir | return | endif
    let s:ctx_loaded_dir = dir
    for name in g:llm_ctx_files
        let path = dir . '/' . name
        if filereadable(path)
            call s:CtxAdd(['### ' . name, ''] + readfile(path) + [''])
            echo 'llm: loaded ' . name
        endif
    endfor
endfunction

" --- response buffer ---

function! s:ResponseBuf()
    let name = '__llm__'
    let bnr = bufnr(name)
    if bnr == -1
        rightbelow vnew
        execute 'file ' . name
    else
        let wnr = bufwinnr(bnr)
        if wnr == -1
            execute 'rightbelow vsplit ' . name
        else
            execute wnr . 'wincmd w'
        endif
    endif
    setlocal buftype=nofile bufhidden=hide noswapfile filetype=markdown
    if !(getline(1) ==# '' && line('$') == 1)
        call append('$', ['', '---', ''])
    endif
endfunction

" --- job callbacks ---

function! s:JobOut(ch, data)
    let bnr = s:llm_buf
    if bnr == -1 | return | endif
    let lines = getbufline(bnr, 1, '$')
    if lines == [''] | let lines = [''] | endif
    let parts = split(a:data, "\n", 1)
    let lines[-1] .= parts[0]
    for part in parts[1:]
        call add(lines, part)
    endfor
    call setbufline(bnr, 1, lines)
    redraw
endfunction

function! s:JobErr(ch, data)
    let bnr = s:llm_buf
    if bnr != -1
        let lines = getbufline(bnr, 1, '$')
        let lines[-1] .= '[err: ' . a:data . ']'
        call setbufline(bnr, 1, lines)
        redraw
    endif
endfunction

function! s:JobClose(ch)
    if s:llm_mode ==# 'replace' && !empty(s:llm_replace)
        let r = s:llm_replace
        let result = getbufline(s:llm_buf, s:response_start_line, '$')
        while len(result) > 1 && result[-1] ==# ''
            call remove(result, -1)
        endwhile
        let wnr = bufwinnr(r.buf)
        if wnr != -1
            execute wnr . 'wincmd w'
            execute r.first . ',' . r.last . 'delete _'
            call append(r.first - 1, result)
        endif
        let s:llm_replace = {}
        let s:llm_mode = 'ask'
        let s:pending_user_msg = ''
        return
    endif
    if g:llm_history && !empty(s:pending_user_msg) && s:llm_buf != -1
        let resp = join(getbufline(s:llm_buf, s:response_start_line, '$'), "\n")
        call add(s:history, {'role': 'user',      'content': s:pending_user_msg})
        call add(s:history, {'role': 'assistant', 'content': resp})
    endif
    let s:pending_user_msg = ''
endfunction

" --- start a request ---

function! s:StartJob(context, question)
    let ctx = join(filter([s:CtxGet(), a:context], 'v:val !=# ""'), "\n\n")
    let s:pending_user_msg = join(filter([ctx, a:question], 'v:val !=# ""'), "\n\n")
    let args = json_encode({
        \ 'url':      g:llm_url,
        \ 'model':    g:llm_model,
        \ 'sys':      g:llm_sys,
        \ 'key':      empty(g:llm_api_key) ? '' : g:llm_api_key,
        \ 'context':  ctx,
        \ 'question': a:question,
        \ 'history':  g:llm_history ? s:history : [],
    \})
    call job_start(['python3', s:helper_py, args], {
        \ 'out_cb':   function('s:JobOut'),
        \ 'err_cb':   function('s:JobErr'),
        \ 'close_cb': function('s:JobClose'),
        \ 'out_mode': 'raw',
        \ 'err_mode': 'raw',
    \})
endfunction

" --- commands ---

function! s:Ask(context)
    call s:AutoLoadCtx()
    let q = input('Ask: ')
    if empty(q) | return | endif
    let prev_win = winnr()
    let s:llm_mode = 'ask'
    call s:ResponseBuf()
    let s:llm_buf = bufnr('%')
    if getline(1) ==# '' && line('$') == 1
        call setline(1, '**' . q . '**')
        call append(1, '')
    else
        call append('$', ['**' . q . '**', ''])
    endif
    let s:response_start_line = line('$')
    call s:StartJob(a:context, q)
    execute prev_win . 'wincmd w'
endfunction

function! s:AskFile()
    let ctx = "### " . expand('%') . "\n\n" . join(getline(1, '$'), "\n")
    call s:Ask(ctx)
endfunction

function! s:AskSel() range
    let ctx = join(getline(a:firstline, a:lastline), "\n")
    call s:Ask(ctx)
endfunction

function! s:ReplaceSel() range
    let ctx = join(getline(a:firstline, a:lastline), "\n")
    let q = input('Replace with: ')
    if empty(q) | return | endif
    let s:llm_mode = 'replace'
    let s:llm_replace = {'buf': bufnr('%'), 'first': a:firstline, 'last': a:lastline}
    let prev_win = winnr()
    call s:ResponseBuf()
    let s:llm_buf = bufnr('%')
    let s:response_start_line = line('$')
    call s:StartJob(ctx, q)
    execute prev_win . 'wincmd w'
endfunction

function! s:ClearHistory()
    let s:history = []
    let s:pending_user_msg = ''
    let bnr = bufnr('__llm__')
    if bnr != -1
        call deletebufline(bnr, 2, '$')
        call setbufline(bnr, 1, '')
    endif
    echo 'History cleared'
endfunction

function! s:ToggleHistory()
    let g:llm_history = !g:llm_history
    echo 'History ' . (g:llm_history ? 'on' : 'off')
endfunction

nnoremap <leader>a  :call <SID>AskFile()<CR>
vnoremap <leader>s  :call <SID>AskSel()<CR>
vnoremap <leader>r  :call <SID>ReplaceSel()<CR>
nnoremap <leader>ac :call <SID>AddFileToCTX()<CR>
vnoremap <leader>sc :call <SID>AddSelToCtx()<CR>
nnoremap <leader>cc :call <SID>ClearCtx()<CR>
nnoremap <leader>ht :call <SID>ToggleHistory()<CR>
nnoremap <leader>hc :call <SID>ClearHistory()<CR>
