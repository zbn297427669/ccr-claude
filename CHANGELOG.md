# Changelog

Notable changes to the launchers. Both platforms share a version number: a tag
describes a set of behaviours, and the two files must agree on them.

The window figures were measured against **Claude Code 2.1.310**. Effective
context is `MAX − 20000` (output reserve), and that version has no 800000 cap.

## [Unreleased]

### Added

- **`windows/install-claude.ps1` installs the Claude Code CLI from a local
  exe, with no network.** `claude install` needs the network twice — to resolve
  the version, and again at "Checking installation status..." — so on a machine
  that cannot reach `downloads.claude.ai` it fails even when the exe is already
  downloaded; `--force` makes it worse by skipping the local-cache check. The
  script does what `install` does (binary to `~\.local\bin`, PATH entry) but
  from the file on disk. It reads the version from the release's file name,
  refuses anything without a PE `MZ` header (a blocked download often saves an
  HTML error page under the `.exe` name), and verifies SHA256 against the
  release's `sha256sums.txt`, or `-ExpectedHash` when there is no network at
  all. Dry run by default; `-Cache` also seeds the version cache so a later
  `claude install <ver>` works offline.

## [0.2.1] - 2026-11-01

### Added

- **`install.ps1` runs a preflight on the three run-time prerequisites.**
  It reports python-with-`sqlite3`, the CCR data directory, and a reachable
  gateway, and prints the command that fixes each gap. The python rule is the
  launcher's: `%LOCALAPPDATA%\Microsoft\WindowsApps\` is skipped as a Store stub,
  and a real interpreter is confirmed with `import sqlite3`. It reports rather
  than fails — installing before CCR is configured is a legitimate order — and
  `-SkipChecks` turns it off. The gateway port is read from `config.sqlite`, so
  that check is omitted when python is absent instead of guessing 3456.

- **A `Prerequisites` section in both top-level READMEs.** It names the running
  gateway, an enabled agent, and python-with-`sqlite3`, and says which of them
  cannot be automated (provider API keys). It also gives the official Claude Code
  installer, and a mirror for users who cannot reach it, with the trust boundary
  of a mirror's checksums stated.

- **`tools/release.py` cuts a release in one command.** `./RELEASING.md`
  described the process in prose and every step was one a person could skip —
  the checks, the archive range that includes `CONTEXT-WINDOW.md`, and the CRLF
  verification. The script runs them in order, refuses to build on a dirty tree
  or a stale changelog link, tags locally by default, and only pushes and calls
  `gh release create` under `--publish`. `tools/check.py` now compiles it too.

- **`v0.2.1` is the first tag.** `0.1.0` and `0.2.0` were written up from the
  commit history and never got tags, so their changelog links pointed at
  comparisons that did not resolve. Those two now link to commit ranges; the
  `Unreleased`/`HEAD` link is gone.

### Fixed

- **`install.ps1` piped in (`irm ... | iex`) died on a binding error.** It read
  `$PSScriptRoot`, which is empty when the script did not come from a file, so
  `Split-Path -Parent ''` threw `ParameterBindingValidationException` before any
  of the script's own messages could run. It now exits with an instruction to
  pass `-RepoPath`, so publishing an `irm | iex` line fails legibly instead of
  with a message the reader cannot act on.

- **A model that reports its window as `meta.n_ctx` now resolves instead of
  showing `unknown`.** `window_of()` read flat fields (`context_window`,
  `contextWindow`, `max_context_window`, `max_model_len`) and CCR's `limits`
  object, but not the nested `meta` one. Servers of the llama.cpp family put it
  there — a local engine's `/v1/models` answers
  `{"id": "...", "meta": {"n_ctx": 32768}}` — and other single-file inference
  servers do the same, which their own launchers already handle (trying
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

- **The model menu offered models the gateway had already dropped.** CCR's
  `availableModels` is history, not a live list: deleting a provider or renaming
  its models does not rewrite it, so picking a stale entry failed with
  `model_not_found`. Both launchers now compare the profile's list against
  `/v1/models` — filtered by the client key, so it is the authoritative
  per-profile list — and drop what the gateway no longer offers. The Windows
  launcher had to fetch its token before the menu instead of after; on WSL it
  was already available. The current model is never dropped even when it looks
  stale: Enter means "keep what the profile says", and changing it is CCR's job,
  so it is reported instead. Reconciliation is best effort — no `curl`, gateway
  down, timeout, or an unexpected shape all leave the list untouched, since
  preflight already reports a gateway that is genuinely unreachable.

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
  fields, so that source matched zero entries. A 1M-window model now
  resolves to `1000000`.
- **Conflicting catalog entries now require agreement.** One model name can map
  to several entries ~5% apart (`vendor-a/…` and `vendor-b/…` both list the
  same model). They must agree within 10%, and the smaller value wins —
  it can only compact early, never late. A wider spread means the name really
  names two models, and then the file is treated as knowing nothing.
- **A model no longer inherits its neighbours' windows.** Every name in the
  provider's metadata used to be a candidate, so a short name could
  pick up whatever another model in the same provider declared. Only the model's
  own names count now.
- **The per-install catalog's 128000 is skipped.** CCR writes `KFe=128e3` for
  any model it has no metadata for. That is a default, not a reading — treating
  it as one had been pulling a configured 800000 down to 128000.
- **WSL strips the `[1m]` suffix when resolving**, matching the Windows side, so
  `<provider>/<model>[1m]` and `<provider>/<model>` resolve the same.

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

[0.2.1]: https://github.com/zbn297427669/ccr-claude/compare/d45d646...v0.2.1
[Unreleased]: https://github.com/zbn297427669/ccr-claude/compare/v0.2.1...HEAD
[0.2.0]: https://github.com/zbn297427669/ccr-claude/compare/d2474b4...d45d646
[0.1.0]: https://github.com/zbn297427669/ccr-claude/tree/d2474b4

<!-- 0.1.0 and 0.2.0 predate tagging: they were written up from the commit
     history and never got a tag or release of their own. Their links point at
     commit ranges instead of tags so they resolve. v0.2.1 is the first tag. -->
