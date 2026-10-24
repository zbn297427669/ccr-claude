# ccr-claude for Linux / WSL (`start-claude.sh`)

[English](./README.md) | [简体中文](./README.zh-CN.md) | [All platforms](../README.md)

Launch [Claude Code](https://code.claude.com/) on Linux/WSL through a local [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router) gateway, using the same Agent profiles as CCR Desktop.

## Why

CCR Desktop writes profile tokens and model settings on the machine where it runs (often Windows). This script discovers that data at runtime so WSL/Linux can start `claude` without hardcoding secrets or usernames.

## Use cases

This project is for people who already run **CCR as a local gateway** and want **Claude Code CLI** to use those same agents from a Unix shell.

| Scenario | What you get |
| --- | --- |
| **Windows CCR + WSL Claude Code** | CCR Desktop runs on Windows (`localhost:3456`); you work in WSL projects and launch Claude Code with `ccr-claude` instead of hand-exporting env vars. |
| **Several CCR agents (multi-provider)** | e.g. one agent for a domestic provider, another for DeepSeek. The script lists **enabled** Claude Code agents and lets you pick by number, or pin one with `--profile`. |
| **Shareable launcher, private credentials** | The repo stays free of tokens and usernames. Each machine reads its own CCR `config.sqlite` / profile helpers at runtime. |
| **Any project directory** | Install once on `PATH`, then `cd` into a repo and run `ccr-claude` — the project root is your current working directory. |

### Requirements (runtime)

- CCR gateway is running and reachable (default `http://127.0.0.1:3456`)
- At least one **Claude Code** agent is enabled in CCR, with a valid client key and model
- Official `claude` CLI installed on the Linux/WSL side

### Not in scope

- Replacing CCR Desktop configuration or provider setup
- Talking to Anthropic (or other providers) **without** CCR
- Running the Windows-only `ccr-app "…"` launcher inside WSL (this script is the WSL/Linux counterpart)

## Install

```bash
cd wsl
chmod +x start-claude.sh
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/ccr-claude
```

### Calling it by another name

The command name is the link name; nothing in the script hardcodes it:

```bash
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/myclaude
myclaude --help          # the usage text calls itself myclaude
```

State does not follow the name: the last profile stays at
`${XDG_CONFIG_HOME:-~/.config}/ccr-claude/last-profile` and is shared by every
alias, so renaming keeps it.

Requires: `bash`, `python3`, `claude` on `PATH`, and a running CCR gateway.

## Usage

```bash
ccr-claude                 # pick among enabled agents if more than one
ccr-claude --list-profiles
ccr-claude --profile <id-or-name-substring>
ccr-claude --pick-model    # force the model menu
ccr-claude --model <name>
ccr-claude --context-window <tokens|off>
ccr-claude --skip-check    # skip gateway / token preflight
```

The model menu comes from the profile’s `availableModels`, which is also the gateway's allow-list, so anything it offers will route. It prints short names (the part after `/`, without `[1m]`) and passes the full CCR name to Claude Code. Each row also carries the model's context window (`1.0M`, `128K`, or the word `unknown` when nothing resolves), resolved once for the whole menu. That is the model's window, not necessarily where compaction fires: when `settings.json` pins a lower `autoCompactWindow` for it, the runtime takes the smaller of the two. The menu is skipped silently when the profile allows a single model, when stdin is not a terminal, when `-p`/`--print` is among the forwarded arguments, or when `CCR_NO_PICK=1` — a prompt inside a script is a hang. `--pick-model` overrides all four.

Before starting Claude Code, the script checks that the CCR gateway is reachable and that the selected profile’s client key can call `/v1/models`. The last chosen profile is remembered under `~/.config/ccr-claude/last-profile` and preferred next time.

The script also resolves the model’s real context window and passes it to Claude Code (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`), printing `Context window: <N> tokens` at startup. If nothing can be resolved it sets nothing rather than guessing. For why this is needed and what is missing between CCR and Claude Code, see [CONTEXT-WINDOW.md](../CONTEXT-WINDOW.md).

## Configuration (no secrets in the repo)

| Variable | Purpose |
| --- | --- |
| `CCR_DIR` | CCR data dir containing `config.sqlite` |
| `CCR_BASE_URL` | Gateway URL (else read from CCR config) |
| `CLAUDE_CONFIG_DIR` | Global Claude `settings.json` dir |
| `CCR_PROFILE` / `--profile` | Select agent (errors if the substring matches more than one) |
| `CCR_NO_PICK=1` | Skip both menus (profile and model); prefer last used, else newest |
| `CCR_SKIP_CHECK=1` | Skip gateway / token preflight |
| `CCR_CONTEXT_WINDOW` / `--context-window` | Override the resolved context window (token count); `off` sets nothing and leaves it to Claude Code |
| `CCR_CAPABILITY_CHECK` | `off` disables the pre-launch probe for `defer_loading` support |
| `MODEL` / `--model` | Temporary model override |

### Auto-discovery order for `CCR_DIR`

1. `$CCR_DIR` if set  
2. `$XDG_CONFIG_HOME/claude-code-router` or `~/.config/claude-code-router`  
3. `~/AppData/Roaming/claude-code-router`  
4. WSL: first `/mnt/c/Users/*/AppData/Roaming/claude-code-router` that has `config.sqlite`

### What is read at runtime (never committed)

| Field | Source |
| --- | --- |
| Profile list / enabled / model | `config.sqlite` → `app_config.default.profile.profiles` |
| Client API token | `api_keys` row `profile:<id>`, or `bin/ccr-claude-code-api-key-<id>.cmd` |
| Gateway URL | `routerEndpoint` / `gateway.host:port` |
| Global settings model | `$CLAUDE_CONFIG_DIR/settings.json` or derived `…/Users/<name>/.claude` |

Long CCR model ids like `Provider/model[1m]` are normalized to the upstream short name (`model`).

## Security notes

- Do **not** put `ccr-profile-…` tokens, provider API keys, or absolute home paths in this script.
- Tokens are exported only into the child `claude` process via `ANTHROPIC_AUTH_TOKEN`.
- Status lines print profile id and model, never the token.
- If a profile token returns 401, re-save/enable that agent in CCR Desktop (or restart the gateway); do not paste keys into git.

## License

[MIT](../LICENSE)
