#requires -version 7
<#
  内置终端：ConPTY（conpty.cs）+ xterm.js（跑在 WebView2 里）。
  由 pwsh-launcher.ps1 点源加载，本身不单独运行。

  分工：
    ConPTY   —— 起一个没有窗口的 pwsh，把它的输出流当字节读出来、把键盘输入写回去；
    xterm.js —— 解析 VT 控制序列画成字符网格，跑在 WebView2 控件里；
    本文件   —— 把两边接起来（定时器搬运字节 + 处理 ready/input/resize 消息）。

  线程模型：ConPTY 的读线程只往队列里塞字节，绝不回调 PowerShell；
  UI 线程用定时器调 Update-TerminalSession 取走并转发给 WebView2（WebView2 只能在 UI 线程调）。
#>

function Initialize-ConPtyType {
  param([Parameter(Mandatory)][string]$ProjectRoot)

  $cs = Join-Path $ProjectRoot 'conpty.cs'
  $dll = Join-Path $ProjectRoot 'vendor\PwshLauncher.ConPty.dll'
  if (-not (Test-Path -LiteralPath $cs)) { throw "找不到 conpty.cs：$cs" }

  $stale = (-not (Test-Path -LiteralPath $dll)) -or
           ((Get-Item -LiteralPath $cs).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dll).LastWriteTimeUtc)

  if ($stale) {
    # Add-Type -OutputAssembly 不会覆盖已存在的文件，得先删；写不进去就退回内存编译
    if (Test-Path -LiteralPath $dll) { [IO.File]::Delete($dll) }
    try {
      Add-Type -Path $cs -OutputAssembly $dll -ErrorAction Stop
    } catch {
      Add-Type -Path $cs
      return
    }
  }
  Add-Type -Path $dll
}

function Initialize-TerminalHost {
  param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$UserDataFolder = (Join-Path $env:LOCALAPPDATA 'pwsh-launcher\webview2')
  )

  $vw = Join-Path $ProjectRoot 'vendor\webview2'
  $coreDll = Join-Path $vw 'Microsoft.Web.WebView2.Core.dll'
  $winFormsDll = Join-Path $vw 'Microsoft.Web.WebView2.WinForms.dll'
  $loaderDll = Join-Path $vw 'WebView2Loader.dll'
  foreach ($f in @($coreDll, $winFormsDll, $loaderDll)) {
    if (-not (Test-Path -LiteralPath $f)) {
      throw "缺少 WebView2 依赖：$f`n先跑一次 fetch-deps.ps1。"
    }
  }

  # WebView2Loader.dll 是原生库，必须显式加载：
  # 托管侧是靠 DllImport("WebView2Loader.dll") 找它的，.NET 不会去 vendor 目录里翻
  [void][System.Runtime.InteropServices.NativeLibrary]::Load($loaderDll)
  Add-Type -Path $coreDll
  Add-Type -Path $winFormsDll
  Initialize-ConPtyType -ProjectRoot $ProjectRoot

  New-Item -ItemType Directory -Force -Path $UserDataFolder | Out-Null

  # 注意第一个参数是 browserExecutableFolder（固定版本模式），不是用户数据目录；
  # 传 $null 表示用系统装的 Evergreen 运行时。
  # 这里必须同步等待：等 UI 线程起来之后再阻塞会死锁，所以要趁现在还没建窗口。
  $envObj = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $UserDataFolder).GetAwaiter().GetResult()

  return [pscustomobject]@{
    Environment = $envObj
    VirtualHost = 'pwsh-launcher.local'
    ProjectRoot = $ProjectRoot
  }
}

function New-TerminalSession {
  param(
    [Parameter(Mandatory)]$TerminalHost,
    [Parameter(Mandatory)][System.Windows.Forms.TabControl]$Tabs,
    [Parameter(Mandatory)][string]$Directory,
    [string]$Command = '',
    [string]$Title = '',
    [Parameter(Mandatory)][string]$PwshPath,
    [Parameter(Mandatory)][string]$OpenShellScript
  )

  if ([string]::IsNullOrWhiteSpace($Title)) { $Title = Split-Path -Leaf $Directory }

  $page = New-Object System.Windows.Forms.TabPage
  $page.Text = $Title
  $page.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 12)

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = 'Top'
  $header.Height = 26
  $header.BackColor = [System.Drawing.Color]::FromArgb(243, 243, 243)

  $lblPath = New-Object System.Windows.Forms.Label
  $lblPath.Text = $Directory
  $lblPath.AutoSize = $true
  $lblPath.Dock = 'Left'
  $lblPath.TextAlign = 'MiddleLeft'
  $lblPath.Padding = New-Object System.Windows.Forms.Padding(6, 4, 0, 0)

  $btnClose = New-Object System.Windows.Forms.Button
  $btnClose.Text = '关闭'
  $btnClose.Dock = 'Right'
  $btnClose.Width = 64
  $btnClose.FlatStyle = 'Flat'

  $webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
  $webView.Dock = 'Fill'
  # 页面加载前先铺成终端底色，免得闪一下白
  $webView.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(12, 12, 12)

  # 停靠顺序：Fill 的先加，Top 的后加（后加的先生效，占走顶部）
  $page.Controls.Add($webView)
  $page.Controls.Add($header)
  $header.Controls.Add($lblPath)
  $header.Controls.Add($btnClose)
  $Tabs.TabPages.Add($page)

  $session = [pscustomobject]@{
    Page        = $page
    WebView     = $webView
    Pty         = $null
    Ready       = $false
    Closed      = $false
    ShellExited = $false
    Title       = $Title
    Directory   = $Directory
  }

  # ---- 起 pwsh（伪控制台，没有窗口）----
  $shellArgs = @('-NoLogo', '-NoExit', '-File', ('"' + $OpenShellScript + '"'), '-Directory', ('"' + $Directory + '"'))
  if (-not [string]::IsNullOrWhiteSpace($Command)) { $shellArgs += @('-Command', ('"' + $Command + '"')) }
  $shellArgs += @('-WindowTitle', ('"' + $Title + '"'))
  $cmdLine = '"' + $PwshPath + '" ' + ($shellArgs -join ' ')
  $session.Pty = New-Object PwshLauncher.ConPty($cmdLine, $Directory, 100, 30)

  # ---- 页面就绪后：映射本地目录、接消息、导航 ----
  # 【重要】事件回调里一律用 $sender.Tag / $sender2 反查对象，不要依赖闭包捕获本函数的局部变量：
  # PowerShell 里从函数内部创建的事件处理器，等回调真的触发时局部变量已经取不到了
  # （实测 $webView 变成 $null，于是 SetVirtualHostNameToFolderMapping 报 "null-valued expression"，
  #  表现就是标签页一片黑、什么都不渲染）。
  $webView.Tag = $session
  $btnClose.Tag = $session

  $webView.add_CoreWebView2InitializationCompleted({
      param($sender, $e)
      if (-not $e.IsSuccess) { return }
      $core = $sender.CoreWebView2
      $core.SetVirtualHostNameToFolderMapping(
        $script:TerminalHost.VirtualHost,
        $script:TerminalHost.ProjectRoot,
        [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)

      $core.add_WebMessageReceived({
          param($sender2, $e2)
          # 按 CoreWebView2 反查是哪个会话（同样是为了避开闭包）
          $session = $null
          foreach ($cand in @($script:Sessions)) {
            if ($cand.Closed) { continue }
            if ($cand.WebView.CoreWebView2 -eq $sender2) { $session = $cand; break }
          }
          if (-not $session) { return }
          try {
            $msg = $e2.WebMessageAsJson | ConvertFrom-Json
          } catch { return }
          switch ($msg.type) {
            'ready' { $session.Ready = $true }
            'input' {
              if ($session.Pty -and $msg.data) {
                $session.Pty.WriteBytes([Text.Encoding]::UTF8.GetBytes([string]$msg.data))
              }
            }
            'resize' {
              if ($session.Pty) { $session.Pty.Resize([int]$msg.cols, [int]$msg.rows) }
            }
          }
        })

      $core.Navigate('https://' + $script:TerminalHost.VirtualHost + '/web/terminal.html')
    })
  $webView.EnsureCoreWebView2Async($TerminalHost.Environment) | Out-Null

  $btnClose.add_Click({ param($sender, $e) Close-TerminalSession -Session $sender.Tag })

  return $session
}

function Update-TerminalSession {
  param([Parameter(Mandatory)]$Session)

  if ($Session.Closed -or -not $Session.Ready) { return }
  $core = $null
  try { $core = $Session.WebView.CoreWebView2 } catch { }
  if (-not $core) { return }

  $bytes = $Session.Pty.DrainOutput()
  if ($bytes -and $bytes.Length -gt 0) {
    $core.PostWebMessageAsJson('{"type":"output","data":"' + [Convert]::ToBase64String($bytes) + '"}')
  }

  if (-not $Session.ShellExited -and $Session.Pty.HasExited) {
    $Session.ShellExited = $true
    $note = "`r`n`e[38;5;244m[进程已退出，退出码 $($Session.Pty.ExitCode)]`e[0m`r`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($note))
    $core.PostWebMessageAsJson('{"type":"output","data":"' + $b64 + '"}')
  }
}

function Close-TerminalSession {
  param([Parameter(Mandatory)]$Session)

  if ($Session.Closed) { return }
  $Session.Closed = $true

  try { if ($Session.Pty) { $Session.Pty.Dispose() } } catch { }
  try {
    $tabs = $Session.Page.Parent
    if ($tabs) { $tabs.TabPages.Remove($Session.Page) }
    $Session.Page.Dispose()
  } catch { }
}
