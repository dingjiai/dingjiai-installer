@echo off
chcp 65001 >NUL
setlocal EnableExtensions

call "%~dp0..\flows\windows\update\entry.cmd"
exit /b %errorlevel%
