#requires -version 7
<#
.SYNOPSIS
  下载内置终端需要的两个第三方依赖到 vendor\（不进 git，和 jarvis2 的 fetch-engine.mjs 一个套路）。

.DESCRIPTION
  - WebView2 SDK（微软）：取 lib\net462 的两个托管 dll + win-x64 的 WebView2Loader.dll。
    注意包里只有 net462 目标，.NET 8 的 WinForms 能直接吃。
  - xterm.js（MIT）：终端模拟器本体，由 WebView2 里的页面加载。
  为什么不提交进仓库：二进制 2MB 上下，仓库里放脚本更干净；离线重装时重跑本脚本即可。

.EXAMPLE
  pwsh -NoProfile -File .\fetch-deps.ps1
  pwsh -NoProfile -File .\fetch-deps.ps1 -Force    # 强制重新下载
#>
[CmdletBinding()]
param(
  [string]$VendorDir = (Join-Path $PSScriptRoot 'vendor'),
  [string]$WebView2Version = '1.0.4191.47',
  [string]$XtermVersion = '5.5.0',
  [string]$FitAddonVersion = '0.10.0',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$webviewDir = Join-Path $VendorDir 'webview2'
$xtermDir = Join-Path $VendorDir 'xterm'
$stampFile = Join-Path $VendorDir 'VERSIONS.txt'
$stamp = "webview2=$WebView2Version`nxterm=$XtermVersion`nfit=$FitAddonVersion"

function Test-DepsPresent {
  $need = @(
    (Join-Path $webviewDir 'Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $webviewDir 'Microsoft.Web.WebView2.WinForms.dll'),
    (Join-Path $webviewDir 'WebView2Loader.dll'),
    (Join-Path $xtermDir 'xterm.js'),
    (Join-Path $xtermDir 'xterm.css'),
    (Join-Path $xtermDir 'addon-fit.js')
  )
  foreach ($f in $need) { if (-not (Test-Path -LiteralPath $f)) { return $false } }
  if (-not (Test-Path -LiteralPath $stampFile)) { return $false }
  return ((Get-Content -LiteralPath $stampFile -Raw).Trim() -eq $stamp.Trim())
}

if (-not $Force -and (Test-DepsPresent)) {
  Write-Host "依赖已就绪（$VendorDir），跳过下载。要强制更新加 -Force。" -ForegroundColor Green
  return
}

New-Item -ItemType Directory -Force -Path $webviewDir, $xtermDir | Out-Null

# ---------------------------------------------------------------- WebView2 SDK

$nupkg = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$WebView2Version/microsoft.web.webview2.$WebView2Version.nupkg"
$tmpNupkg = Join-Path $env:TEMP "webview2-$WebView2Version.nupkg"
Write-Host "下载 WebView2 SDK $WebView2Version ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $nupkg -OutFile $tmpNupkg -UseBasicParsing

Add-Type -AssemblyName System.IO.Compression.FileSystem
$want = [ordered]@{
  'lib/net462/Microsoft.Web.WebView2.Core.dll'     = (Join-Path $webviewDir 'Microsoft.Web.WebView2.Core.dll')
  'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = (Join-Path $webviewDir 'Microsoft.Web.WebView2.WinForms.dll')
  'runtimes/win-x64/native/WebView2Loader.dll'     = (Join-Path $webviewDir 'WebView2Loader.dll')
}
$zip = [System.IO.Compression.ZipFile]::OpenRead($tmpNupkg)
try {
  foreach ($entryName in $want.Keys) {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $entryName } | Select-Object -First 1
    if (-not $entry) { throw "包里没有 $entryName（SDK 布局变了？）" }
    $dest = $want[$entryName]
    $inStream = $entry.Open()
    $outStream = [System.IO.File]::Create($dest)
    try { $inStream.CopyTo($outStream) } finally { $outStream.Dispose(); $inStream.Dispose() }
    Write-Host ("  {0}  ->  {1}  ({2:N0} KB)" -f $entryName, (Split-Path -Leaf $dest), ($entry.Length / 1KB)) -ForegroundColor DarkGray
  }
} finally {
  $zip.Dispose()
  Remove-Item -LiteralPath $tmpNupkg -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- xterm.js

$assets = @(
  @{ Url = "https://unpkg.com/@xterm/xterm@$XtermVersion/lib/xterm.js"; Dest = (Join-Path $xtermDir 'xterm.js') },
  @{ Url = "https://unpkg.com/@xterm/xterm@$XtermVersion/css/xterm.css"; Dest = (Join-Path $xtermDir 'xterm.css') },
  @{ Url = "https://unpkg.com/@xterm/addon-fit@$FitAddonVersion/lib/addon-fit.js"; Dest = (Join-Path $xtermDir 'addon-fit.js') }
)
foreach ($a in $assets) {
  Write-Host "下载 $(Split-Path -Leaf $a.Dest) ..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $a.Url -OutFile $a.Dest -UseBasicParsing
}

$stampText = @(
  "WebView2 SDK : $WebView2Version  (https://www.nuget.org/packages/Microsoft.Web.WebView2)"
  "xterm.js     : $XtermVersion  (https://www.npmjs.com/package/@xterm/xterm, MIT)"
  "addon-fit    : $FitAddonVersion  (https://www.npmjs.com/package/@xterm/addon-fit, MIT)"
  "下载时间     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  "由 fetch-deps.ps1 生成，不要手工编辑。"
) -join "`n"
Set-Content -LiteralPath $stampFile -Value $stampText -Encoding UTF8

Write-Host "依赖就绪: $VendorDir" -ForegroundColor Green
