# Changelog

Notable changes to the launchers. Both platforms share a version number: a tag
describes a set of behaviours, and the two files must agree on them.

The window figures were measured against **Claude Code 2.1.310**. Effective
context is `MAX − 20000` (output reserve), and that version has no 800000 cap.

## [Unreleased]

### Fixed

- **A model that reports its window as `meta.n_ctx` now resolves instead of
  showing `unknown`.** `window_of()` read flat fields (`context_window`,
  `contextWindow`, `max_context_window`, `max_model_len`) and CCR's `limits`
  object, but not the nested `meta` one. Servers of the llama.cpp family put it
  there — Strata's `/v1/models` answers
  `{"id": "...", "meta": {"n_ctx": 32768}}` — and ninfer's *ring* builds do the
  same, which its own launcher already handles (`lib/engine-status.ps1` tries
  `context_window`, then `max_model_len`, then `meta.n_ctx`). With no value
  resolved, the menu said `unknown` and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` was
  never set, so Claude Code fell back to its 128000/200000 default.
  Both launchers, same change; a shape that already resolved is untouched.

- **The model menu printed `~0.0M` for every window.** `Format-WindowLabel`
  declared `[string]$N` and then did `$n = [long]$N`. PowerShell variable names
  are case-insensitive, so `$n` *was* `$N`: the parameter's `[string]` type
  constraint turned the `[long]` straight back into a string. The following
  `$n -ge 1000000` then compared strings — `"32768" -ge "1000000"` is `'3' > '1'`
  — so every window took the millions branch and rendered as `~0.0M`. The local
  is now `$tokens`. This was latent until a `meta.n_ctx` model started resolving:
  before that the value was `unknown` and the formatter never ran.

## [0.2.0] - 2026-10-24

### Added

- **The model menu shows each model's context window** — `1.0M`, `128K`, or
  `unknown` when nothing resolves. Resolved once for the whole menu rather than
  per row. Values round to 100K above a million; a `~` marks a rounded number.
- **`--context-window <tokens|off>` on both launchers** (also
  `CCR_CONTEXT_WINDOW`). A number overrides every source. `off` sets nothing and
  leaves the decision to Claude Code — useful when a pin in `settings.json` is
  what you actually want.
- **`CCR_CLAUDE_EXE`** — point the Windows launcher at `claude.exe` wherever it
  lives, instead of copying the script next to it.
- `tools/check.py` and a CI workflow (`check.yml`) covering shell syntax, the
  embedded Python in both launchers, the PowerShell parse, and the Windows
  files' UTF-8-BOM/CRLF encoding.
- `RELEASING.md`, including why release artifacts are archives and not raw URLs.

### Fixed

- **`models.json` was never read.** Its windows live under
  `limits.contextTokens` / `limits.inputTokens`, and the lookup only knew flat
  fields, so that source matched zero entries. `OD/deepseek-v4.1-flash` now
  resolves to `1000000`.
- **Conflicting catalog entries now require agreement.** One model name can map
  to several entries ~5% apart (`alibaba/…` and `deepseek/…` both list
  `deepseek-v4-pro`). They must agree within 10%, and the smaller value wins —
  it can only compact early, never late. A wider spread means the name really
  names two models, and then the file is treated as knowing nothing.
- **A model no longer inherits its neighbours' windows.** Every name in the
  provider's metadata used to be a candidate, so `deepseek-v4.1-flash` could
  pick up whatever another model in the same provider declared. Only the model's
  own names count now.
- **The per-install catalog's 128000 is skipped.** CCR writes `KFe=128e3` for
  any model it has no metadata for. That is a default, not a reading — treating
  it as one had been pulling a configured 800000 down to 128000.
- **WSL strips the `[1m]` suffix when resolving**, matching the Windows side, so
  `Go/deepseek-v4-flash[1m]` and `Go/deepseek-v4-flash` resolve the same.

### Changed

- **The "unresolved" message is honest.** It used to say Claude Code would
  assume 200000. It now says what happens: `autoCompactWindow` from
  `settings.json`, then 200000.
- The Windows launcher no longer needs `claude.exe` in its own directory.
  `CCR_CLAUDE_EXE` → `PATH` → same directory, in that order; a path that
  resolves to nothing runnable is an error rather than a silent fallback.

## [0.1.0] - 2026-10-23

Grouped retrospectively: before this tag the launcher was a single WSL script
and the repo had no versioning.

### Added

- Windows launcher (`ccr-claude.ps1` + `ccr-claude.cmd`), split alongside the
  WSL one into `windows/` and `wsl/`.
- Model menu in both launchers, driven by the profile's `availableModels`.
- Context-window resolution and export via `CLAUDE_CODE_MAX_CONTEXT_TOKENS`.
- Profile menu, `--list-profiles`, last-used-profile memory, ambiguous-match
  errors, and gateway/token preflight.
- A pre-launch probe for `defer_loading` support (`CCR_CAPABILITY_CHECK`).

[Unreleased]: https://github.com/zbn297427669/ccr-claude/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/zbn297427669/ccr-claude/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/zbn297427669/ccr-claude/releases/tag/v0.1.0
