@echo off
chcp 65001 >NUL
setlocal EnableExtensions

call "%~dp0..\flows\windows\install\entry.cmd"
exit /b %errorlevel%
