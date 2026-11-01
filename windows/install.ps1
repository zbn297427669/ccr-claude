#Requires -Version 5.1
<#
.SYNOPSIS
  Point the user PATH at this repo's windows\ directory, and CCR_CLAUDE_EXE at
  wherever claude.exe lives.

.DESCRIPTION
  Before CCR_CLAUDE_EXE existed, the only way to run the launcher was to copy
  ccr-claude.ps1 and ccr-claude.cmd next to a 296MB claude.exe -- outside the
  repo, so that copy silently fell behind. Measured on the machine this was
  written on: the deployed copy was 130 lines and one feature behind HEAD.

  This script makes the one-time switch. It:
    - checks the repo is on a local drive (RemoteSigned refuses a .ps1 on a
      UNC path such as \\wsl.localhost\...),
    - checks claude.exe is where you say it is,
    - checks the three things the launcher itself needs at run time -- python
      with sqlite3, a CCR data directory, a reachable gateway -- and prints
      what is missing together with the command that fixes it,
    - removes PATH entries that hold an old copy of the launcher,
    - adds this repo's windows\ directory,
    - sets CCR_CLAUDE_EXE.

  Nothing is written until -Apply is given. Without it the script prints the
  plan and exits, so you can read the diff first.

.PARAMETER RepoPath
  The repo root. Defaults to the parent of this script's directory.

.PARAMETER ClaudeExe
  A claude.exe, or a directory containing one. Defaults to the current
  CCR_CLAUDE_EXE if set, else a claude.exe already on PATH.

.PARAMETER Apply
  Write the changes. Without it, only a plan is printed.

.PARAMETER NoBackup
  Skip writing the backup file. Not recommended: the backup is what makes the
  PATH change reversible.

.PARAMETER Alias
  Also install a .cmd under this name, so the launcher can be called something
  other than ccr-claude. The alias forwards to ccr-claude.ps1; state
  (last profile, overlay, backups) stays under ccr-claude either way.

.PARAMETER SkipChecks
  Do not probe the run-time prerequisites (python, CCR data dir, gateway).
  You still have to start CCR and add a provider before the launcher works;
  this only stops the installer from reporting it.

.EXAMPLE
  .\install.ps1
  # shows what would change, touches nothing

.EXAMPLE
  .\install.ps1 -ClaudeExe 'C:\path\to\claude' -Apply

.EXAMPLE
  .\install.ps1 -ClaudeExe 'C:\path\to\claude' -Alias myclaude -Apply

.EXAMPLE
  irm https://example/install.ps1 | iex
  # piped in, there is no file on disk and $PSScriptRoot is empty -- pass
  # -RepoPath explicitly. Worth knowing before you publish an irm|iex line:
  # the script refuses with that instruction instead of binding an empty path.
#>
[CmdletBinding()]
param(
    [string]$RepoPath,
    [string]$ClaudeExe,
    [switch]$Apply,
    [switch]$NoBackup,
    [string]$Alias,
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'

function Say([string]$Msg) { Write-Host $Msg }
function Note([string]$Msg) { Write-Host "  $Msg" }
function Warn([string]$Msg) { Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Bad([string]$Msg) { Write-Host "ccr-claude: $Msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- repo 检查
# $PSScriptRoot is empty when the script did not come from a file -- `irm ... |
# iex`, or a scriptblock built from text. Split-Path -Parent '' throws
# ParameterBindingValidationException before any of our messages can run, so
# say what to pass instead of failing at a binding error the user cannot read.
if (-not $RepoPath) {
    if (-not $PSScriptRoot) {
        Bad ("cannot locate the repo: this script was piped in, so there is no script " +
             "directory. Pass the repo root explicitly, e.g. -RepoPath 'C:\tools\ccr-claude'.")
    }
    $RepoPath = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    Bad "repo not found: $RepoPath"
}
# Provider-qualified paths: Resolve-Path returns
# `Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\...`, and both the
# written and the reported form need to be plain. Without this, a UNC check
# against the string never fires.
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
$WinDir = Join-Path $RepoPath 'windows'
$Ps1 = Join-Path $WinDir 'ccr-claude.ps1'
$Cmd = Join-Path $WinDir 'ccr-claude.cmd'
foreach ($f in @($Ps1, $Cmd)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Bad "missing $f -- is $RepoPath really the ccr-claude repo?"
    }
}

# RemoteSigned refuses to run a .ps1 from a UNC path with
# `SecurityError: UnauthorizedAccess` (measured: \\wsl.localhost\...). Putting
# such a path on PATH would produce a working-looking install that fails at
# launch, so refuse here instead.
if ($WinDir.StartsWith('\\')) {
    Bad ("$WinDir is a UNC path. PowerShell's RemoteSigned policy will refuse to run a .ps1 from there. " +
         "Clone the repo onto a local drive and run this script from that copy.")
}

# ---------------------------------------------------------------- exe 检查
if (-not $ClaudeExe) {
    if ($env:CCR_CLAUDE_EXE) { $ClaudeExe = $env:CCR_CLAUDE_EXE }
    else {
        $onPath = Get-Command claude -ErrorAction SilentlyContinue
        if ($onPath) { $ClaudeExe = $onPath.Source }
    }
}
if (-not $ClaudeExe) {
    Bad "cannot find claude.exe. Pass -ClaudeExe <exe or its directory>."
}
if (Test-Path -LiteralPath $ClaudeExe -PathType Container) {
    $hit = Get-ChildItem -LiteralPath $ClaudeExe -Filter 'claude*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.exe', '.cmd', '.bat' } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $hit) { Bad "no claude* executable in $ClaudeExe" }
    $ExeDir = (Resolve-Path -LiteralPath $ClaudeExe).ProviderPath
    $ExeFile = $hit.FullName
}
elseif (Test-Path -LiteralPath $ClaudeExe -PathType Leaf) {
    $ExeFile = (Resolve-Path -LiteralPath $ClaudeExe).ProviderPath
    $ExeDir = Split-Path -Parent $ExeFile
}
else {
    Bad "CCR_CLAUDE_EXE/claude.exe not found: $ClaudeExe"
}

# ---------------------------------------------------------------- 前置检查
# The launcher reads CCR's SQLite database through python (PowerShell has no
# SQLite), so a machine can install cleanly and still fail on first launch with
# `no python on PATH`. These are warnings, not errors: installing before CCR is
# configured is a legitimate order of operations, and `Bad` here would also
# break the dry run. They are repeated in the plan below, and each names the
# command that fixes it -- "missing python" alone sends people to the Store
# stub, which Find-Python deliberately skips.
#
# Find-PythonForCheck duplicates Find-Python from ccr-claude.ps1 on purpose:
# the launcher is a script, not a module, and dot-sourcing it would run it. Two
# copies that can drift is the cost of keeping the launcher runnable on its own.
# If the launcher's rule changes, change this one too -- the Windows job in
# check.yml parses both files but cannot compare their meaning.
function Find-PythonForCheck {
    foreach ($n in @('python', 'python3', 'py')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if (-not $c -or -not $c.Source) { continue }
        # Same WindowsApps exclusion as the launcher: those are Store stubs that
        # open the Store and exit 9009 without running anything.
        if ($c.Source -like '*\WindowsApps\*') { continue }
        $probe = & $c.Source -c 'import sqlite3; print(1)' 2>$null
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -eq '1') { return $c.Source }
    }
    return $null
}

function Find-CcrDirForCheck {
    if ($env:CCR_DIR -and (Test-Path -LiteralPath (Join-Path $env:CCR_DIR 'config.sqlite'))) {
        return $env:CCR_DIR
    }
    $candidates = @()
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'claude-code-router') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'claude-code-router') }
    $candidates += (Join-Path $HOME '.claude-code-router')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'config.sqlite'))) { return $c }
    }
    return $null
}

$PrereqNotes = @()   # each item: @{ Level; Text }
$PythonExe = $null
$CcrDir = $null
$GatewayOk = $false

if (-not $SkipChecks) {
    $PythonExe = Find-PythonForCheck
    if ($PythonExe) {
        $PrereqNotes += @{ Level = 'ok'; Text = "python with sqlite3: $PythonExe" }
    }
    else {
        $PrereqNotes += @{ Level = 'warn'; Text = "python with sqlite3 not found -- the launcher cannot read CCR's database without it." }
        $PrereqNotes += @{ Level = 'fix';  Text = "winget install Python.Python.3.12   (then open a new terminal)" }
    }

    $CcrDir = Find-CcrDirForCheck
    if ($CcrDir) {
        $PrereqNotes += @{ Level = 'ok'; Text = "CCR data dir: $CcrDir" }
    }
    else {
        $PrereqNotes += @{ Level = 'warn'; Text = "no CCR data dir (needs config.sqlite) -- install and run CCR Desktop first." }
        $PrereqNotes += @{ Level = 'fix';  Text = "https://github.com/musistudio/claude-code-router/releases" }
    }

    # Probe the gateway only when there is a config to read a port from, and
    # never fail on it: an unreachable gateway is the normal state before the
    # user starts CCR, and the launcher has --skip-check for the same reason.
    # The port lives in the same SQLite database, so only ask python for it when
    # python exists. The snippet is a single-quoted here-string so PowerShell
    # does not expand `$` inside it, and the closing `'@` must sit at column 0.
    if ($CcrDir -and $PythonExe) {
        $gwPort = 3456
        $PortCode = @'
import json, sqlite3, sys
try:
    con = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
    row = con.execute("select value_json from app_config where key='default'").fetchone()
    cfg = json.loads(row[0]) if row else {}
    gw = cfg.get('gateway') or {}
    print(gw.get('port') or cfg.get('PORT') or 3456)
except Exception:
    print(3456)
'@
        try {
            # Temp file, not a pipe: `$Code | python -` goes through
            # $OutputEncoding, and a GB2312 session corrupts the text. Same
            # reason as the launcher's Invoke-CcrPy.
            $portTmp = Join-Path ([IO.Path]::GetTempPath()) ("ccr-install-{0}.py" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($portTmp, $PortCode, (New-Object Text.UTF8Encoding($false)))
            try {
                $cfgText = & $PythonExe $portTmp (Join-Path $CcrDir 'config.sqlite') 2>$null
            }
            finally {
                Remove-Item -LiteralPath $portTmp -Force -ErrorAction SilentlyContinue
            }
            if ("$cfgText".Trim() -match '^\d+$') { $gwPort = [int]"$cfgText".Trim() }
        }
        catch { }
        $gwUrl = "http://127.0.0.1:$gwPort"
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri "$gwUrl/health" -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
                $GatewayOk = $true
                $PrereqNotes += @{ Level = 'ok'; Text = "gateway reachable: $gwUrl" }
            }
        }
        catch { }
        if (-not $GatewayOk) {
            $PrereqNotes += @{ Level = 'warn'; Text = "CCR gateway not reachable at $gwUrl -- start CCR before using the launcher." }
            $PrereqNotes += @{ Level = 'fix';  Text = "open CCR Desktop, enable the gateway, confirm the Claude Code agent" }
        }
    }
}

# ---------------------------------------------------------------- 算 PATH 差异
# Compare case-insensitively and ignoring a trailing backslash: Windows paths
# are case-insensitive, and "C:\a\" and "C:\a" are the same directory.
function Normalize-PathEntry([string]$p) {
    if (-not $p) { return '' }
    return $p.Trim().TrimEnd('\').ToLowerInvariant()
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @()
if ($userPath) { $entries = $userPath.Split(';') }

$keep = @()
$drop = @()
$alreadyHas = $false
foreach ($e in $entries) {
    if (-not $e.Trim()) { continue }
    if ((Normalize-PathEntry $e) -eq (Normalize-PathEntry $WinDir)) {
        $alreadyHas = $true
        $keep += $e
        continue
    }
    # 旧的手抄目录：里面还躺着 ccr-claude.ps1/.cmd，但不在这个仓库里。
    $isStale = $false
    try {
        if (Test-Path -LiteralPath $e -PathType Container) {
            $dup = @('ccr-claude.ps1', 'ccr-claude.cmd') |
                Where-Object { Test-Path -LiteralPath (Join-Path $e $_) -PathType Leaf }
            if ($dup.Count -gt 0) { $isStale = $true }
        }
    }
    catch { }
    if ($isStale) { $drop += $e } else { $keep += $e }
}

$newEntries = @($WinDir) + $keep
$newPath = ($newEntries -join ';')
$oldExeVar = $env:CCR_CLAUDE_EXE
$exeUnchanged = ((Normalize-PathEntry $oldExeVar) -eq (Normalize-PathEntry $ExeDir))

# ---------------------------------------------------------------- 别名
# 一个 .cmd 就是一份别名：它靠 %~n0 把调用名转交给启动器，内容与文件名叫
# 什么无关。放在同一个 windows 目录里，PATH 已经指向它，不必再改 PATH。
if ($Alias) {
    if ($Alias -notmatch '^[A-Za-z0-9_-]+$') {
        Bad "-Alias takes letters, digits, '-' and '_' only, got `"$Alias`""
    }
    if ($Alias -ieq 'ccr-claude') {
        Bad "-Alias ccr-claude is the existing name; drop -Alias"
    }
}
$AliasPath = if ($Alias) { Join-Path $WinDir "$Alias.cmd" } else { $null }
$AliasExists = $AliasPath -and (Test-Path -LiteralPath $AliasPath -PathType Leaf)

# ---------------------------------------------------------------- 计划
Say "ccr-claude install"
Say ''
Say "repo     $RepoPath"
Say "launcher $Ps1"
Say "exe      $ExeFile"
Say "exe dir  $ExeDir"
Say ''
if ($SkipChecks) {
    Say "Preflight skipped (-SkipChecks)."
} elseif ($PrereqNotes.Count -gt 0) {
    Say "Preflight (what the launcher needs at run time):"
    foreach ($n in $PrereqNotes) {
        switch ($n.Level) {
            'ok'   { Note "ok   $($n.Text)" }
            'warn' { Warn $n.Text }
            'fix'  { Note "     fix: $($n.Text)" }
        }
    }
}
Say ''
Say "Plan for the user PATH:"
if ($alreadyHas) {
    Note "already present, kept: $WinDir"
} else {
    Note "add: $WinDir"
}
if ($drop.Count) {
    foreach ($d in $drop) { Note "remove (old copy of this launcher): $d" }
} else {
    Note "no old copies of the launcher found on PATH"
}
Say ''
Say "Plan for CCR_CLAUDE_EXE:"
if ($exeUnchanged) {
    Note "already set to $ExeDir"
} else {
    if ($oldExeVar) { Note "change: `"$oldExeVar`" -> `"$ExeDir`"" }
    else { Note "set: $ExeDir" }
}
if ($Alias) {
    Say ''
    Say "Plan for the alias:"
    if ($AliasExists) { Note "overwrite: $AliasPath" }
    else { Note "create: $AliasPath" }
    Note "call it with: $Alias"
}

$changes = (-not $alreadyHas) -or ($drop.Count -gt 0) -or (-not $exeUnchanged) -or [bool]$Alias
if (-not $changes) {
    Say ''
    Say "Nothing to do -- already installed."
    exit 0
}
if (-not $Apply) {
    Say ''
    Say "Dry run. Re-run with -Apply to write these changes."
    Say "A backup of the current values is written first unless -NoBackup is given."
    exit 0
}

# ---------------------------------------------------------------- 备份
if (-not $NoBackup) {
    $stateDir = Join-Path $env:LOCALAPPDATA 'ccr-claude'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $stateDir "install-backup-$stamp.txt"
    $lines = @(
        "# ccr-claude install.ps1 backup, $stamp"
        "# Restore by pasting these two lines into PowerShell:"
        "#   [Environment]::SetEnvironmentVariable('Path', <the PATH line below, unquoted>, 'User')"
        "#   [Environment]::SetEnvironmentVariable('CCR_CLAUDE_EXE', <the CCR_CLAUDE_EXE line>, 'User')"
        ""
        "PATH=$userPath"
        "CCR_CLAUDE_EXE=$oldExeVar"
    )
    # Ascii, not UTF8: the file holds machine paths, and a BOM would end up
    # inside the value if someone pastes it back.
    Set-Content -LiteralPath $backup -Value $lines -Encoding Ascii
    Say ''
    Say "Backup written: $backup"
}

# ---------------------------------------------------------------- 写入
try {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    [Environment]::SetEnvironmentVariable('CCR_CLAUDE_EXE', $ExeDir, 'User')
}
catch {
    Bad "could not write the user environment: $($_.Exception.Message)"
}

if ($Alias) {
    # Copy this repo's .cmd, not a freshly invented one: the alias then has the
    # same forwarding, the same %~n0, and the same CCR_CLAUDE_PS1 fallback.
    $SrcCmd = Join-Path $WinDir 'ccr-claude.cmd'
    try {
        Copy-Item -LiteralPath $SrcCmd -Destination $AliasPath -Force
    }
    catch {
        Bad "could not write ${AliasPath}: $($_.Exception.Message)"
    }
    Say "Alias written: $AliasPath"
}

Say ''
Say "Done. Open a new terminal, then:"
Say "  where ccr-claude"
Say "  ccr-claude --list-profiles"
if ($Alias) {
    Say "  where $Alias"
    Say "  $Alias --help"
}
Say ''
Warn "The current window keeps the old PATH; a new terminal is required."
