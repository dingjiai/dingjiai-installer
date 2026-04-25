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
        Write-CenteredLine '当前菜单仍是占位，安装 / 更新 / 卸载尚未接入。'
        Write-BlankLine
        Write-CenteredLine '[1] 安装 Claude 和依赖       未接入'
        Write-CenteredLine '[2] 更新 Claude 和依赖       未接入'
        Write-CenteredLine '[3] 卸载 Claude 和依赖       未接入'
        Write-BlankLine
        Write-CenteredLine '[0] 退出'
    }
    'install' {
        Write-CenteredLine '           安装 Claude 和依赖'
        Write-BlankLine
        Write-CenteredLine '当前任务仍是占位，真实安装流程尚未接入。'
    }
    'update' {
        Write-CenteredLine '           更新 Claude 和依赖'
        Write-BlankLine
        Write-CenteredLine '当前任务仍是占位，真实更新流程尚未接入。'
    }
    'uninstall' {
        Write-CenteredLine '           卸载 Claude 和依赖'
        Write-BlankLine
        Write-CenteredLine '当前任务仍是占位，真实卸载流程尚未接入。'
    }
}

Write-PanelLine '______________________________________________________________'
Write-BlankLine
