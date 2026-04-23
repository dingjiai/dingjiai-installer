@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001>nul
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "BACKEND_PS1=%SCRIPT_DIR%win.ps1"
set "WINDOW_COLS=96"
set "WINDOW_LINES=30"
call :prepare_window

:main
cls
echo ================================================
echo  dingjiai 安装器
echo ================================================
echo.
echo  当前窗口是正式安装界面。
echo  后续菜单、检测、下载和安装都会在这里完成。
echo.
echo [1] 安装 Claude 和依赖
echo [2] 更新 Claude 和依赖
echo [3] 卸载 Claude 和依赖
echo [0] 退出
echo.
set /p choice=请选择一个选项（输入数字后按回车）：

if "%choice%"=="1" goto install
if "%choice%"=="2" goto update
if "%choice%"=="3" goto uninstall
if "%choice%"=="0" goto end

echo.
echo 无效选项，请重新输入。
pause
goto main

:install
cls
echo 你选择了：安装 Claude 和依赖
echo.
echo 为保证后续安装顺利，当前会先处理：
echo - winget
echo - Git
echo.
echo Claude 与其他增强工具将在后续版本接入。
echo.
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%BACKEND_PS1%" -Action install
echo.
pause
goto main

:update
cls
echo 更新功能正在准备中，当前版本暂未开放。
echo.
pause
goto main

:uninstall
cls
echo 卸载功能正在准备中，当前版本暂未开放。
echo.
pause
goto main

:end
echo.
echo 已退出安装器。
endlocal
exit /b 0

:prepare_window
title dingjiai 安装器
mode con cols=%WINDOW_COLS% lines=%WINDOW_LINES% >nul
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$cols=[int]$env:WINDOW_COLS; $lines=[int]$env:WINDOW_LINES; try { $raw=$Host.UI.RawUI; $buffer=$raw.BufferSize; if($buffer.Width -lt $cols){$buffer.Width=$cols}; $buffer.Height=$lines; $raw.BufferSize=$buffer; $window=$raw.WindowSize; $window.Width=$cols; $window.Height=$lines; $raw.WindowSize=$window } catch {}; Add-Type -Namespace Dingjiai -Name NativeMethods -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr hWnd, int nIndex); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr hWnd, int nIndex, int dwNewLong); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetSystemMenu(System.IntPtr hWnd, bool bRevert); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DeleteMenu(System.IntPtr hMenu, uint uPosition, uint uFlags);' -ErrorAction SilentlyContinue; try { $hwnd=[Dingjiai.NativeMethods]::GetConsoleWindow(); if($hwnd -ne [IntPtr]::Zero){ $style=[Dingjiai.NativeMethods]::GetWindowLong($hwnd,-16); $style = $style -band (-bnot 0x00040000) -band (-bnot 0x00010000); [void][Dingjiai.NativeMethods]::SetWindowLong($hwnd,-16,$style); [void][Dingjiai.NativeMethods]::SetWindowPos($hwnd,[IntPtr]::Zero,0,0,0,0,0x0027); $menu=[Dingjiai.NativeMethods]::GetSystemMenu($hwnd,$false); if($menu -ne [IntPtr]::Zero){ [void][Dingjiai.NativeMethods]::DeleteMenu($menu,0xF000,0); [void][Dingjiai.NativeMethods]::DeleteMenu($menu,0xF030,0) } } } catch {}" >nul 2>nul
exit /b 0
