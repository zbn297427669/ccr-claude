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

.EXAMPLE
  .\install.ps1
  # shows what would change, touches nothing

.EXAMPLE
  .\install.ps1 -ClaudeExe 'C:\path\to\claude' -Apply
#>
[CmdletBinding()]
param(
    [string]$RepoPath,
    [string]$ClaudeExe,
    [switch]$Apply,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

function Say([string]$Msg) { Write-Host $Msg }
function Note([string]$Msg) { Write-Host "  $Msg" }
function Warn([string]$Msg) { Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Bad([string]$Msg) { Write-Host "ccr-claude: $Msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- repo 检查
if (-not $RepoPath) {
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

# ---------------------------------------------------------------- 计划
Say "ccr-claude install"
Say ''
Say "repo     $RepoPath"
Say "launcher $Ps1"
Say "exe      $ExeFile"
Say "exe dir  $ExeDir"
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

$changes = (-not $alreadyHas) -or ($drop.Count -gt 0) -or (-not $exeUnchanged)
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

Say ''
Say "Done. Open a new terminal, then:"
Say "  where ccr-claude"
Say "  ccr-claude --list-profiles"
Say ''
Warn "The current window keeps the old PATH; a new terminal is required."
