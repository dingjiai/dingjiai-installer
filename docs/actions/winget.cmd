@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "ACTION=%~1"
if not defined ACTION set "ACTION=ensure"
if /I "%ACTION%"=="ensure" shift

set "HELPER=%~dp0winget.ps1"
if not exist "%HELPER%" (
  echo winget action helper missing.
  exit /b 20
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Action "%ACTION%" %*
exit /b %errorlevel%
