@echo off
REM Thin shell for the PowerShell launcher, runnable under the machine's
REM RemoteSigned policy (no -ExecutionPolicy flag needed: this file lives on
REM local NTFS and has no Zone.Identifier stream). Everything after the script
REM name is forwarded to Claude Code.
REM
REM The launcher is found two ways, so this file can be copied to any name:
REM   1. a ccr-claude.ps1 sitting next to this file
REM   2. whatever CCR_CLAUDE_PS1 points at
REM That is what lets a user call it `myclaude`: copy this .cmd to myclaude.cmd,
REM and it still finds the launcher.
setlocal
set "HERE=%~dp0"

if defined CCR_CLAUDE_PS1 (
  set "SCRIPT=%CCR_CLAUDE_PS1%"
) else if exist "%HERE%ccr-claude.ps1" (
  set "SCRIPT=%HERE%ccr-claude.ps1"
) else (
  >&2 echo %~nx0: no launcher found. Put ccr-claude.ps1 next to this file, or set CCR_CLAUDE_PS1.
  exit /b 1
)

if not exist "%SCRIPT%" (
  >&2 echo %~nx0: missing %SCRIPT%
  exit /b 1
)

REM Tell the launcher what it was called as: under -File it would only see the
REM .ps1's own path. %~n0 is this file's name without the extension.
set "CCR_INVOKED_AS=%~n0"
powershell.exe -NoProfile -NoLogo -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
