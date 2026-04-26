" llm.vim — chat with a local mlx_lm server
" \a  ask about current file
" \s  ask about visual selection
" \r  replace visual selection with model response

let g:llm_url   = get(g:, 'llm_url',   'http://localhost:8080')
let g:llm_model = get(g:, 'llm_model', 'mlx-community/Qwen3.6-27B-4bit')
let g:llm_sys   = get(g:, 'llm_sys',   'Concise coding assistant. No explanations unless asked.')

" --- scratch buffer ---

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
import json, urllib.request, vim

def llm_call(context, question):
    url   = vim.eval('g:llm_url') + '/v1/chat/completions'
    model = vim.eval('g:llm_model')
    sys   = vim.eval('g:llm_sys')
    msgs  = [
        {'role': 'system',  'content': sys},
        {'role': 'user',    'content': f"{context}\n\n{question} /no_think"},
    ]
    body = json.dumps({'model': model, 'messages': msgs,
                       'max_tokens': 4096, 'stream': True}).encode()
    req  = urllib.request.Request(url, data=body,
                                  headers={'Content-Type': 'application/json'})
    buf  = vim.current.buffer
    buf[:] = ['']
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith('data: '):
                    continue
                data = line[6:]
                if data == '[DONE]':
                    break
                delta = json.loads(data)['choices'][0]['delta'].get('content', '')
                if not delta:
                    continue
                lines = buf[:]
                for ch in delta:
                    if ch == '\n':
                        lines.append('')
                    else:
                        lines[-1] += ch
                buf[:] = lines
                vim.command('redraw')
    except Exception as e:
        buf[:] = [f'[error: {e}]']
PYEOF

" --- commands ---

function! s:Ask(context)
    let q = input('Ask: ')
    if empty(q) | return | endif
    let prev = winnr()
    call s:ResponseBuf()
    call py3eval('llm_call(vim.eval("a:context"), vim.eval("a:q"))')
    execute prev . 'wincmd w'
endfunction

function! s:AskFile()
    let ctx = "File: " . expand('%') . "\n\n" . join(getline(1, '$'), "\n")
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

nnoremap <leader>a :call <SID>AskFile()<CR>
vnoremap <leader>s :call <SID>AskSel()<CR>
vnoremap <leader>r :call <SID>ReplaceSel()<CR>
