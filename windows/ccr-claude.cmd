@echo off
REM Runs ccr-claude.ps1 under the machine's RemoteSigned policy (no -ExecutionPolicy
REM flag needed: this file lives on local NTFS and has no Zone.Identifier stream).
REM Everything after the script name is forwarded to Claude Code.
setlocal
set "SCRIPT=%~dp0ccr-claude.ps1"
if not exist "%SCRIPT%" (
  >&2 echo ccr-claude: missing %SCRIPT%
  exit /b 1
)
powershell.exe -NoProfile -NoLogo -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
