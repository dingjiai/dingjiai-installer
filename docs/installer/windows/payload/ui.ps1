param(
    [ValidateSet('main', 'install', 'update', 'uninstall')]
    [string] $Page = 'main'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-BlankLine {
    Write-Host ''
}

function Write-PanelLine {
    param([string] $Text)
    Write-Host ('       ' + $Text)
}

function Write-CenteredLine {
    param([string] $Text)
    Write-Host ('              ' + $Text)
}

Write-BlankLine
Write-BlankLine
Write-PanelLine '______________________________________________________________'
Write-BlankLine

switch ($Page) {
    'main' {
        Write-CenteredLine '           dingjiai installer'
        Write-BlankLine
        Write-CenteredLine '启动阶段已完成，管理员 CMD 主窗口已接管。'
        Write-BlankLine
        Write-CenteredLine '当前菜单已接入 flow 骨架，checkpoint 仍是占位。'
        Write-BlankLine
        Write-CenteredLine '[1] 安装 Claude 和依赖       占位 flow'
        Write-CenteredLine '[2] 更新 Claude 和依赖       占位 flow'
        Write-CenteredLine '[3] 卸载 Claude 和依赖       占位 flow'
        Write-BlankLine
        Write-CenteredLine '[0] 退出'
    }
    'install' {
        Write-CenteredLine '           安装 Claude 和依赖'
        Write-BlankLine
        Write-CenteredLine '当前会进入安装 flow 骨架；不会修改系统。'
    }
    'update' {
        Write-CenteredLine '           更新 Claude 和依赖'
        Write-BlankLine
        Write-CenteredLine '当前会进入更新 flow 骨架；不会修改系统。'
    }
    'uninstall' {
        Write-CenteredLine '           卸载 Claude 和依赖'
        Write-BlankLine
        Write-CenteredLine '当前会进入卸载 flow 骨架；不会修改系统。'
    }
}

Write-PanelLine '______________________________________________________________'
Write-BlankLine
