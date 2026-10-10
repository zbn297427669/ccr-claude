# ccr-claude (`start-claude.sh`)

[English](./README.md) | [简体中文](./README.zh-CN.md)

Launch [Claude Code](https://code.claude.com/) on Linux/WSL through a local [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router) gateway, using the same Agent profiles as CCR Desktop.

## Why

CCR Desktop writes profile tokens and model settings on the machine where it runs (often Windows). This script discovers that data at runtime so WSL/Linux can start `claude` without hardcoding secrets or usernames.

## Install

```bash
chmod +x start-claude.sh
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/ccr-claude
```

Requires: `bash`, `python3`, `claude` on `PATH`, and a running CCR gateway.

## Usage

```bash
ccr-claude                 # pick among enabled agents if more than one
ccr-claude --list-profiles
ccr-claude --profile <id-or-name-substring>
ccr-claude --model <name>
```

## Configuration (no secrets in the repo)

| Variable | Purpose |
| --- | --- |
| `CCR_DIR` | CCR data dir containing `config.sqlite` |
| `CCR_BASE_URL` | Gateway URL (else read from CCR config) |
| `CLAUDE_CONFIG_DIR` | Global Claude `settings.json` dir |
| `CCR_PROFILE` / `--profile` | Select agent |
| `CCR_NO_PICK=1` | Skip interactive menu |
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

Use and modify freely for your own projects; no warranty.
