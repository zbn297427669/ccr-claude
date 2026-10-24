# ccr-claude — Windows (`ccr-claude.ps1`)

[English](./README.md) | [简体中文](./README.zh-CN.md) | [All platforms](../README.md)

`ccr-claude.ps1` is the real entry point; `ccr-claude.cmd` is a thin shell for double-click and cmd use. They are equivalent: both discover the profile, client key, gateway URL and model window from CCR's `config.sqlite`, and neither contains secrets or machine-specific paths.

## Prefer the `.ps1`

`.cmd` forwards arguments with `%*`, and cmd expands percent signs in them unconditionally — `EnableDelayedExpansion` does not turn that off. Measured with the same caller and the same argument:

```
input: 50% off and PATH=%PATH% done
.cmd → 50% off and PATH=C:\WINDOWS\system32;...\GitHub CLI done
.ps1 → 50% off and PATH=%PATH% done
```

`call ccr-claude.cmd` parses a second time on top of that, and a `>` in an argument comes out with an extra `^`. The `.ps1` has no such layer: `$args` arrives verbatim and goes straight to `claude`.

So: use the `.ps1` for code snippets, regexes, and anything containing `%`. For double-clicking or typing in cmd, the `.cmd` is fine. Both pass the exit code through.

## Installing as `ccr-claude`

Run the repo's own installer once, and both shells can run `ccr-claude`:

```powershell
# prints the plan and writes nothing
.\windows\install.ps1

# write it (backs up the current PATH and CCR_CLAUDE_EXE first)
.\windows\install.ps1 -ClaudeExe 'C:\path\to\claude' -Apply
```

It does three things: adds this repo's `windows` directory to the user `PATH`,
points `CCR_CLAUDE_EXE` at `claude.exe`, and removes any PATH entry still holding
a hand-copied launcher. The originals are saved to
`%LOCALAPPDATA%\ccr-claude\install-backup-<timestamp>.txt` before anything is
written.

It refuses a UNC path (`\\wsl.localhost\...`): `RemoteSigned` will not run a
`.ps1` from one, so installing from there produces a launcher that fails at
startup. The repo has to live on a local drive.

Doing it by hand is the same thing:

```powershell
$repo = '<repo>'   # e.g. C:\tools\ccr-claude
[Environment]::SetEnvironmentVariable(
  'Path', "$repo\windows;" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')
```

In a new terminal:

```bat
ccr-claude                       :: PowerShell resolves ccr-claude.ps1
ccr-claude --pick                :: cmd resolves ccr-claude.cmd
where ccr-claude                 :: <repo>\windows\ccr-claude.cmd
```

No wrapper is needed for the two same-named files: PowerShell's `Get-Command` picks `.ps1` first per `PATHEXT`, cmd's `where` picks `.cmd`. **In PowerShell, `ccr-claude` runs the `.ps1`**, so the two `%*` traps above never apply.

### `claude.exe` need not sit next to the script

The launcher looks for `claude` in this order:

1. `CCR_CLAUDE_EXE` — the exe itself, or a directory holding `claude*` executables
2. `claude` on `PATH`
3. `claude-*-win32-x64.exe` in the script's own directory

Point it at wherever the exe already lives:

```powershell
[Environment]::SetEnvironmentVariable(
  'CCR_CLAUDE_EXE', 'C:\path\to\claude', 'User')   # a directory, or the exe's full path
```

Rule 3 used to be the only way, which forced a hand-copied script into the same folder as a 296MB exe — and that copy went stale on every repo update. Now the script stays in the repo and follows `git pull`; the exe stays where it is.

## Usage

```bat
:: recommended
powershell -NoProfile -File <repo>\windows\ccr-claude.ps1 -p "explain this repo"

:: double-click / cmd
<repo>\windows\ccr-claude.cmd
<repo>\windows\ccr-claude.cmd --pick
<repo>\windows\ccr-claude.cmd --pick-model
<repo>\windows\ccr-claude.cmd --list-profiles
<repo>\windows\ccr-claude.cmd --profile <id>       :: or set CCR_PROFILE
<repo>\windows\ccr-claude.cmd --model XM/bonsai-heretic
<repo>\windows\ccr-claude.cmd --context-window 262144
<repo>\windows\ccr-claude.cmd --skip-check
<repo>\windows\ccr-claude.cmd --continue
<repo>\windows\ccr-claude.cmd --resume
```

The launcher's own switches are all double-dash; everything else (`-p`, `--model`, `--continue`, …) goes to `claude` untouched. There is deliberately no PowerShell `param` block: PowerShell binds parameters by prefix, and declaring `-ProfileId` would steal `claude`'s own `-p` (measured: `AmbiguousParameter`).

Startup lines (profile, model, window) go to **stderr**; the answer goes to stdout. So `2>/dev/null` keeps only model output, and `2>&1` is what shows the diagnostics.

### The two menus

**Profile menu** — appears when CCR has more than one usable Claude Code agent. The last one used comes first, marked `(last)`. Silent when there is only one usable profile, when stdin is not a terminal, when `CCR_NO_PICK=1`, or when `-p`/`--print` is being forwarded. `--pick` forces it.

**Model menu** — appears when the profile's `availableModels` holds more than one entry. The current model comes first, marked `(current)`, so pressing Enter keeps today's behaviour. That list is also the gateway's allow-list, so every entry offered will route. Short names are shown (after the `/`, without `[1m]`); the full CCR name is what Claude Code gets. It follows the same silent rules plus "only one model". `--pick-model` overrides all four.

When `MODEL` / `--model` already names a model, the model menu does not appear — that's an explicit override.

## What it reads

| Item | Source |
| --- | --- |
| CCR data dir | `CCR_DIR`, else `%APPDATA%\claude-code-router` |
| Gateway URL | `CCR_BASE_URL`, else `routerEndpoint`, else `gateway.host:port` |
| Client key | `api_keys` table (`encryption == plain` only), else `ccr-profile-…` inside `bin\ccr-claude-code-api-key-<pid>.cmd` |
| Model | `--model` / `MODEL` / the profile's `model` / the menu |
| Context window | CCR `modelMetadata.contextWindow` → loopback `/v1/models` → `models.json` (`limits.contextTokens`) → per-machine catalog. See [CONTEXT-WINDOW.md](../CONTEXT-WINDOW.md) |
| `claude` exe | `CCR_CLAUDE_EXE` → `PATH` → next to the script |

The key is read at runtime and written into the process environment; it is never persisted. `python` is required — PowerShell has no built-in SQLite. The three database files (including `-wal`/`-shm`) are copied to a temp directory and opened read-only so CCR is not locked.

## Six things that bite

### 1. `settings.json`'s `env` outranks process environment variables

Measured: with `ANTHROPIC_BASE_URL=…:3456` in the process and `…:1` in `settings.json`'s `env`, requests go to `:1` and fail with `ECONNREFUSED`. The wrapper CCR generates and an existing user `settings.json` therefore swallow everything the launcher sets, including `CLAUDE_CODE_MAX_CONTEXT_TOKENS`.

So the launcher writes an extra `%LOCALAPPDATA%\ccr-claude\settings.json` and passes it via `--settings`. Measured: `--settings`'s `env` beats `settings.json`'s `env` (same broken-address experiment, connects to `3456` once the overlay is in). The overlay carries only non-secret values; the token still travels in the process environment.

> Exception: `ANTHROPIC_AUTH_TOKEN` is unaffected — a fake token in the process produces a 401, proving the process value is the one used.

### 2. A model name must hit the gateway cache, or autocompact does not run

For a model name absent from `~/.claude/cache/gateway-models.json`, Claude Code skips the autocompact threshold check entirely and the session grows until the engine refuses it. The cache holds long names:

```
OD/deepseek-v4.1-flash  ->  anthropic/claude-ccr-h4f442f646565707365656b2d76342e312d666c617368
```

The bytes after `h` are the original name in hex (`4f442f` = `OD/`), so it is reversible. The launcher does two things:

- folds a short name / display_name into the cache `id` before setting `ANTHROPIC_MODEL`;
- decodes a pasted long name back to `OD/deepseek-v4.1-flash` to look up the provider and window.

`[claude-code:unrecognized_model]` is telemetry, not an error; the request returns normally.

### 3. The overlay must blank `apiKeyHelper`

With `apiKeyHelper` in `settings.json` and a token in `ANTHROPIC_AUTH_TOKEN`, the TUI shows:

```
Both ANTHROPIC_AUTH_TOKEN and apiKeyHelper set · auth may not work as expected
```

In 2.1.310 the check is `ua().source !== "none" && kp().source !== "none"`. `Ng()` starts with `return pe("flagSettings")?.apiKeyHelper`, and `--settings` *is* flagSettings — so `"apiKeyHelper": ""` in the overlay makes it return falsy, both sources land on `none`, and the banner cannot fire. The helper is not executed either (marker probe: a real value shows CALLED, an empty string shows NOT-CALLED).

**Do not use `null`**: `apiKeyHelper: [REDACTED] string, but received null` — the setting is rejected, dropped, and logged as an ERROR.

### 4. The `Custom …` entries must carry the CCR name, not `display_name`

`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` supplies the text of those `/model` menu entries. Passing the cache's long name (`anthropic/claude-ccr-h<hex>`) gives you a wall of ids, so the launcher decodes back to the CCR name first.

But **not** to the cache's `display_name` (`Go/DeepSeek V4 Flash (1M context)`): the gateway accepts only the CCR short and long names; `display_name` returns 403 exactly like a fabricated name, so picking it in the menu sends nothing. The decoded `OD/deepseek-v4.1-flash` both routes and reads well.

Decoding must preserve the `[1m]` suffix (`Go/deepseek-v4-flash[1m]` and `Go/deepseek-v4-flash` are two different gateway entries), and the local variables must not be called `$m` — PowerShell variable names are case-insensitive, so `$m` *is* the parameter `$M`, and `Substring` rewrites the original too.

### 5. `$ErrorActionPreference='Stop'` turns redirected stderr into a fatal error

`claude` writes telemetry to stderr. When the **caller** redirects stderr (`2>$null`, `2>&1`), PowerShell 5.1 records each native stderr line as a `NativeCommandError`. With the script's own `$ErrorActionPreference = 'Stop'`, that line aborts the caller the moment it surfaces.

The symptom is misleading: running `powershell -File ccr-claude.ps1` directly is fine, but invoking it from another script with `&` dies at the launch line and looks like the launcher crashed.

So the launcher relaxes the preference around the call:

```powershell
$ErrorActionPreference = 'Continue'
& $ClaudeExe @PassArgs
$rc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
exit $rc
```

If you hit the same thing calling `ccr-claude.ps1` from your own script, do the same or use the `.cmd`.

### 6. Piping Python code in is at the mercy of `$OutputEncoding`

Earlier versions used `$Code | python -` to pass the embedded Python. That pipe encodes text according to **`$OutputEncoding`** — a **session-level** variable. The same script behaved differently per terminal:

| `$OutputEncoding` | Result |
| --- | --- |
| UTF-8 (BOM or not) | ✅ |
| ASCII | ✅ (when the code is all ASCII) |
| GB2312 / GB18030 | ❌ `SyntaxError: Non-UTF-8 code ... on line 76` |
| UTF-16 / UTF-16BE | ❌ `SyntaxError ... starting with '\xff' on line 1` |

The code contains Chinese comments, so GB2312 blows up on that comment line; UTF-16 does not even match the BOM and fails on line 1. With `2>$null` all you see is `python.exe : File "<stdin>", line 1`, and the real cause is gone.

It now writes a temp file (UTF-8 without BOM, GUID-named to avoid collisions), deletes it afterwards, and owns the encoding. `Find-Python` also skips the `WindowsApps` app-execution aliases (Microsoft Store stubs, rc=9009) and confirms a real interpreter with an `import sqlite3` probe.

## Differences from the WSL version

- **Arguments are forwarded differently**: here the launcher's own switches are all double-dash (`--pick`, `--list-profiles`) and everything else goes to `claude` untouched, because PowerShell binds parameters by prefix — once `-ProfileId` exists, `-p` belongs to it.
- **There is a `--settings` overlay**: on WSL the `settings.json` is written by the script itself, so there is nothing to fight. On Windows the user `settings.json` is generated by CCR and overrides environment variables, so only `--settings` can push back.
- **This file must be UTF-8 with BOM**: PowerShell 5.1 decodes a BOM-less `.ps1` as GBK, turning Chinese comments into mojibake and sometimes breaking parsing outright.

## Windows for local models

`XM/bonsai-heretic` has an empty `contextWindow` in CCR's `modelMetadata`, and `/v1/models` cannot answer while the engine is down. In that case the launcher sets **no** `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (blank beats a guess), so the menu shows `unknown` and Claude Code falls back to `autoCompactWindow` in `settings.json` — 500000 for that model there — before its own 200000 default.

Per `ninfer\launcher\config.bat` the current engine variant is `ternary` with 524288; switching to `kvmem-0.18.0` clamps it to 262144. To get the full window, say so:

```bat
ccr-claude.cmd --model XM/bonsai-heretic --context-window 524288
```

Claude Code's rule is **`effectiveWindow = MAX − 20000`**. There is **no** 800000 cap in 2.1.310 (`1000000` measures 980000), so the old "780000 ceiling" note no longer applies.

### `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is global

It clamps **every** model, not just the current one. The launcher therefore resolves it per run, from the model that is about to start, rather than leaving one fixed number in the environment: `OD/deepseek-v4.1-flash` resolves to 1000000, `Go/qwen3.8-max` to 1048576.

What the menu prints is the model's window, not necessarily where compaction fires: `settings.json` pins `autoCompactWindow` per model (800000 for the `deepseek` entries, 500000 for the XM ones), and `pS()` takes `Math.min(window, pin)`. Pass `--context-window` to override both:

```bat
ccr-claude.cmd --model Go/qwen3.8-max --context-window 1048576
ccr-claude.cmd --model Go/qwen3.8-max --context-window off
```
