#requires -version 7
<#
.SYNOPSIS
  pwsh 启动器：左边管理常用文件夹，右边选命令，点一下开一个「命令已预填」的 pwsh。

.DESCRIPTION
  设计约定：
  - 文件夹列表存在脚本同目录的 folders.json（相对 $PSScriptRoot，整个文件夹挪走也能用）。
  - 右侧命令不需要手工维护：读该文件夹 package.json 的 scripts 生成，常用脚本按优先级排前面。
    没有 package.json 就退回几条通用 git 命令。
  - 开终端默认走内置终端：ConPTY 起一个没有窗口的 pwsh，输出交给 WebView2 里的 xterm.js 渲染，
    会话以标签页形式长在本窗口里（见 terminal-session.ps1 / web/terminal.html），任务栏只有一个按钮。
    取消勾选「在启动器内打开」则退回 Windows Terminal 标签页模式，用 wt.exe -w <窗口名> nt，
    窗口名由 -TerminalWindowName 控制（'0' = 当前 WT 窗口，'-1' = 每次新窗口）。
  - 只负责「开一个终端并把命令敲好」，不常驻、不后台、不碰你的项目进程。

.EXAMPLE
  # 由桌面快捷方式调用。宿主用 conhost --headless：不建控制台窗口，
  # 也就不会在任务栏「终端」组里多算一个隐藏窗口（-STA 是 WinForms 要的）。
  conhost.exe --headless pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\pwsh-launcher.ps1
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'folders.json'),
  [string]$OpenShellScript = (Join-Path $PSScriptRoot 'open-shell.ps1'),
  # 所有会话都塞进这个「按名字定位」的 Windows Terminal 窗口的不同标签页；
  # 名字只是用来定位窗口的，不会显示在标题栏。想改成「标签页开到当前 WT 窗口」，把它换成 '0' 即可。
  [string]$TerminalWindowName = 'pwsh-launcher',
  # 开机自启动时带上：最小化启动，不挡屏幕（点任务栏或桌面快捷方式就能恢复）
  [switch]$StartMinimized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# pwsh 默认跑在 MTA，老式 FolderBrowserDialog 在 MTA 下会出问题（claude-launcher 也是靠 -STA 绕开的）。
# 快捷方式已经带 -STA；这里是兜底：万一有人直接 pwsh -File 跑，就自己用 -STA 重启一份。
# 环境变量会传给子进程，所以不会无限重启。
if ($env:PWSH_LAUNCHER_RELAUNCHED -ne '1' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
  $env:PWSH_LAUNCHER_RELAUNCHED = '1'
  Start-Process -FilePath (Get-Process -Id $PID).Path `
    -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"") `
    -WorkingDirectory $PSScriptRoot
  exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace PwshLauncher -Name Native -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
"@

# 任务栏是按 AppUserModelID 分组的：不指定的话，用 pwsh.exe 启的窗口会被并进
# 「Windows PowerShell / 终端」那一组，任务栏上显示的是那一组的图标和名字 ——
# 我们设的 Form.Icon 压根不会出现在任务栏按钮上（claude-launcher 的图标"加载不出来"就是这个原因）。
Add-Type -Namespace PwshLauncher -Name Shell -MemberDefinition @"
[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string appId);
"@
try { [PwshLauncher.Shell]::SetCurrentProcessExplicitAppUserModelID('wenheLL.PwshLauncher') } catch { }

# 进程级那个 API 要求「在建窗口之前」调用，而 pwsh 启动时控制台窗口早就建好了，实测不生效。
# 真正管用的是窗口级属性：往窗口的 IPropertyStore 里写 PKEY_AppUserModel_ID。
# 写完之后任务栏会把我们单列一组，图标取窗口图标、名字取窗口标题。
Add-Type -Namespace PwshLauncher -Name AppId -MemberDefinition @"
[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
private interface IPropertyStore {
  [PreserveSig] int GetCount(out uint c);
  [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
  [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
  [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
  [PreserveSig] int Commit();
}
[StructLayout(LayoutKind.Sequential, Pack = 4)]
private struct PROPERTYKEY { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit)]
private struct PROPVARIANT {
  [FieldOffset(0)] public ushort vt;
  [FieldOffset(8)] public IntPtr p;
}
[DllImport("shell32.dll")]
private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropertyStore store);
public static void SetWindowAppId(IntPtr hwnd, string appId) {
  var iid = new Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
  IPropertyStore store;
  int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
  if (hr != 0) { System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(hr); }
  try {
    var key = new PROPERTYKEY();
    key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    key.pid = 5;
    var pv = new PROPVARIANT();
    pv.vt = 31; // VT_LPWSTR
    pv.p = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUni(appId);
    try {
      hr = store.SetValue(ref key, ref pv);
      if (hr != 0) { System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(hr); }
      hr = store.Commit();
      if (hr != 0) { System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(hr); }
    } finally {
      System.Runtime.InteropServices.Marshal.FreeCoTaskMem(pv.p);
    }
  } finally {
    System.Runtime.InteropServices.Marshal.ReleaseComObject(store);
  }
}
"@

# 不声明 DPI 感知的话，125%/150% 缩放下系统会把整个窗口栅格化拉伸 —— 字和边框都是糊的。
try { [void][PwshLauncher.Native]::SetProcessDPIAware() } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

# 布局按 96 DPI 写死，再按实际 DPI 自己乘一遍。
# 【不要改回 AutoScaleMode='Dpi' + AutoScaleDimensions】实测在 pwsh 里不生效（窗口没缩），
# 结果是字号跟着 DPI 变大、控件尺寸不变，缩放一高就会把文字挤出去。
$script:Scale = 1.0
try {
  $systemDpi = [PwshLauncher.Native]::GetDpiForSystem()
  if ($systemDpi -gt 0) { $script:Scale = $systemDpi / 96.0 }
} catch { }
function ScaleInt { param([double]$v) [int][Math]::Round($v * $script:Scale) }
function ScalePoint { param([double]$x, [double]$y) New-Object System.Drawing.Point((ScaleInt $x), (ScaleInt $y)) }
function ScaleSize { param([double]$w, [double]$h) New-Object System.Drawing.Size((ScaleInt $w), (ScaleInt $h)) }

# package.json scripts 里这些名字排前面，其余按字母序跟在后面
$script:ScriptPriority = @(
  'dev', 'start', 'build', 'test', 'typecheck', 'lint',
  'dist:win', 'dist:win:native', 'dist', 'package', 'release'
)
$script:MaxCommands = 14

$script:Folders = New-Object System.Collections.Generic.List[string]

# 启动时左右两栏的默认宽度比例（左栏占窗口宽度的百分比）。
# 想改就直接改这个数：0.52 = 左栏 52%，0.4 = 左栏 40%。
# 之后用户仍然可以拖分隔条临时调整，只是不会再记住（重开回到这个值）。
$script:DefaultSplitRatio = 0.52

# ---------------------------------------------------------------- 配置读写

function Read-FolderConfig {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    # 首次运行不塞任何东西，界面上会提示去点「添加文件夹…」
    return
  }
  try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($f in @($cfg.folders)) {
      if ($f -and -not $script:Folders.Contains([string]$f)) { $script:Folders.Add([string]$f) }
    }
  } catch {
    [System.Windows.Forms.MessageBox]::Show(
      "配置文件读不了，这次就当空的用：`n$ConfigPath`n`n$($_.Exception.Message)",
      'pwsh 启动器', 'OK', 'Warning') | Out-Null
  }
}

function Save-FolderConfig {
  $dir = Split-Path -Parent $ConfigPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [pscustomobject]@{ folders = @($script:Folders) } |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# ---------------------------------------------------------------- 命令推导

function Get-FolderCommands {
  param([string]$Directory)

  $pkgPath = Join-Path $Directory 'package.json'
  if (Test-Path -LiteralPath $pkgPath) {
    $names = @()
    try {
      $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($pkg.PSObject.Properties['scripts']) { $names = @($pkg.scripts.PSObject.Properties.Name) }
    } catch { $names = @() }

    if ($names.Count -gt 0) {
      $ordered = @()
      foreach ($p in $script:ScriptPriority) {
        if ($names -contains $p) { $ordered += $p }
      }
      $ordered += ($names | Where-Object { $ordered -notcontains $_ } | Sort-Object)
      return @($ordered | Select-Object -First $script:MaxCommands | ForEach-Object { "npm run $_" })
    }
  }

  return @('git status -sb', 'git pull --ff-only')
}

# ---------------------------------------------------------------- 开终端

function ConvertTo-WtLiteral {
  param([string]$Value)
  # wt 有自己的参数解析：`;` 被当成命令分隔符、`"` 需要转义，其余交给 PowerShell 的标准引号处理。
  # 我们的值里基本不会出现这两个字符，但目录名带分号时（罕见）不至于把命令拆开。
  return $Value.Replace('"', '\"').Replace(';', '\;')
}

# 在启动器自己的标签页里开一个终端（ConPTY + xterm.js）
function Open-EmbeddedSession {
  param([string]$Directory, [string]$Command = '')

  $title = Split-Path -Leaf $Directory
  # 同一个文件夹开第二个会话时，标题加序号，免得标签页重名分不清
  $used = @($script:Sessions | Where-Object { -not $_.Closed } | ForEach-Object { $_.Title })
  if ($used -contains $title) {
    $n = 2
    while ($used -contains "$title ($n)") { $n++ }
    $title = "$title ($n)"
  }

  # 第一次开终端时把窗口撑到能用的尺寸
  if ($tabs.TabPages.Count -lt 2) {
    $want = ScaleSize 1180 720
    if ($form.ClientSize.Width -lt $want.Width -or $form.ClientSize.Height -lt $want.Height) {
      $form.ClientSize = New-Object System.Drawing.Size(
        [Math]::Max($form.ClientSize.Width, $want.Width),
        [Math]::Max($form.ClientSize.Height, $want.Height))
    }
  }

  $session = New-TerminalSession -TerminalHost $script:TerminalHost -Tabs $tabs `
    -Directory $Directory -Command $Command -Title $title `
    -PwshPath (Get-Process -Id $PID).Path -OpenShellScript $OpenShellScript
  [void]$script:Sessions.Add($session)
  $tabs.SelectedTab = $session.Page
  $lblStatus.Text = "已在启动器内打开：$Directory"
}

function Start-PrefilledShell {
  param([string]$Directory, [string]$Command)

  if (-not (Test-Path -LiteralPath $Directory)) {
    [System.Windows.Forms.MessageBox]::Show("文件夹不存在了：`n$Directory", 'pwsh 启动器', 'OK', 'Warning') | Out-Null
    return
  }
  if (-not (Test-Path -LiteralPath $OpenShellScript)) {
    [System.Windows.Forms.MessageBox]::Show("找不到 open-shell.ps1：`n$OpenShellScript", 'pwsh 启动器', 'OK', 'Error') | Out-Null
    return
  }

  # 默认开在启动器里（ConPTY，任务栏不留东西）；
  # 取消勾选或内置终端不可用时，才走下面的 Windows Terminal / 独立窗口。
  if ($script:UseEmbedded -and $script:TerminalHost) {
    Open-EmbeddedSession -Directory $Directory -Command $Command
    return
  }

  $pwshPath = (Get-Process -Id $PID).Path
  $title = Split-Path -Leaf $Directory
  $shellArgs = @('-NoLogo', '-NoExit', '-File', $OpenShellScript, '-Directory', $Directory)
  if (-not [string]::IsNullOrWhiteSpace($Command)) { $shellArgs += @('-Command', $Command) }
  $shellArgs += @('-WindowTitle', $title)

  # 首选 Windows Terminal：-w 按名字定位窗口，nt 在里面开新标签页 ——
  # 于是所有会话都在同一个窗口、不同 tab 里；窗口不存在时 wt 会自动建一个。
  $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
  if ($wt) {
    $wtArgs = @('-w', $TerminalWindowName, 'nt', '--title', (ConvertTo-WtLiteral $title), '-d', (ConvertTo-WtLiteral $Directory), $pwshPath)
    $wtArgs += ($shellArgs | ForEach-Object { ConvertTo-WtLiteral $_ })
    try {
      # 注意：wt.exe 是 GUI 程序，`&` 不会等它、也不会更新 $LASTEXITCODE，
      # 所以这里【不要】写 "if ($LASTEXITCODE -eq 0) { return }" —— 那是拿上一条命令的残留值做判断，
      # 会误判成失败，于是额外再开一个窗口（重复开窗）。
      & $wt.Source @wtArgs
      return
    } catch {
      # wt 存在但调不起来：往下走兜底
    }
  }

# 兜底：没有 wt.exe（或它失败了）就回到「自己开一个窗口」的老办法。
  # Start-Process 只做空格拼接，带空格的参数得自己补引号。
  $argumentLine = ($shellArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  Start-Process -FilePath $pwshPath -ArgumentList $argumentLine -WorkingDirectory $Directory
}

# ---------------------------------------------------------------- 内置终端

# ---------------------------------------------------------------- 单实例

# 装了开机自启动之后，很容易出现「自启的那个已经在跑，你又双击了桌面快捷方式」——
# 于是任务栏挂两个一模一样的启动器。这里用命名互斥体挡一下：
# 已经在跑就把它的窗口唤到前台（最小化状态则先还原），本进程直接退出。
# 注意：这个必须放在下面那些初始化（WebView2 环境、conpty 编译）之前，
# 否则重复启动时要白等两秒才退出。
# 【为什么不用 FindWindow(null, '标题')】实测从 PowerShell 调它时，那个 $null 的类名参数
# 匹配不上（返回 0），窗口就白找。这里改成自己枚举顶层窗口比标题 —— 和其它诊断脚本里用的是同一套，稳定。
Add-Type -Namespace PwshLauncher -Name Singleton -MemberDefinition @"
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
"@
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\pwsh-launcher-single')
if (-not $script:InstanceMutex.WaitOne(0)) {
  try {
    $script:ExistingWindow = [IntPtr]::Zero
    $findCallback = [PwshLauncher.Singleton+EnumWindowsProc]{
      param($hWnd, $lParam)
      if ([PwshLauncher.Singleton]::IsWindowVisible($hWnd)) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][PwshLauncher.Singleton]::GetWindowTextW($hWnd, $sb, 256)
        if ($sb.ToString() -eq 'pwsh 启动器') {
          $script:ExistingWindow = $hWnd
          return $false   # 找到就停
        }
      }
      return $true
    }
    [void][PwshLauncher.Singleton]::EnumWindows($findCallback, [IntPtr]::Zero)
    if ($script:ExistingWindow -ne [IntPtr]::Zero) {
      if ([PwshLauncher.Singleton]::IsIconic($script:ExistingWindow)) {
        [void][PwshLauncher.Singleton]::ShowWindowAsync($script:ExistingWindow, 9)   # SW_RESTORE
      }
      [void][PwshLauncher.Singleton]::SetForegroundWindow($script:ExistingWindow)
    }
  } catch { }
  exit
}

# 内置终端 = ConPTY（没有窗口的 pwsh）+ xterm.js（跑在 WebView2 里）。
# 初始化必须赶在建任何窗口之前：WebView2 环境是同步等待创建的，
# 等 UI 线程跑起来之后再阻塞会死锁。
$script:UseEmbedded = $true
$script:Sessions = New-Object System.Collections.ArrayList
$script:TerminalHost = $null
$script:TerminalHostError = ''
try {
  . (Join-Path $PSScriptRoot 'terminal-session.ps1')
  $script:TerminalHost = Initialize-TerminalHost -ProjectRoot $PSScriptRoot
} catch {
  # 内置终端起不来不能把启动器整个搞挂：退回到「开 Windows Terminal 标签页」
  $script:TerminalHostError = $_.Exception.Message
  $script:UseEmbedded = $false
}

# ---------------------------------------------------------------- 界面

$form = New-Object System.Windows.Forms.Form
$form.Text = 'pwsh 启动器'
$form.AutoScaleMode = 'None' # 缩放自己算，见上面的 ScaleInt/ScalePoint/ScaleSize
$form.ClientSize = ScaleSize 1180 720
$form.MinimumSize = ScaleSize 820 520
$form.StartPosition = 'CenterScreen'
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch { }
if ($StartMinimized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized }

# 窗口图标：任务栏按钮取的就是这个（WM_SETICON），跟 .lnk 的图标是两回事。
# 按 DPI 缩放后的 32px 去取对应尺寸的条目 —— 否则系统会拿 32px 的图放大到 40px（125% 下会糊）。
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
if (Test-Path -LiteralPath $iconPath) {
  try {
    $iconPx = ScaleInt 32
    $form.Icon = New-Object System.Drawing.Icon($iconPath, (New-Object System.Drawing.Size($iconPx, $iconPx)))
  } catch { }
}

# 窗口句柄一建好就把 AUMID 写上（此时窗口还没显示，任务栏按钮也还没生成）
$form.add_HandleCreated({
    try { [PwshLauncher.AppId]::SetWindowAppId($form.Handle, 'wenheLL.PwshLauncher') } catch { }
  })

# 顶层是标签页：第 0 页是启动器本体，之后每开一个终端会话就多一页 ——
# 所有终端都长在启动器窗口里，任务栏永远只有这一个按钮。
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
# 标签本身做大一点：字体大一档 + 内边距，不然默认那一条又矮又小不好点
try { $tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5) } catch { }
$tabs.Padding = New-Object System.Drawing.Point((ScaleInt 16), (ScaleInt 7))
# 固定宽度：Normal 模式是按文字宽度算的，不会算上右侧给 ✕ 预留的位置，
# 结果标签文字会被截成 "ja..."（实测）。固定宽度让文字和 ✕ 都有地方放。
$tabs.ItemSize = New-Object System.Drawing.Size((ScaleInt 190), (ScaleInt 32))
$tabs.SizeMode = 'Fixed'
$tabs.ShowToolTips = $true     # 会话页的 ToolTipText 放完整路径
# 自绘标签：WinForms 原生不支持「标签上带关闭按钮」，得自己画 + 自己判点击位置
$tabs.DrawMode = 'OwnerDrawFixed'
# 自绘 + 悬停重画容易闪，开双缓冲（DoubleBuffered 是 protected，只能反射设）
try {
  [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
    ([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)) |
    ForEach-Object { $_.SetValue($tabs, $true, $null) }
} catch { }

$tabLauncher = New-Object System.Windows.Forms.TabPage
$tabLauncher.Text = '启动器'
$tabLauncher.Tag = 'launcher'   # 会话页的 Tag 是会话对象，用这个区分「不要画关闭按钮」
$tabLauncher.UseVisualStyleBackColor = $false
$tabLauncher.BackColor = [System.Drawing.Color]::White   # 跟活动标签同色，视觉上连成一片
$tabs.TabPages.Add($tabLauncher)

$edge = ScaleInt 12
$launcherPanel = New-Object System.Windows.Forms.Panel
$launcherPanel.Dock = 'Fill'
$launcherPanel.Padding = New-Object System.Windows.Forms.Padding($edge, (ScaleInt 10), $edge, (ScaleInt 10))
$launcherPanel.BackColor = [System.Drawing.Color]::White
$tabLauncher.Controls.Add($launcherPanel)

# 左右两栏装进 SplitContainer：中间那条分隔条可以直接左右拖，改两栏宽度比例。
# 停靠顺序：Fill 的先加，Bottom 的后加（后加的先生效，占走底边）。
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.SplitterWidth = ScaleInt 6
$split.Panel1.BorderStyle = 'FixedSingle'
$split.Panel2.BorderStyle = 'FixedSingle'
$split.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235) # 分隔条的颜色：看得出来能拖
# 注意：Panel1MinSize / Panel2MinSize / SplitterDistance 不能在这里设 ——
# 现在是 Dock=Fill，布局之前容器宽度还是默认的 150，设 400 会直接抛
# "SplitterDistance must be between Panel1MinSize and Width - Panel2MinSize"。
# 挪到窗口 Shown 里设（那时布局已完成，宽度是真的）。
$panelPadding = New-Object System.Windows.Forms.Padding((ScaleInt 4))
$split.Panel1.Padding = $panelPadding
$split.Panel2.Padding = $panelPadding

$lblFolders = New-Object System.Windows.Forms.Label
$lblFolders.Text = '常用文件夹'
$lblFolders.AutoSize = $true
$lblFolders.Dock = 'Top'

$lstFolders = New-Object System.Windows.Forms.ListBox
$lstFolders.Dock = 'Fill'
$lstFolders.IntegralHeight = $false

# 停靠顺序有讲究：先加 Fill 的、再加 Top 的 —— WinForms 是「后加的先生效」，
# 这样标签占顶部、列表吃掉剩余空间。写反了标签会跑到列表下面去。
$split.Panel1.Controls.Add($lstFolders)
$split.Panel1.Controls.Add($lblFolders)

# 底部按钮行：左边一串操作按钮放流式布局，右边「打开 pwsh」贴右。
# 全用停靠而不是绝对坐标 —— 左右拖动分隔条或改窗口大小时都不会错位。
$bottomBar = New-Object System.Windows.Forms.Panel
$bottomBar.Dock = 'Bottom'
$bottomBar.Height = ScaleInt 36

$flowLeft = New-Object System.Windows.Forms.FlowLayoutPanel
$flowLeft.Dock = 'Fill'
$flowLeft.FlowDirection = 'LeftToRight'
$flowLeft.WrapContents = $false

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = '添加文件夹…'
$btnAdd.Size = ScaleSize 130 30
$btnAdd.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 3)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = '移除'
$btnRemove.Size = ScaleSize 70 30
$btnRemove.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 3)

$btnExplorer = New-Object System.Windows.Forms.Button
$btnExplorer.Text = '资源管理器'
$btnExplorer.Size = ScaleSize 110 30
$btnExplorer.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 3)

$btnEmpty = New-Object System.Windows.Forms.Button
$btnEmpty.Text = '空终端'
$btnEmpty.Size = ScaleSize 66 30
$btnEmpty.Margin = New-Object System.Windows.Forms.Padding(0, 3, 12, 3)

# 内置终端可用时默认勾上；起不来（缺依赖 / 没装 WebView2 运行时）就灰掉并退回 WT
$chkEmbedded = New-Object System.Windows.Forms.CheckBox
$chkEmbedded.Text = '在启动器内打开（新标签页）'
$chkEmbedded.AutoSize = $true
$chkEmbedded.Checked = [bool]$script:TerminalHost
$chkEmbedded.Enabled = [bool]$script:TerminalHost
$chkEmbedded.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 3)
if (-not $script:TerminalHost) { $chkEmbedded.Text = '在启动器内打开（不可用，见下方提示）' }

$flowLeft.Controls.AddRange(@($btnAdd, $btnRemove, $btnExplorer, $btnEmpty, $chkEmbedded))

$lblCommands = New-Object System.Windows.Forms.Label
$lblCommands.Text = '命令（来自该文件夹的 package.json）'
$lblCommands.AutoSize = $true
$lblCommands.Dock = 'Top'

$lstCommands = New-Object System.Windows.Forms.ListBox
$lstCommands.Dock = 'Fill'
$lstCommands.IntegralHeight = $false
$split.Panel2.Controls.Add($lstCommands)
$split.Panel2.Controls.Add($lblCommands)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = '打开 pwsh（预填选中命令）'
$btnOpen.Dock = 'Right'
$btnOpen.Width = ScaleInt 300
$btnOpen.Margin = New-Object System.Windows.Forms.Padding(0)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Bottom'
$lblStatus.Height = ScaleInt 24
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$bottomBar.Controls.Add($flowLeft)
$bottomBar.Controls.Add($btnOpen)
$launcherPanel.Controls.Add($split)
$launcherPanel.Controls.Add($bottomBar)
$launcherPanel.Controls.Add($lblStatus)
$form.Controls.Add($tabs)
$form.AcceptButton = $btnOpen

# ---------------------------------------------------------------- 交互逻辑

function Get-SelectedFolder {
  if ($lstFolders.SelectedIndex -lt 0) { return '' }
  return $script:Folders[$lstFolders.SelectedIndex]
}

function Update-CommandList {
  $lstCommands.Items.Clear()
  $dir = Get-SelectedFolder
  if (-not $dir) { return }
  if (-not (Test-Path -LiteralPath $dir)) {
    $lblStatus.Text = "⚠ 文件夹不存在：$dir"
    return
  }
  foreach ($c in (Get-FolderCommands -Directory $dir)) { $lstCommands.Items.Add($c) | Out-Null }
  if ($lstCommands.Items.Count -gt 0) { $lstCommands.SelectedIndex = 0 }
  $lblStatus.Text = "已选：$dir  ($($lstCommands.Items.Count) 条命令)"
}

function Refresh-FolderList {
  $keep = $lstFolders.SelectedIndex
  $lstFolders.Items.Clear()
  foreach ($f in $script:Folders) {
    $prefix = if (Test-Path -LiteralPath $f) { '' } else { '⚠ ' }
    $lstFolders.Items.Add("$prefix$f") | Out-Null
  }
  if ($lstFolders.Items.Count -gt 0) {
    $lstFolders.SelectedIndex = [Math]::Max(0, [Math]::Min($keep, $lstFolders.Items.Count - 1))
  }
}

$lstFolders.add_SelectedIndexChanged({ Update-CommandList })

$lstFolders.add_DoubleClick({
  $dir = Get-SelectedFolder
  if (-not $dir) { return }
  $cmd = if ($lstCommands.Items.Count -gt 0) { [string]$lstCommands.Items[0] } else { '' }
  Start-PrefilledShell -Directory $dir -Command $cmd
})

$lstCommands.add_DoubleClick({
  $dir = Get-SelectedFolder
  $cmd = if ($lstCommands.SelectedItem) { [string]$lstCommands.SelectedItem } else { '' }
  if (-not $dir) { return }
  Start-PrefilledShell -Directory $dir -Command $cmd
})

$btnAdd.add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = '选一个常用文件夹'
  $dlg.ShowNewFolderButton = $true
  $current = Get-SelectedFolder
  if ($current -and (Test-Path -LiteralPath $current)) { $dlg.SelectedPath = $current }
  if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

  $picked = $dlg.SelectedPath.TrimEnd('\')
  if ($script:Folders.Contains($picked)) {
    $lblStatus.Text = "已经在列表里了：$picked"
  } else {
    $script:Folders.Add($picked)
    Save-FolderConfig
    Refresh-FolderList
    $lstFolders.SelectedIndex = $lstFolders.Items.Count - 1
    $lblStatus.Text = "已添加并保存：$picked"
  }
})

$btnRemove.add_Click({
  $dir = Get-SelectedFolder
  if (-not $dir) { return }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    "从常用列表里移除？`n$dir", 'pwsh 启动器',
    [System.Windows.Forms.MessageBoxButtons]::YesNo, 'Question')
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  $script:Folders.Remove($dir)
  Save-FolderConfig
  Refresh-FolderList
  $lblStatus.Text = "已移除：$dir"
})

$btnExplorer.add_Click({
  $dir = Get-SelectedFolder
  if (-not $dir) { return }
  if (-not (Test-Path -LiteralPath $dir)) {
    [System.Windows.Forms.MessageBox]::Show("文件夹不存在了：`n$dir", 'pwsh 启动器', 'OK', 'Warning') | Out-Null
    return
  }
  Start-Process -FilePath 'explorer.exe' -ArgumentList $dir
})

$btnEmpty.add_Click({
  $dir = Get-SelectedFolder
  if (-not $dir) { return }
  Start-PrefilledShell -Directory $dir -Command ''
})

$btnOpen.add_Click({
  $dir = Get-SelectedFolder
  if (-not $dir) {
    [System.Windows.Forms.MessageBox]::Show('先在左边选一个文件夹。', 'pwsh 启动器', 'OK', 'Information') | Out-Null
    return
  }
  $cmd = if ($lstCommands.SelectedItem) { [string]$lstCommands.SelectedItem } else { '' }
  Start-PrefilledShell -Directory $dir -Command $cmd
})

# 启动时把分隔条放到默认比例位置。
# 【为什么不在建控件时直接设 SplitterDistance】改成 Dock=Fill 之后，布局之前容器宽度还是默认的 150，
# 那时候设 400 会直接抛 "SplitterDistance must be between Panel1MinSize and Width - Panel2MinSize"。
# 所以等窗口布局好（Load）再设 —— Load 在窗口显示之前，看不到跳动；
# 万一那时宽度还不够（不同 DPI/最小尺寸边界情况），Shown 里再兜一次。
function Set-DefaultSplitRatio {
  try {
    $minLeft = ScaleInt 220
    $minRight = ScaleInt 260
    if ($split.Width -le ($minLeft + $minRight + $split.SplitterWidth)) { return $false }
    $split.Panel1MinSize = $minLeft
    $split.Panel2MinSize = $minRight
    $limit = $split.Width - $minRight - $split.SplitterWidth
    $wanted = [int]($split.Width * $script:DefaultSplitRatio)
    $split.SplitterDistance = [Math]::Max($minLeft, [Math]::Min($limit, $wanted))
    return $true
  } catch {
    return $false
  }
}

$form.add_Load({ [void](Set-DefaultSplitRatio) })
$form.add_Shown({ [void](Set-DefaultSplitRatio) })

$chkEmbedded.add_CheckedChanged({
    # 只影响之后新开的会话，已经开着的标签页不动
    $script:UseEmbedded = $chkEmbedded.Checked
    $lblStatus.Text = if ($chkEmbedded.Checked) { '新会话将开在启动器内' } else { '新会话将开到 Windows Terminal' }
  })

# ---------------------------------------------------------------- 标签页自绘
# ---------------------------------------------------------------- 标签页自绘（仿 Chrome）

# WinForms 的 TabControl 原生画法带 3D 边框和阴影，很难看；这里整条标签栏都自己画：
#   标签栏底色（跟随系统强调色调淡）+ 未选中标签只显示文字和分隔线 +
#   活动标签是白色圆角块（跟下面内容区连成一片）+ ✕ 悬停时带圆形底色。
# 关闭按钮也得自己判点击位置，因为它是画上去的，不是控件。

# 只给上方两个角加圆角：Chrome 的活动标签就是这种"上半圆角、底部跟内容连成一片"
function New-RoundedTopPath {
  param([double]$X, [double]$Y, [double]$Width, [double]$Height, [double]$Radius)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $Radius * 2
  $path.AddArc($X, $Y, $d, $d, 180, 90)
  $path.AddArc(($X + $Width - $d), $Y, $d, $d, 270, 90)
  $path.AddLine(($X + $Width), ($Y + $Radius), ($X + $Width), ($Y + $Height))
  $path.AddLine(($X + $Width), ($Y + $Height), $X, ($Y + $Height))
  $path.AddLine($X, ($Y + $Height), $X, ($Y + $Radius))
  $path.CloseFigure()
  return $path
}

# 标签栏底色：跟 Chrome 一样沾一点系统强调色（很淡），取不到就用中性浅灰蓝
function Get-TabStripColor {
  $fallback = [System.Drawing.Color]::FromArgb(222, 226, 233)
  try {
    $accent = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
    # AccentColor 是 0xAABBGGRR
    $r = $accent -band 0xFF
    $g = ($accent -shr 8) -band 0xFF
    $b = ($accent -shr 16) -band 0xFF
    if ($r -eq 0 -and $g -eq 0 -and $b -eq 0) { return $fallback }
    $mix = 0.14   # 只混一点点，保证是"很淡的一层"
    $nr = [int]($r * $mix + 255 * (1 - $mix))
    $ng = [int]($g * $mix + 255 * (1 - $mix))
    $nb = [int]($b * $mix + 255 * (1 - $mix))
    return [System.Drawing.Color]::FromArgb($nr, $ng, $nb)
  } catch {
    return $fallback
  }
}
$script:TabStripColor = Get-TabStripColor

# ✕ 的矩形：画和判点击都用它，免得两边算错位
function Get-TabCloseRect {
  param([System.Drawing.Rectangle]$TabRect)
  $size = ScaleInt 18
  $x = $TabRect.Right - (ScaleInt 30)
  $y = $TabRect.Y + [int](($TabRect.Height - $size) / 2) + (ScaleInt 3)
  return New-Object System.Drawing.Rectangle($x, $y, $size, $size)
}

function Test-IsSessionPage {
  param($Page)
  if ($null -eq $Page) { return $false }
  return (-not ($Page.Tag -is [string])) -and ($null -ne $Page.Tag)
}

$script:TabHoverIndex = -1
$script:TabHoverClose = $false

# 【别用 $tabs.Invalidate() 不带参数】那是让整个控件失效 ——
# 标签栏底下的页面区域也会跟着重画，鼠标在标签和内容之间来回移动时就会一直闪（实测）。
# 只失效受影响的那一两个标签所在的小矩形就够了。
function Update-TabVisuals {
  param([int]$OldIndex, [int]$NewIndex)
  $rects = @()
  foreach ($i in @($OldIndex, $NewIndex)) {
    if ($i -ge 0 -and $i -lt $tabs.TabPages.Count) { $rects += $tabs.GetTabRect($i) }
  }
  if ($rects.Count -eq 0) { return }
  $left = ($rects | ForEach-Object { $_.Left } | Measure-Object -Minimum).Minimum
  $top = ($rects | ForEach-Object { $_.Top } | Measure-Object -Minimum).Minimum
  $right = ($rects | ForEach-Object { $_.Right } | Measure-Object -Maximum).Maximum
  $bottom = ($rects | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum
  # 外扩 2px，免得边缘和相邻分隔线留下残影
  $tabs.Invalidate((New-Object System.Drawing.Rectangle(
        ($left - 2), ($top - 2), ($right - $left + 4), ($bottom - $top + 4))))
}

$tabs.add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $tabs.TabPages.Count) { return }
    $page = $tabs.TabPages[$e.Index]
    $rect = $e.Bounds
    $g = $e.Graphics
    $selected = ($tabs.SelectedIndex -eq $e.Index)
    $hovered = ($script:TabHoverIndex -eq $e.Index)
    $isSession = Test-IsSessionPage $page
    $radius = ScaleInt 9

    # 1) 先铺标签栏底色，把原生那层 3D 边框盖掉；
    #    第一个标签左侧、最后一个标签右侧的空档也一并铺到控件边缘
    $stripBrush = New-Object System.Drawing.SolidBrush($script:TabStripColor)
    $g.FillRectangle($stripBrush, $rect)
    if ($e.Index -eq 0 -and $rect.Left -gt 0) {
      $g.FillRectangle($stripBrush, 0, $rect.Top, $rect.Left, $rect.Height)
    }
    if ($e.Index -eq $tabs.TabPages.Count - 1 -and $rect.Right -lt $tabs.Width) {
      $g.FillRectangle($stripBrush, $rect.Right, $rect.Top, ($tabs.Width - $rect.Right), $rect.Height)
    }
    $stripBrush.Dispose()

    # 2) 标签本体
    if ($selected) {
      $path = New-RoundedTopPath $rect.X ($rect.Y + (ScaleInt 4)) ($rect.Width - 1) ($rect.Height - (ScaleInt 4)) $radius
      $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
      $g.FillPath($brush, $path)
      $brush.Dispose(); $path.Dispose()
    } elseif ($hovered) {
      $path = New-RoundedTopPath ($rect.X + (ScaleInt 3)) ($rect.Y + (ScaleInt 7)) ($rect.Width - (ScaleInt 7)) ($rect.Height - (ScaleInt 7)) $radius
      $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 255, 255, 255))
      $g.FillPath($brush, $path)
      $brush.Dispose(); $path.Dispose()
    } else {
      # 未选中：不画底，只在两个"都不是活动标签"的相邻标签之间画一条细分隔线
      $next = $e.Index + 1
      if ($next -lt $tabs.TabPages.Count -and $next -ne $tabs.SelectedIndex -and $script:TabHoverIndex -ne $next) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 160, 172), 1)
        $g.DrawLine($pen, ($rect.Right - 1), ($rect.Y + (ScaleInt 10)), ($rect.Right - 1), ($rect.Bottom - (ScaleInt 10)))
        $pen.Dispose()
      }
    }

    # 3) 文字
    $fgColor = if ($selected) { [System.Drawing.Color]::FromArgb(32, 33, 36) } else { [System.Drawing.Color]::FromArgb(68, 71, 75) }
    $reserve = if ($isSession) { ScaleInt 30 } else { 0 }
    $textRect = New-Object System.Drawing.Rectangle(
      ($rect.X + (ScaleInt 15)),
      ($rect.Y + (ScaleInt 4)),
      [Math]::Max(10, $rect.Width - $reserve - (ScaleInt 20)),
      ($rect.Height - (ScaleInt 4)))
    [System.Windows.Forms.TextRenderer]::DrawText($g, $page.Text, $tabs.Font, $textRect, $fgColor,
      ([System.Windows.Forms.TextFormatFlags]::Left -bor
       [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
       [System.Windows.Forms.TextFormatFlags]::EndEllipsis))

    # 4) ✕（悬停时加个圆形底色，跟 Chrome 一样）
    if ($isSession) {
      $closeRect = Get-TabCloseRect $rect
      $closeHovered = ($hovered -and $script:TabHoverClose)
      if ($closeHovered) {
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(205, 210, 216))
        $g.FillEllipse($brush, $closeRect)
        $brush.Dispose()
      }
      $inkColor = if ($closeHovered) { [System.Drawing.Color]::FromArgb(32, 33, 36) } else { [System.Drawing.Color]::FromArgb(95, 99, 104) }
      $pen = New-Object System.Drawing.Pen($inkColor, 1.6)
      $inset = (ScaleInt 6)
      $g.DrawLine($pen, ($closeRect.X + $inset), ($closeRect.Y + $inset), ($closeRect.Right - $inset), ($closeRect.Bottom - $inset))
      $g.DrawLine($pen, ($closeRect.Right - $inset), ($closeRect.Y + $inset), ($closeRect.X + $inset), ($closeRect.Bottom - $inset))
      $pen.Dispose()
    }
  })

$tabs.add_MouseMove({
    param($sender, $e)
    $index = -1
    $onClose = $false
    for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
      $r = $tabs.GetTabRect($i)
      if ($r.Contains($e.Location)) {
        $index = $i
        if (Test-IsSessionPage $tabs.TabPages[$i]) { $onClose = (Get-TabCloseRect $r).Contains($e.Location) }
        break
      }
    }
    # 只在需要时才动 Cursor，频繁赋值也会触发重绘
    $wanted = if ($onClose) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    if ($tabs.Cursor -ne $wanted) { $tabs.Cursor = $wanted }
    if ($index -ne $script:TabHoverIndex -or $onClose -ne $script:TabHoverClose) {
      $old = $script:TabHoverIndex
      $script:TabHoverIndex = $index
      $script:TabHoverClose = $onClose
      Update-TabVisuals -OldIndex $old -NewIndex $index
    }
  })

$tabs.add_MouseLeave({
    if ($script:TabHoverIndex -ge 0) {
      Update-TabVisuals -OldIndex $script:TabHoverIndex -NewIndex $script:TabHoverIndex
      $script:TabHoverIndex = -1
      $script:TabHoverClose = $false
    }
  })

$tabs.add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
      $r = $tabs.GetTabRect($i)
      if (-not $r.Contains($e.Location)) { continue }
      $page = $tabs.TabPages[$i]
      if ((Test-IsSessionPage $page) -and (Get-TabCloseRect $r).Contains($e.Location)) {
        Close-TerminalSession -Session $page.Tag   # 点 ✕：关掉这个会话
        return
      }
      # 切页之后把焦点交给内容区：一是符合直觉，二是免得 TabControl 拿到焦点后
      # 在标签上画出那个虚线焦点框（挺丑的）
      if (Test-IsSessionPage $page) {
        try { if ($page.Controls.Count -gt 0) { $page.Controls[0].Focus() } } catch { }
      } else {
        try { $lstFolders.Focus() } catch { }
      }
      return
    }
  })

# 终端输出搬运工：ConPTY 的读线程只往队列塞字节，
# 这里在 UI 线程定时取走、再转发给 WebView2（WebView2 只能在 UI 线程调用）。
$script:PumpTimer = New-Object System.Windows.Forms.Timer
$script:PumpTimer.Interval = 30
$script:PumpTimer.add_Tick({
    foreach ($s in @($script:Sessions)) {
      if (-not $s.Closed) { Update-TerminalSession -Session $s }
    }
  })
$script:PumpTimer.Start()

$form.add_FormClosing({
    param($sender, $e)
    $live = @($script:Sessions | Where-Object { -not $_.Closed -and -not $_.Pty.HasExited })
    if ($live.Count -gt 0) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        "还有 $($live.Count) 个终端会话在跑。`n关掉启动器会连同它们一起结束，确定吗？",
        'pwsh 启动器',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        $e.Cancel = $true
        return
      }
    }
    try { $script:PumpTimer.Stop() } catch { }
    foreach ($s in @($script:Sessions)) { Close-TerminalSession -Session $s }
    Save-FolderConfig
  })

# ---------------------------------------------------------------- 启动

Read-FolderConfig
Refresh-FolderList
if ($lstFolders.Items.Count -eq 0) {
  $lblStatus.Text = '还没有常用文件夹 —— 点「添加文件夹…」挑一个（存在本工具目录的 folders.json）'
} else {
  Update-CommandList
}
if ($script:TerminalHostError) {
  $lblStatus.Text = "内置终端不可用（$($script:TerminalHostError)）—— 会退回用 Windows Terminal 打开"
}

[void]$form.ShowDialog()
$form.Dispose()
