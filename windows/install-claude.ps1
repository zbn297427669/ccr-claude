#Requires -Version 5.1
<#
.SYNOPSIS
  Install the Claude Code CLI from an already-downloaded exe, with no network.

.DESCRIPTION
  `claude install` needs the network twice: once to resolve the version, and
  again to check installation status before it does anything. On a machine that
  cannot reach downloads.claude.ai it fails at "Checking installation status..."
  with ECONNREFUSED or a 10s timeout -- even when the exe is already on disk.
  `--force` makes it worse, not better: it skips the local-cache check and
  insists on downloading.

  What `install` actually does is put the binary in two places and register it
  on PATH. This script does that directly from the file you already have, so it
  works with the network switched off.

  Everything is verified before anything is written:
    - the file must be a Windows executable (PE "MZ" header), which catches the
      HTML error page people get when a download is blocked mid-flight;
    - its SHA256 must match the release's sha256sums.txt, or -ExpectedHash.

  Nothing is written until -Apply is given.

.PARAMETER Exe
  The downloaded claude-<version>-win32-<arch>.exe. The version is read from
  this name, because that is also the name `install` uses for its cache.

.PARAMETER ExpectedHash
  A SHA256 to check against, instead of downloading sha256sums.txt. Needed when
  there is no network at all, which is the case this script exists for.

.PARAMETER SumsUrl
  Where to fetch sha256sums.txt. Defaults to the mirror's per-tag URL.

.PARAMETER SkipHashCheck
  Do not verify the hash. Not recommended: the hash is the only thing that
  says the file is the file.

.PARAMETER Cache
  Also copy the binary to %USERPROFILE%\.local\share\claude\versions\<ver>, the
  place `claude install` looks first. Lets a later `claude install <ver>`
  succeed offline. Costs another copy unless -HardLink is given.

.PARAMETER HardLink
  Use a hard link instead of a second copy for -Cache. Both paths must be on
  the same volume.

.PARAMETER Apply
  Write the changes. Without it, only a plan is printed.

.EXAMPLE
  .\install-claude.ps1 -Exe .\claude-2.1.316-win32-x64.exe
  # prints the plan, downloads sha256sums.txt, checks the hash, writes nothing

.EXAMPLE
  .\install-claude.ps1 -Exe .\claude-2.1.316-win32-x64.exe -Apply

.EXAMPLE
  .\install-claude.ps1 -Exe .\claude-2.1.316-win32-x64.exe `
      -ExpectedHash e896a9d8da519353a49bf69ca4a695ba7e09067752687c675b3969041e632d52 -Apply
  # fully offline: no network at any point

.EXAMPLE
  .\install-claude.ps1 -Exe .\claude-2.1.316-win32-x64.exe -Cache -HardLink -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Exe,
    [string]$ExpectedHash,
    [string]$SumsUrl,
    [switch]$SkipHashCheck,
    [switch]$Cache,
    [switch]$HardLink,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Say([string]$Msg) { Write-Host $Msg }
function Note([string]$Msg) { Write-Host "  $Msg" }
function Warn([string]$Msg) { Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Bad([string]$Msg) { Write-Host "install-claude: $Msg" -ForegroundColor Red; exit 1 }

if ($HardLink -and -not $Cache) { Bad "-HardLink only makes sense with -Cache." }

# ---------------------------------------------------------------- 文件检查
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    Bad "not found: $Exe"
}
$Exe = (Resolve-Path -LiteralPath $Exe).ProviderPath
$ExeName = [IO.Path]::GetFileName($Exe)

# claude-<version>-<platform>.exe. The platform is part of the name so a
# darwin or linux build cannot be installed by mistake on Windows.
$m = [regex]::Match($ExeName, '^claude-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-(win32-(?:x64|arm64))\.exe$')
if (-not $m.Success) {
    Bad ("unexpected file name: $ExeName`n" +
         "         expected claude-<version>-win32-x64.exe (or win32-arm64), as published by the release.")
}
$Version = $m.Groups[1].Value
$Platform = $m.Groups[2].Value
$CacheName = "claude-$Version-$Platform.exe"

# A blocked download usually still writes *something* -- an HTML error page with
# a 200, or a truncated file. Neither starts with MZ, and neither is caught by
# a size check. Read the first two bytes before trusting anything else.
$fs = [IO.File]::OpenRead($Exe)
try {
    $magic = New-Object byte[] 2
    $read = $fs.Read($magic, 0, 2)
}
finally { $fs.Dispose() }
if ($read -ne 2 -or $magic[0] -ne 0x4D -or $magic[1] -ne 0x5A) {
    $preview = ''
    try {
        $preview = (Get-Content -LiteralPath $Exe -TotalCount 2 -Encoding UTF8) -join ' '
    }
    catch { }
    Bad ("$ExeName is not a Windows executable (no MZ header).`n" +
         "         A blocked download often saves an HTML error page instead.`n" +
         ("         starts with: " + $preview.Substring(0, [Math]::Min(90, $preview.Length))))
}

$SizeMB = [Math]::Round((Get-Item -LiteralPath $Exe).Length / 1MB)
Say "Claude Code CLI $Version ($Platform), $SizeMB MB"
Say "  from $Exe"
Say ''

# ---------------------------------------------------------------- 哈希
# The hash is the only thing that distinguishes "the file I meant" from "a file
# with the right name". Fetch the release's list by default; -ExpectedHash is
# the offline route, which is the situation this script was written for.
$wantHash = ''
if ($SkipHashCheck) {
    Warn "hash check skipped (-SkipHashCheck)"
}
elseif ($ExpectedHash) {
    $wantHash = $ExpectedHash.Trim().ToLowerInvariant()
    if ($wantHash -notmatch '^[0-9a-f]{64}$') { Bad "-ExpectedHash must be 64 hex characters, got `"$ExpectedHash`"" }
    Note "expected hash: $wantHash (from -ExpectedHash)"
}
else {
    if (-not $SumsUrl) {
        $SumsUrl = "https://github.com/ProjectAILeap/claude-code-releases/releases/download/v$Version/sha256sums.txt"
    }
    Note "fetching $SumsUrl"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri $SumsUrl -ErrorAction Stop
    }
    catch {
        Bad ("could not fetch sha256sums.txt: $($_.Exception.Message)`n" +
             "         Offline? Pass -ExpectedHash <64 hex chars> instead, or -SkipHashCheck.")
    }
    # PowerShell 7 returns Byte[] here; 5.1 returns String. Splitting a byte
    # array on a newline yields the byte values rather than lines, which then
    # reads as "no entry for this file" -- a confusing failure for a correct URL.
    $sums = if ($resp.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($resp.Content)
    }
    else { [string]$resp.Content }
    # Format is "<hash>  <filename>" per line, as sha256sum writes it.
    $line = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($CacheName) + '\s*$' } | Select-Object -First 1)
    if (-not $line) {
        Bad "sha256sums.txt has no entry for $CacheName (wrong version or platform?)"
    }
    $wantHash = ($line -split '\s+')[0].ToLowerInvariant()
    Note "expected hash: $wantHash (from sha256sums.txt)"
}

if ($wantHash) {
    Note "computing SHA256 of $SizeMB MB ..."
    $gotHash = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($gotHash -ne $wantHash) {
        Bad ("hash mismatch`n" +
             "         expected $wantHash`n" +
             "         got      $gotHash`n" +
             "         The file is corrupt or not what it claims to be. Download it again.")
    }
    Note "hash OK"
}

# ---------------------------------------------------------------- 目标位置
$BinDir = Join-Path $env:USERPROFILE '.local\bin'
$BinExe = Join-Path $BinDir 'claude.exe'
$CacheDir = Join-Path $env:USERPROFILE '.local\share\claude\versions'
$CachePath = Join-Path $CacheDir $Version

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$norm = { param($p) if (-not $p) { '' } else { $p.Trim().TrimEnd('\').ToLowerInvariant() } }
$pathHas = ($userPath -split ';' | Where-Object { (& $norm $_) -eq (& $norm $BinDir) }).Count -gt 0

$existing = if (Test-Path -LiteralPath $BinExe) { (Get-FileHash -LiteralPath $BinExe -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
$sameFile = $existing -and $gotHash -and ($existing -eq (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant())

Say 'Plan:'
Note "install to  $BinExe"
if (-not $existing) {
    Note "            (nothing there now)"
}
elseif ($sameFile) {
    Note "            (already this exact file, will be skipped)"
}
else {
    Note "            (different file present, will be replaced -- back it up first if you care)"
}
if ($Cache) {
    Note "cache to    $CachePath  ($(if ($HardLink) { 'hard link' } else { 'copy' }))"
}
if ($pathHas) {
    Note "PATH        already contains $BinDir"
}
else {
    Note "PATH        add $BinDir"
}
Say ''

if (-not $Apply) {
    Say 'Dry run. Re-run with -Apply to write these changes.'
    exit 0
}

# ---------------------------------------------------------------- 写入
try {
    if (-not (Test-Path -LiteralPath $BinDir)) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    }
    if (-not $sameFile) {
        Copy-Item -LiteralPath $Exe -Destination $BinExe -Force
    }
    if ($sameFile) {
        Note "$BinExe already in place, nothing to copy"
    }
    else {
        Note "installed $BinExe"
    }

    if ($Cache) {
        if (-not (Test-Path -LiteralPath $CacheDir)) {
            New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        }
        if (Test-Path -LiteralPath $CachePath) { Remove-Item -LiteralPath $CachePath -Force }
        if ($HardLink) {
            New-Item -ItemType HardLink -Path $CachePath -Target $BinExe | Out-Null
            Note "cached $CachePath (hard link)"
        }
        else {
            Copy-Item -LiteralPath $Exe -Destination $CachePath -Force
            Note "cached $CachePath"
        }
    }

    if (-not $pathHas) {
        # Prepend: this is the directory the user's own claude should win from,
        # and it matches what the official installer does.
        $newPath = if ($userPath) { "$BinDir;$userPath" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Note "added $BinDir to the user PATH"
    }
}
catch {
    Bad "could not install: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- 验证
Say ''
$check = & $BinExe --version 2>&1
Say "Installed: $check"

if (-not $pathHas) {
    Say ''
    Warn "The current window keeps the old PATH; open a new terminal for 'claude' to resolve."
}

<#
Installation notes worth knowing:

  - `claude install <version>` still works later if the cache is populated
    (-Cache). It only reaches for the network when the version is not cached.
  - For Claude Code driven by ccr-claude, no /login is needed: the launcher
    supplies the gateway URL and a profile key. `claude` on its own still needs
    the official login -- the two commands coexist.
  - Auto-update: a hand-installed binary does not know it was installed
    natively, so it may try to check for updates. Set "autoUpdates": false in
    %USERPROFILE%\.claude.json to stop that.
#>
