#requires -version 7
<#
.SYNOPSIS
  打开一个新的 pwsh 7 窗口：切到指定目录，并把一条命令「敲」进命令行等你按回车。

.DESCRIPTION
  为什么不直接用 pwsh -Command 跑：那样命令立刻执行，你在按回车前没机会改它。
  这里把命令写进 PSReadLine 的输入缓冲区，光标停在该行末尾，按回车才真正执行。

  为什么必须走 OnIdle 事件：在 -Command / -File 执行期间，PSReadLine 的缓冲区还没建好，
  此时直接调 [Microsoft.PowerShell.PSConsoleReadLine]::Insert() 会抛
  "Object reference not set to an instance of an object"。挂到 PowerShell.OnIdle 上、
  等第一个提示符渲染完再插入，才真正生效（OnIdle 只触发一次）。

.EXAMPLE
  # 由 pwsh-launcher.ps1 调用；也可自己手动用：
  pwsh -NoLogo -NoExit -File .\open-shell.ps1 -Directory . -Command 'npm run dev'

.EXAMPLE
  # 换条命令、换个目录，同一个脚本都能用
  pwsh -NoLogo -NoExit -File .\open-shell.ps1 -Directory C:\work\other -Command 'npm test'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [string]$Directory,

  [Parameter(Position = 1)]
  [string]$Command = '',

  [string]$WindowTitle = ''
)

Set-Location -LiteralPath $Directory

if (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
  try { $Host.UI.RawUI.WindowTitle = $WindowTitle } catch { }
}

if ([string]::IsNullOrWhiteSpace($Command)) { return }

# 命令内容拼成字面量写进脚本块，避免事件动作在另一个作用域里取不到变量。
$literal = $Command.Replace("'", "''")
$insertOnIdle = [scriptblock]::Create(@"
try { [Microsoft.PowerShell.PSConsoleReadLine]::Insert('$literal') } catch { }
"@)

Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action $insertOnIdle | Out-Null

Write-Host '[shell] ' -NoNewline -ForegroundColor DarkGray
Write-Host $Command -NoNewline -ForegroundColor Cyan
Write-Host '  -> 按回车执行，Ctrl+C 清掉' -ForegroundColor DarkGray
