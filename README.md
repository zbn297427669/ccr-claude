# ccr-claude

[English](./README.md) | [简体中文](./README.zh-CN.md)

Launch [Claude Code](https://code.claude.com/) through a local [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router) gateway, reusing the Agent profiles you already configured in CCR Desktop.

Two launchers, one behaviour:

| Platform | Entry point | Docs |
| --- | --- | --- |
| Windows | `windows/ccr-claude.ps1` (plus `ccr-claude.cmd` shell) | [windows/README.md](./windows/README.md) |
| Linux / WSL | `wsl/start-claude.sh` | [wsl/README.md](./wsl/README.md) |

Both discover the CCR data directory, the gateway URL, the profile's client key, and the model's real context window at runtime. **Nothing secret or machine-specific lives in this repo**: no tokens, no absolute home paths.

## Why two launchers

The two platforms fail differently, so the fixes differ:

- **Linux / WSL** — `claude` is already on `PATH`; the launcher just needs to find Windows' CCR database across `/mnt/c`. Settings are written by the script itself.
- **Windows** — CCR Desktop generates `settings.json` *and* a wrapper `.cmd` that hardcode `ANTHROPIC_API_KEY`-adjacent settings, and a `settings.json` `env` block outranks process environment variables. The PowerShell launcher therefore writes a `--settings` overlay to push its values back on top, and skips the generated wrapper entirely.

Everything else — which profile, which model, which context window — is the same logic in both. See [CONTEXT-WINDOW.md](./CONTEXT-WINDOW.md) for the long version of what CCR does not tell Claude Code, and how the launchers fill the gap.

## Layout

```
.
├── README.md            this file
├── README.zh-CN.md
├── CONTEXT-WINDOW.md    why the context window has to be passed by hand
├── CHANGELOG.md         what changed, per version
├── RELEASING.md         how a version is cut and what the archives must contain
├── LICENSE              MIT
├── .github/workflows/
│   └── check.yml        syntax checks for the embedded code in both launchers
├── tools/
│   └── check.py         the same checks, runnable locally
├── windows/
│   ├── ccr-claude.ps1   real entry point
│   ├── ccr-claude.cmd   thin shell for double-click / cmd
│   ├── README.md
│   └── README.zh-CN.md
└── wsl/
    ├── start-claude.sh  real entry point
    ├── README.md
    └── README.zh-CN.md
```

Before changing either launcher, run the checks — they parse the Python embedded
in both scripts, which no interpreter otherwise reads from disk:

```bash
python3 -I tools/check.py --verbose
```

## Quick start

**Windows** (PowerShell):

```powershell
$repo = 'C:\path\to\ccr-claude'
[Environment]::SetEnvironmentVariable(
  'Path', "$repo\windows;" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')
# Wherever claude.exe already lives -- it need not sit next to the script:
[Environment]::SetEnvironmentVariable(
  'CCR_CLAUDE_EXE', 'C:\path\to\claude', 'User')
```

```bat
ccr-claude                      :: profile menu when several are enabled
ccr-claude --pick-model         :: then the model menu
ccr-claude -p "explain this repo"
```

**Linux / WSL**:

```bash
cd wsl
chmod +x start-claude.sh
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/ccr-claude

ccr-claude --list-profiles
```

## Shared concepts

| Concept | Behaviour on both platforms |
| --- | --- |
| Profile selection | Only **enabled** Claude Code agents with a model *and* a client key are offered. The last choice is remembered and listed first. |
| Model selection | The menu comes from the profile's `availableModels` — the same list CCR's gateway enforces, so every entry routes. Short names are shown, the full CCR name is passed on. |
| Silent by default | No prompt when only one choice exists, when stdin is not a terminal, when `-p`/`--print` is being forwarded, or when `CCR_NO_PICK=1`. `--pick` / `--pick-model` force it. |
| Context window | Resolved from the provider's `/v1/models` (loopback only), then CCR's `modelMetadata`, then the per-machine catalog. If none of them answer, nothing is set — guessing moves the compaction point silently. |
| Diagnostics | Startup lines (profile, model, gateway, window) go to **stderr**; only Claude's answer goes to **stdout**, so `2>/dev/null` is safe. |

## Security notes

- No tokens, provider keys, or absolute home paths are committed. Every machine reads its own CCR `config.sqlite` and profile helpers at runtime.
- Tokens are exported only into the child `claude` process via `ANTHROPIC_AUTH_TOKEN`.
- Status lines print the profile id and model, never the token.
- If a profile returns 401, re-save or re-enable that agent in CCR Desktop — do not paste keys into git.

## License

[MIT](./LICENSE)
