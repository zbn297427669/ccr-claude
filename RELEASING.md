# Release process

Two launchers, one version number. `v0.2.0` describes a set of *behaviours*
(which window a model reports, what `--context-window off` does), and both files
must match it — that is why they share a tag instead of versioning separately.
There is no shared code between them; what is shared is meaning, and a release
note that says "the model menu shows a context window" has to be true on both
platforms or it is wrong.

## Why the release artifacts are archives, not raw links

`.gitattributes` marks the Windows files `eol=crlf`, and that conversion happens
**at checkout / archive time**. Measured on this repo:

| How you get the file | `ccr-claude.ps1` line endings | `ccr-claude.cmd` |
| --- | --- | --- |
| `git clone` | CRLF | CRLF |
| `git archive` / GitHub zipball | CRLF | CRLF |
| `raw.githubusercontent.com` | **LF** | **LF** |

Raw serves the blob's bytes unchanged. A `.ps1` with LF endings still runs, but a
`.cmd` with LF endings is unreliable under cmd's parser, and neither is what
`.gitattributes` promises. So a release publishes `git archive` output and never
points anyone at a raw URL.

Note for anyone running the Windows launcher straight out of a WSL checkout:
`RemoteSigned` refuses to run a `.ps1` on a UNC path (`\\wsl.localhost\...`) with
`SecurityError: UnauthorizedAccess`. The Windows side needs a checkout on a local
drive, plus `CCR_CLAUDE_EXE` pointing at wherever `claude.exe` lives.

## Cutting a release

1. **Checks pass on a clean checkout.**

   ```bash
   python3 -I tools/check.py --verbose
   ```

   If you are on Windows, also confirm the PowerShell-parser line ran instead of
   skipping. CI (`check.yml`) does both an ubuntu and a windows job.

2. **Update the changelog and the version-labelled docs together.** See
   `CHANGELOG.md`; the comparison links at the bottom name the tag, so they need
   the new tag to exist on the remote before they resolve.

3. **Build the two artifacts from the tag, not from a working tree.**

   ```bash
   VERSION=v0.2.0
   git tag -a "$VERSION" -m "ccr-claude $VERSION"
   git push origin "$VERSION"

   mkdir -p dist
   git archive --format=zip --prefix="ccr-claude-$VERSION-windows/" \
     --output="dist/ccr-claude-$VERSION-windows.zip" "$VERSION" \
     windows/ README.md README.zh-CN.md CONTEXT-WINDOW.md LICENSE
   git archive --format=tar.gz --prefix="ccr-claude-$VERSION-wsl/" \
     --output="dist/ccr-claude-$VERSION-wsl.tar.gz" "$VERSION" \
     wsl/ README.md README.zh-CN.md CONTEXT-WINDOW.md LICENSE
   ```

   Verify the Windows archive before uploading — this is the step that would
   have caught the raw-link problem:

   ```bash
   unzip -p "dist/ccr-claude-$VERSION-windows.zip" \
     "ccr-claude-$VERSION-windows/windows/ccr-claude.ps1" | grep -c $'\r'
   # must be non-zero, and equal to the file's line count
   ```

4. **Create the release** and attach both archives:

   ```bash
   gh release create "$VERSION" dist/* \
     --title "ccr-claude $VERSION" \
     --notes-file <(sed -n "/^## \[$VERSION\]/,/^## \[/p" CHANGELOG.md | head -n -1)
   ```

   The release notes should name the one thing a user has to do differently, if
   anything (`CCR_CLAUDE_EXE` is now the supported way to point at `claude.exe`).

## What a release note must say

- Which `claude` version the window behaviour was measured against. The numbers
  are not stable across versions: `2.1.310` has no 800000 cap, and the effective
  window is `MAX − 20000`.
- Any changed default. Leaving `CLAUDE_CODE_MAX_CONTEXT_TOKENS` unset is a
  behaviour, not an absence of one — say so when it changes.
- Anything a user must reinstall rather than `git pull`. Today that is only the
  Windows PATH entry, and only if they came from the hand-copied-script era.
