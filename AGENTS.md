# vim-llm

A minimal vim plugin for LLM-assisted editing. Single file, no dependencies beyond Python stdlib and vim's built-in `+python3`.

## Design principles

- **Hand-editable**: the whole plugin fits in one screen. If you can't read it end-to-end in 2 minutes, it's too complex.
- **No hidden state**: context is a visible vim buffer you can inspect and edit directly.
- **No dependencies**: pure Python stdlib + vim. No pip installs, no external tools.
- **Two backends only**: OpenAI-compatible endpoints (local or remote) and Anthropic's API. Detection is automatic via URL.

## Current keybindings

| Key | Mode | Action |
|-----|------|--------|
| `\a` | normal | Ask about current file |
| `\s` | visual | Ask about selection |
| `\r` | visual | Replace selection with model response |
| `\ac` | normal | Add current file to context buffer |
| `\sc` | visual | Add selection to context buffer |
| `\cc` | normal | Clear context buffer |
| `\ht` | normal | Toggle conversation history on/off |
| `\hc` | normal | Clear conversation history (and response buffer) |

## Buffers

- `__llm__` — response output (markdown, right split)
- `__llm_ctx__` — accumulated context (unlisted, inspect with `:b __llm_ctx__`)

## Configuration

```vim
let g:llm_url       = 'http://localhost:8080'          " any OpenAI-compatible endpoint
let g:llm_model     = 'mlx-community/gemma-4-e4b-it-4bit'
let g:llm_sys       = 'Concise coding assistant. No explanations unless asked.'
let g:llm_api_key   = ''                               " or set ANTHROPIC_API_KEY in env
let g:llm_history   = 1                                " 1 = on, 0 = off; toggle with \ht
let g:llm_ctx_files = ['CLAUDE.md', 'AGENTS.md', '.llm-context']
```

For Claude, set `g:llm_url = 'https://api.anthropic.com'` and `g:llm_model = 'claude-sonnet-4-6'`.

`g:llm_ctx_files` lists filenames auto-loaded from the current directory into the context buffer on first use per session.

## Local setup

`~/.vim` is a symlink to this repo. The plugin is auto-loaded by vim from `plugin/llm.vim`.

## Future direction

Context management and tool support should stay buffer-native:
- A `:LLMAdd` command to explicitly load files into the context buffer
- Tool calls rendered into a buffer, executed as vim commands, results fed back
- No framework — extend by editing the single source file
