param()

$ErrorActionPreference = 'Stop'

$signature = @'
using System;
using System.Runtime.InteropServices;

public static class DingjiaiConsoleMode {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
}
'@

Add-Type -TypeDefinition $signature

$stdin = [DingjiaiConsoleMode]::GetStdHandle(-10)
if ($stdin -eq [IntPtr]::Zero -or $stdin -eq [IntPtr](-1)) {
    exit 0
}

$mode = 0
if (-not [DingjiaiConsoleMode]::GetConsoleMode($stdin, [ref] $mode)) {
    exit 0
}

$enableQuickEditMode = 0x0040
$enableExtendedFlags = 0x0080
$nextMode = ($mode -bor $enableExtendedFlags) -band (-bnot $enableQuickEditMode)

if ($nextMode -ne $mode -and -not [DingjiaiConsoleMode]::SetConsoleMode($stdin, $nextMode)) {
    throw 'failed to disable QuickEdit mode'
}
