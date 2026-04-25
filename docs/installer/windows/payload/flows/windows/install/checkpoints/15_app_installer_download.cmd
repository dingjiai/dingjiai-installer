@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "DOWNLOAD_HELPER=%~dp0..\..\..\..\lib\windows\download.ps1"
if not exist "%DOWNLOAD_HELPER%" (
  echo download checkpoint helper missing.
  exit /b 20
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DOWNLOAD_HELPER%" -FlowName "install" -CheckpointName "app-installer-download" -ArtifactKind "AppInstaller" -ArtifactName "app-installer.msixbundle" %*
exit /b %errorlevel%
