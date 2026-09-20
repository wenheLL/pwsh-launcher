#requires -version 5
<#
  通用快捷方式生成器：给一组「目标 + 参数」就能生成 .lnk，重复执行覆盖同名文件。

  本工具的现成用法：

  1) 启动器本体（图形界面）
  # 用 conhost --headless 当宿主：这样不会因为「默认终端 = Windows Terminal」
  # 而多出一个隐藏的终端窗口（任务栏「终端」组的计数会白白 +1）。
  .\create-shortcut.ps1 `
    -Name 'pwsh 启动器' `
    -Target "$env:SystemRoot\System32\conhost.exe" `
    -Arguments "--headless `"$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe`" -NoProfile -STA -ExecutionPolicy Bypass -File `"$PWD\pwsh-launcher.ps1`"" `
    -WorkingDirectory $PWD -Description '常用文件夹 + 预填命令的 pwsh 启动器' `
    -Icon (Join-Path $PWD 'icon.ico')

  2) 某个项目专用的「预填终端」（等价于在启动器里双击该项目）
  .\create-shortcut.ps1 `
    -Name 'MyProject Shell' `
    -Target "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe" `
    -Arguments "-NoLogo -NoExit -File `"$PWD\open-shell.ps1`" -Directory `"C:\path\to\project`" -Command 'npm run dev' -WindowTitle 'MyProject'" `
    -WorkingDirectory 'C:\path\to\project'

  注意：-Arguments 里带空格的路径要自己补引号；这串会原样写进 .lnk，不会再被解析一次。
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Target,
  [string]$Arguments = '',
  [string]$WorkingDirectory = '',
  [string]$Icon = '',
  [string]$Description = '',
  [string]$ShortcutDir = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Target)) {
  throw "目标不存在: $Target"
}
if (-not (Test-Path -LiteralPath $ShortcutDir)) {
  throw "快捷方式目录不存在: $ShortcutDir"
}
if ($WorkingDirectory -and -not (Test-Path -LiteralPath $WorkingDirectory)) {
  throw "工作目录不存在: $WorkingDirectory"
}

$linkPath = Join-Path $ShortcutDir "$Name.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($linkPath)
$shortcut.TargetPath = $Target
$shortcut.Arguments = $Arguments
if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
if ($Description) { $shortcut.Description = $Description }
$shortcut.WindowStyle = 1
if ($Icon -and (Test-Path -LiteralPath $Icon)) {
  $shortcut.IconLocation = "$Icon,0"
}
$shortcut.Save()

Write-Host "已创建快捷方式: $linkPath" -ForegroundColor Green
Write-Host "  -> $Target $Arguments"
