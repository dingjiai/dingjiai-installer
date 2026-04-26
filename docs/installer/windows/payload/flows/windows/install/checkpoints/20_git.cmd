@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "RUNNER=%~dp0..\..\..\..\lib\windows\checkpoint_runner.cmd"
set "GIT_HELPER=%~dp0..\..\..\..\lib\windows\git.ps1"
if not exist "%RUNNER%" (
  echo checkpoint runner missing.
  exit /b 20
)

set "DINGJIAI_CHECKPOINT_HELPER=%GIT_HELPER%"
set "DINGJIAI_CHECKPOINT_FLOW=install"
set "DINGJIAI_CHECKPOINT_NAME=git"
call "%RUNNER%" %*
exit /b %errorlevel%
