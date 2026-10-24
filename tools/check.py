#!/usr/bin/env python3
"""Checks that run before a launcher change is trusted.

Both launchers are one file each, and both hide their real logic in embedded
Python that no interpreter ever sees as a file: the shell passes heredocs on
stdin, PowerShell writes `$PyProfiles` to a temp file. A syntax error in either
therefore surfaces only on the machine that happens to run that launcher first
-- which is why these five checks exist as a script rather than as commands
someone remembers to retype.

    python3 tools/check.py            # from the repo root
    python3 tools/check.py --verbose  # say what passed, not just what failed

Exit code is 0 only when every check passes. Nothing here touches CCR, the
network, or any credential: it reads the two scripts as text and parses the
Python inside them.
"""

from __future__ import annotations

import ast
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SH = ROOT / "wsl" / "start-claude.sh"
PS1 = ROOT / "windows" / "ccr-claude.ps1"
CMD = ROOT / "windows" / "ccr-claude.cmd"
INSTALL_PS1 = ROOT / "windows" / "install.ps1"

VERBOSE = "--verbose" in sys.argv

failures: list[str] = []
passes: list[str] = []
skips: list[str] = []


def ok(name: str) -> None:
    passes.append(name)
    if VERBOSE:
        print(f"  ok   {name}")


def skip(name: str, why: str) -> None:
    skips.append(name)
    print(f"  skip {name} ({why})")


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"  FAIL {name}")
    for line in detail.rstrip().splitlines():
        print(f"       {line}")


def check_bash_syntax() -> None:
    """`bash -n` parses the whole script without running any of it.

    Fed on stdin rather than as a filename: on Windows, Git Bash does not turn a
    `C:\\...` argument into a path (backslashes are escapes), and `bash -n` over
    a path it cannot open exits 1 with a *silent* stderr -- which reads as a
    syntax failure. Stdin sidesteps path translation entirely.
    """
    if not SH.is_file():
        fail("bash syntax", f"{SH} is missing")
        return
    if not shutil.which("bash"):
        skip("bash syntax", "no bash on PATH")
        return
    proc = subprocess.run(
        ["bash", "-n", "-s"],
        input=SH.read_bytes(),
        capture_output=True,
    )
    if proc.returncode:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail("bash syntax", detail or f"bash -n exited {proc.returncode} with no message")
    else:
        ok("bash syntax")


def check_shell_heredocs() -> None:
    """Every `<<'PY' ... PY` block in the shell script must parse as Python.

    The heredoc delimiter is `'PY'` -- quoted, so the shell does not expand
    anything inside. That makes the block plain Python text from start to end.
    """
    if not SH.is_file():
        fail("shell heredocs", f"{SH} is missing")
        return
    text = SH.read_text(encoding="utf-8")
    # `<<'PY'` may be followed by redirections (`2>/dev/null`) on the same line.
    blocks = list(
        re.finditer(r"<<'PY'[^\n]*\n(.*?)\nPY[ \t]*$", text, re.S | re.M)
    )
    if not blocks:
        fail("shell heredocs", "found no <<'PY' blocks -- did the delimiter change?")
        return
    bad = []
    for i, m in enumerate(blocks, 1):
        line_no = text.count("\n", 0, m.start(1)) + 1
        try:
            ast.parse(m.group(1))
        except SyntaxError as e:
            bad.append(f"block {i} (line {line_no}): {e.msg} at offset {e.offset}")
    if bad:
        fail("shell heredocs", "\n".join(bad))
    else:
        ok(f"shell heredocs ({len(blocks)} blocks)")


def check_ps_embedded_python() -> None:
    """The `$PyProfiles = @' ... '@` here-string must parse as Python."""
    if not PS1.is_file():
        fail("powershell embedded python", f"{PS1} is missing")
        return
    text = PS1.read_text(encoding="utf-8-sig")
    m = re.search(r"^\$PyProfiles = @'\r?\n(.*?)\r?\n'@", text, re.S | re.M)
    if not m:
        fail(
            "powershell embedded python",
            "found no $PyProfiles here-string -- did the delimiter change?",
        )
        return
    try:
        ast.parse(m.group(1))
    except SyntaxError as e:
        fail("powershell embedded python", f"{e.msg} (line {e.lineno})")
    else:
        ok(f"powershell embedded python ({len(m.group(1).splitlines())} lines)")


def check_ps_syntax() -> None:
    """Parse every .ps1 with PowerShell's own parser when one is available.

    Windows ships Windows PowerShell 5.1 (`powershell.exe`); anything else
    ships `pwsh`. Both parse the same language for our purposes.
    """
    exe = shutil.which("pwsh") or shutil.which("powershell")
    if not exe:
        skip("powershell syntax", "no pwsh / powershell on PATH")
        return
    targets = [p for p in (PS1, INSTALL_PS1) if p.is_file()]
    if not targets:
        fail("powershell syntax", "no .ps1 files found")
        return
    # The paths go through the environment, not the command line. `-Command`
    # appends any extra arguments to the command *text*: passing two paths
    # produced `...; exit $bad D:\a\...` and a ParserError, measured in CI. A
    # temp script file would work too, but this needs no cleanup.
    env = dict(os.environ)
    env["CCR_CHECK_FILES"] = os.pathsep.join(str(p) for p in targets)
    script = (
        "$bad = 0; "
        "foreach ($f in $env:CCR_CHECK_FILES.Split([IO.Path]::PathSeparator)) { "
        "  if (-not $f) { continue }; "
        "  $errs = $null; "
        "  $null = [System.Management.Automation.Language.Parser]::ParseFile("
        "$f, [ref]$null, [ref]$errs); "
        "  if ($errs.Count) { "
        "    Write-Output $f; "
        "    $errs | ForEach-Object { Write-Output ('  ' + $_.Message) }; "
        "    $bad = 1 "
        "  } "
        "}; "
        "exit $bad"
    )
    proc = subprocess.run(
        [exe, "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode:
        fail("powershell syntax", proc.stdout or proc.stderr)
    else:
        ok(f"powershell syntax ({len(targets)} file(s))")


def check_windows_encoding() -> None:
    """The two Windows files must be UTF-8 with BOM and CRLF.

    PowerShell 5.1 decodes a BOM-less .ps1 as GBK, which turns the Chinese
    comments into mojibake and can break parsing outright. cmd's parser wants
    CRLF. Both properties live in the working tree, not the git blob -- a Linux
    checkout applies `.gitattributes`' `eol=crlf` -- so checking here also
    catches an editor that silently rewrote the file as LF.
    """
    for path, want_bom in ((PS1, True), (INSTALL_PS1, True), (CMD, False)):
        name = f"encoding {path.name}"
        if not path.is_file():
            fail(name, f"{path} is missing")
            continue
        raw = path.read_bytes()
        problems = []
        if want_bom and not raw.startswith(b"\xef\xbb\xbf"):
            problems.append("missing UTF-8 BOM (PowerShell 5.1 will read it as GBK)")
        if not want_bom and raw.startswith(b"\xef\xbb\xbf"):
            problems.append("unexpected UTF-8 BOM (cmd would run it as part of line 1)")
        if b"\r\n" not in raw:
            problems.append("no CRLF line endings")
        else:
            # A stray bare LF means something mixed the two.
            bare = raw.count(b"\n") - raw.count(b"\r\n")
            if bare:
                problems.append(f"{bare} bare LF line ending(s)")
        if problems:
            fail(name, "\n".join(problems))
        else:
            ok(name)


CHECKS = (
    check_bash_syntax,
    check_shell_heredocs,
    check_ps_embedded_python,
    check_ps_syntax,
    check_windows_encoding,
)


def main() -> int:
    print(f"checking {ROOT.name}")
    for check in CHECKS:
        check()
    if failures:
        print(f"\n{len(failures)} check(s) failed")
        return 1
    tail = f"all {len(passes)} checks passed"
    if skips:
        tail += f", {len(skips)} skipped"
    print(f"\n{tail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
