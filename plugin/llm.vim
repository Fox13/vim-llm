" llm.vim — chat with any OpenAI-compatible endpoint or Claude API
" \a   ask about current file
" \s   ask about visual selection  (visual mode)
" \r   replace visual selection    (visual mode)
" \ac  add current file to context
" \sc  add visual selection to context  (visual mode)
" \cc  clear context
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

let g:llm_url       = get(g:, 'llm_url',       'http://localhost:8080')
let g:llm_model     = get(g:, 'llm_model',     'mlx-community/Qwen3.6-27B-4bit')
let g:llm_sys       = get(g:, 'llm_sys',       'Concise coding assistant. No explanations unless asked.')
let g:llm_api_key   = get(g:, 'llm_api_key',   '')
let g:llm_ctx_files = get(g:, 'llm_ctx_files', ['CLAUDE.md', 'AGENTS.md', '.llm-context'])

let s:ctx_loaded_dir = ''

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
    silent %delete _
endfunction

" --- HTTP call via Python ---

python3 << PYEOF
import json, os, urllib.request, vim

def _is_anthropic(url):
    return 'anthropic.com' in url

def _stream_openai(resp, buf):
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith('data: '):
            continue
        data = line[6:]
        if data == '[DONE]':
            break
        delta = json.loads(data)['choices'][0]['delta'].get('content', '')
        _append(buf, delta)

def _stream_anthropic(resp, buf):
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith('data: '):
            continue
        ev = json.loads(line[6:])
        if ev.get('type') == 'content_block_delta':
            _append(buf, ev['delta'].get('text', ''))

def _append(buf, text):
    if not text:
        return
    lines = buf[:]
    for ch in text:
        if ch == '\n':
            lines.append('')
        else:
            lines[-1] += ch
    buf[:] = lines
    vim.command('redraw')

def llm_call(context, question):
    url     = vim.eval('g:llm_url')
    model   = vim.eval('g:llm_model')
    sys_msg = vim.eval('g:llm_sys')
    api_key = vim.eval('g:llm_api_key') or os.environ.get('ANTHROPIC_API_KEY', '')
    anthropic = _is_anthropic(url)

    ctx_buf = vim.eval('s:CtxGet()')
    full_context = '\n\n'.join(filter(None, [ctx_buf, context]))

    if anthropic:
        endpoint = url + '/v1/messages'
        body = json.dumps({
            'model': model, 'max_tokens': 4096, 'stream': True,
            'system': sys_msg,
            'messages': [{'role': 'user', 'content': f"{full_context}\n\n{question}"}],
        }).encode()
        headers = {
            'Content-Type': 'application/json',
            'x-api-key': api_key,
            'anthropic-version': '2023-06-01',
        }
    else:
        endpoint = url + '/v1/chat/completions'
        body = json.dumps({
            'model': model, 'max_tokens': 4096, 'stream': True,
            'messages': [
                {'role': 'system', 'content': sys_msg},
                {'role': 'user',   'content': f"{full_context}\n\n{question} /no_think"},
            ],
        }).encode()
        headers = {'Content-Type': 'application/json'}
        if api_key:
            headers['Authorization'] = f'Bearer {api_key}'

    buf = vim.current.buffer
    buf[:] = ['']
    try:
        req = urllib.request.Request(endpoint, data=body, headers=headers)
        with urllib.request.urlopen(req, timeout=120) as r:
            if anthropic:
                _stream_anthropic(r, buf)
            else:
                _stream_openai(r, buf)
    except Exception as e:
        buf[:] = [f'[error: {e}]']
PYEOF

" --- commands ---

function! s:Ask(context)
    call s:AutoLoadCtx()
    let q = input('Ask: ')
    if empty(q) | return | endif
    let prev = winnr()
    call s:ResponseBuf()
    call py3eval('llm_call(vim.eval("a:context"), vim.eval("a:q"))')
    execute prev . 'wincmd w'
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
    let prev_buf = bufnr('%')
    let prev_first = a:firstline
    let prev_last = a:lastline
    call s:ResponseBuf()
    call py3eval('llm_call(vim.eval("ctx"), vim.eval("q"))')
    let result = getline(1, '$')
    execute bufwinnr(prev_buf) . 'wincmd w'
    execute prev_first . ',' . prev_last . 'delete _'
    call append(prev_first - 1, result)
endfunction

nnoremap <leader>a  :call <SID>AskFile()<CR>
vnoremap <leader>s  :call <SID>AskSel()<CR>
vnoremap <leader>r  :call <SID>ReplaceSel()<CR>
nnoremap <leader>ac :call <SID>AddFileToCTX()<CR>
vnoremap <leader>sc :call <SID>AddSelToCtx()<CR>
nnoremap <leader>cc :call <SID>ClearCtx()<CR>
