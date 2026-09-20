#requires -version 7
<#
.SYNOPSIS
  把启动器设成「登录后自动启动」，或者取消。

.DESCRIPTION
  用「启动」文件夹里的快捷方式实现：
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
  为什么不用注册表 Run 键：快捷方式是看得见摸得着的一个文件 —— 卸载就是删掉它，
  而且任务管理器 →「启动」标签里也能直接禁用它，不用记注册表路径。
  默认最小化启动（不然每次登录都会有个窗口跳到脸前）；想让它登录后直接显示窗口就加 -ShowWindow。

.EXAMPLE
  pwsh -NoProfile -File .\install-autostart.ps1              # 装上（最小化启动）
  pwsh -NoProfile -File .\install-autostart.ps1 -ShowWindow  # 装上（直接显示窗口）
  pwsh -NoProfile -File .\install-autostart.ps1 -Uninstall   # 取消
#>
[CmdletBinding()]
param(
  [switch]$Uninstall,
  [switch]$ShowWindow
)

$ErrorActionPreference = 'Stop'

$tool = $PSScriptRoot
$startupDir = [Environment]::GetFolderPath('Startup')
$linkPath = Join-Path $startupDir 'pwsh 启动器.lnk'

if ($Uninstall) {
  if (Test-Path -LiteralPath $linkPath) {
    Remove-Item -LiteralPath $linkPath -Force
    Write-Host "已取消开机自启动（删掉了 $linkPath）" -ForegroundColor Green
  } else {
    Write-Host '本来就没装，无需处理。' -ForegroundColor Yellow
  }
  return
}

if (-not (Test-Path -LiteralPath $startupDir)) { throw "找不到「启动」文件夹：$startupDir" }
foreach ($f in 'pwsh-launcher.ps1', 'icon.ico', 'create-shortcut.ps1') {
  if (-not (Test-Path -LiteralPath (Join-Path $tool $f))) {
    throw "工具目录里缺少 $f —— 请从完整的 pwsh-launcher 目录运行本脚本。"
  }
}

$pwshExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
$arguments = "--headless `"$pwshExe`" -NoProfile -STA -ExecutionPolicy Bypass -File `"$tool\pwsh-launcher.ps1`""
if (-not $ShowWindow) { $arguments += ' -StartMinimized' }

& (Join-Path $tool 'create-shortcut.ps1') `
  -Name 'pwsh 启动器' `
  -Target (Join-Path $env:SystemRoot 'System32\conhost.exe') `
  -Arguments $arguments `
  -WorkingDirectory $tool `
  -Description '登录后自动启动的 pwsh 启动器' `
  -Icon (Join-Path $tool 'icon.ico') `
  -ShortcutDir $startupDir

Write-Host ''
Write-Host '已设为登录后自动启动。' -ForegroundColor Green
Write-Host "  快捷方式：$linkPath"
if ($ShowWindow) {
  Write-Host '  启动方式：登录后直接显示窗口'
} else {
  Write-Host '  启动方式：最小化启动（点一下任务栏图标就出来）'
}
Write-Host '  取消：install-autostart.ps1 -Uninstall，或在任务管理器 →「启动」里禁用'
