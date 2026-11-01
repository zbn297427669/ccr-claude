#!/usr/bin/env python3
"""Cut a release: check, tag, build both archives, verify them.

`RELEASING.md` describes the process in prose, and every step in it is one a
person can skip by accident: the checks, the tag from the right commit, the
archive range that includes CONTEXT-WINDOW.md, and the CRLF verification that
the raw-link incident taught us to run. This script is that prose written down
once so it runs in the same order every time.

    python3 -I tools/release.py --dry-run        # say what would happen
    python3 -I tools/release.py                  # build dist/
    python3 -I tools/release.py --publish        # also tag, push, gh release

Nothing here talks to the network unless --publish is given.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
DIST = ROOT / "dist"

# What goes into each artifact. Listed here rather than inline in RELEASING.md so
# that adding a file to the release is a one-line change in one place. The two
# READMEs and CONTEXT-WINDOW.md are shared; LICENSE travels with both because a
# zip that omits it is not redistributable.
COMMON = ["README.md", "README.zh-CN.md", "CONTEXT-WINDOW.md", "LICENSE"]
ARTIFACTS = [
    ("windows", "zip", ["windows"] + COMMON),
    ("wsl", "tar.gz", ["wsl"] + COMMON),
]

failures: list[str] = []


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def fail(msg: str) -> None:
    failures.append(msg)
    print(f"  FAIL {msg}")


def ok(msg: str) -> None:
    print(f"  ok   {msg}")


def step(title: str) -> None:
    print(f"\n== {title}")


# ---------------------------------------------------------------- 1. changelog
def read_version() -> str:
    """The top-most released heading, e.g. `## [0.2.1] - 2026-11-01`.

    Deliberately not "the highest number": a release is whatever the changelog
    says is next, and deriving it from tags too would let the two disagree.
    """
    if not CHANGELOG.is_file():
        fail(f"{CHANGELOG.name} is missing")
        return ""
    text = CHANGELOG.read_text(encoding="utf-8")
    m = re.search(r"^## \[(\d+\.\d+\.\d+)\](?: - (\d{4}-\d{2}-\d{2}))?", text, re.M)
    if not m:
        fail("no `## [x.y.z]` heading in CHANGELOG.md")
        return ""
    if not m.group(2):
        fail(f"version {m.group(1)} has no `- YYYY-MM-DD` date")
    return m.group(1)


def check_changelog_links(version: str) -> None:
    """Every version heading needs a link definition, and vice versa.

    The unreleased section is the one that bites: renaming `[Unreleased]` to a
    version leaves its link pointing at `...HEAD`, which still renders but no
    longer means anything.
    """
    text = CHANGELOG.read_text(encoding="utf-8")
    headings = re.findall(r"^## \[([^\]]+)\]", text, re.M)
    links = dict(re.findall(r"^\[([^\]]+)\]: (\S+)", text, re.M))
    for h in headings:
        if h not in links:
            fail(f"heading [{h}] has no link definition at the bottom")
    if "[Unreleased]" not in headings and "Unreleased" in links:
        fail("[Unreleased] link is still defined but no such heading exists")
    # A released version must compare against the previous tag, not HEAD.
    for h in headings:
        if h == "Unreleased":
            continue
        target = links.get(h, "")
        if target.endswith("...HEAD"):
            fail(f"[{h}] compares against HEAD; a release compares tag...tag")
    ok(f"changelog has {len(headings)} version heading(s) and matching links")


# ---------------------------------------------------------------- 2. git state
def git(*args: str) -> str:
    r = run(["git", *args])
    if r.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def check_git_state(version: str) -> None:
    if git("status", "--porcelain"):
        fail("working tree is not clean -- commit first, or the tag names a tree you cannot rebuild")
    else:
        ok("working tree is clean")

    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if branch != "main":
        fail(f"on branch `{branch}`, not `main`")
    else:
        ok("on main")

    tag = f"v{version}"
    existing = run(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"])
    if existing.returncode == 0:
        fail(f"tag {tag} already exists")
    else:
        ok(f"tag {tag} is free")

    # The tag is cut here, so the branch must already be what upstream has --
    # otherwise the released tree is one nobody can fetch.
    ahead = run(["git", "rev-list", "--count", "origin/main..HEAD"])
    if ahead.returncode == 0 and ahead.stdout.strip() not in ("", "0"):
        fail(f"local main is {ahead.stdout.strip()} commit(s) ahead of origin/main; push first")
    elif ahead.returncode != 0:
        ok("no origin/main to compare against (skipped)")
    else:
        ok("main matches origin/main")


# ---------------------------------------------------------------- 3. checks
def run_checks() -> None:
    r = run([sys.executable, "-I", str(ROOT / "tools" / "check.py")])
    if r.returncode:
        fail("tools/check.py failed:\n" + r.stdout + r.stderr)
    else:
        ok("all launcher checks passed")


# ---------------------------------------------------------------- 4. archives
def build(version: str, tag_ref: str) -> list[Path]:
    """Archive from a git ref, never from the working tree.

    `git archive` is what applies `.gitattributes`' eol=crlf to the Windows
    files; a plain zip of the directory would ship whatever the checkout has.
    """
    DIST.mkdir(exist_ok=True)
    built: list[Path] = []
    for name, fmt, paths in ARTIFACTS:
        out = DIST / f"ccr-claude-v{version}-{name}.{fmt}"
        prefix = f"ccr-claude-v{version}-{name}/"
        cmd = ["git", "archive", f"--format={fmt}", f"--prefix={prefix}",
               f"--output={out}", tag_ref, *paths]
        r = run(cmd)
        if r.returncode:
            fail(f"git archive for {name}: {r.stderr.strip()}")
            continue
        ok(f"{out.name} ({out.stat().st_size // 1024} KB)")
        built.append(out)
    return built


def verify_zip(path: Path, version: str) -> None:
    """The CRLF check RELEASING.md calls out as the one that catches real bugs.

    A `.ps1` with LF endings still runs; a `.cmd` with LF endings does not. Both
    are supposed to be CRLF, but only the `.ps1` takes a BOM: cmd's parser would
    run a leading BOM as part of line 1. This mirrors `check_windows_encoding`
    in tools/check.py -- keep the two in step.
    """
    prefix = path.name[: -len(".zip")]
    wanted = {
        "windows/ccr-claude.ps1": True,    # BOM required (PowerShell 5.1 reads GBK otherwise)
        "windows/ccr-claude.cmd": False,   # BOM forbidden (cmd would run it)
    }
    with zipfile.ZipFile(path) as z:
        for member, want_bom in wanted.items():
            name = f"{prefix}/{member}"
            try:
                raw = z.read(name)
            except KeyError:
                fail(f"{path.name}: missing {member}")
                continue
            has_bom = raw.startswith(b"\xef\xbb\xbf")
            if want_bom and not has_bom:
                fail(f"{path.name}: {member} has no UTF-8 BOM")
            elif not want_bom and has_bom:
                fail(f"{path.name}: {member} has a UTF-8 BOM (cmd would run it as part of line 1)")
            elif raw.count(b"\r\n") != raw.count(b"\n"):
                fail(f"{path.name}: {member} has bare LF line endings")
            else:
                ok(f"{path.name}: {member} is {'BOM + ' if want_bom else ''}CRLF")


def verify_tar(path: Path) -> None:
    r = run(["tar", "-tzf", str(path)])
    if r.returncode:
        fail(f"cannot list {path.name}: {r.stderr.strip()}")
        return
    names = r.stdout.split()
    wanted = f"{path.name[: -len('.tar.gz')]}/wsl/start-claude.sh"
    if wanted not in names:
        fail(f"{path.name}: missing wsl/start-claude.sh")
    else:
        ok(f"{path.name}: contains wsl/start-claude.sh")


# ---------------------------------------------------------------- 5. publish
def release_notes(version: str) -> str:
    """The changelog section for this version, minus its heading line."""
    text = CHANGELOG.read_text(encoding="utf-8")
    m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else ""


def main() -> int:
    ap = argparse.ArgumentParser(description="Cut a ccr-claude release.")
    ap.add_argument("--dry-run", action="store_true", help="check and describe, build nothing")
    ap.add_argument("--publish", action="store_true",
                    help="also tag, push the tag, and create the GitHub release")
    ap.add_argument("--skip-network-checks", action="store_true",
                    help="do not compare against origin/main (offline)")
    args = ap.parse_args()

    print(f"ccr-claude release, from {ROOT}")

    step("changelog")
    version = read_version()
    if not version:
        return 1
    print(f"  version {version}")
    check_changelog_links(version)

    step("git state")
    try:
        check_git_state(version)
    except RuntimeError as e:
        fail(str(e))

    step("checks")
    run_checks()

    if failures:
        print(f"\n{len(failures)} problem(s); nothing was built.")
        return 1

    tag = f"v{version}"
    if args.dry_run:
        step("would build")
        for name, fmt, paths in ARTIFACTS:
            print(f"  dist/ccr-claude-{tag}-{name}.{fmt} <- {tag}: {' '.join(paths)}")
        print("\nDry run: nothing written.")
        return 0

    step("build")
    # Without --publish, tag locally so `git archive <tag>` names exactly what
    # would ship; the tag is deletable and unreleased. With --publish the same
    # tag is what gets pushed.
    if not args.publish:
        r = run(["git", "tag", "-a", tag, "-m", f"ccr-claude {tag}"])
        if r.returncode:
            fail(f"git tag: {r.stderr.strip()}")
    built = build(version, tag)

    step("verify")
    for p in built:
        if p.suffix == ".zip":
            verify_zip(p, version)
        else:
            verify_tar(p)

    if failures:
        print(f"\n{len(failures)} problem(s); do not publish these archives.")
        return 1

    if not args.publish:
        print(f"\nBuilt {len(built)} archive(s) in dist/, tagged {tag} locally.")
        print("Nothing was pushed. When you are ready:")
        print(f"  git push origin {tag}")
        print(f"  gh release create {tag} dist/* --title 'ccr-claude {tag}' --notes-file <notes>")
        return 0

    step("publish")
    push = run(["git", "push", "origin", tag])
    if push.returncode:
        fail(f"git push: {push.stderr.strip()}")
        return 1
    ok(f"pushed {tag}")

    notes = release_notes(version)
    notes_path = DIST / f"notes-{tag}.md"
    notes_path.write_text(notes + "\n", encoding="utf-8")
    gh = run(["gh", "release", "create", tag, *[str(p) for p in built],
              "--title", f"ccr-claude {tag}", "--notes-file", str(notes_path)])
    if gh.returncode:
        fail(f"gh release: {gh.stderr.strip()}")
        return 1
    ok("release created")
    print(gh.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
