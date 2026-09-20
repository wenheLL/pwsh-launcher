#requires -version 7
<#
.SYNOPSIS
  pwsh 启动器：左边管理常用文件夹，右边选命令，点一下开一个「命令已预填」的 pwsh。

.DESCRIPTION
  设计约定：
  - 文件夹列表存在脚本同目录的 folders.json（相对 $PSScriptRoot，整个文件夹挪走也能用）。
  - 右侧命令不需要手工维护：读该文件夹 package.json 的 scripts 生成，常用脚本按优先级排前面。
    没有 package.json 就退回几条通用 git 命令。
  - 开终端走 wt.exe -w <窗口名> nt，所以所有会话都落在同一个 Windows Terminal 窗口的不同标签页里；
    想换行为就改 -TerminalWindowName（'0' = 当前 WT 窗口，'-1' = 每次新窗口）。
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
  [string]$TerminalWindowName = 'pwsh-launcher'
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

# ---------------------------------------------------------------- 界面

$form = New-Object System.Windows.Forms.Form
$form.Text = 'pwsh 启动器'
$form.AutoScaleMode = 'None' # 缩放自己算，见上面的 ScaleInt/ScalePoint/ScaleSize
$form.ClientSize = ScaleSize 920 496
$form.MinimumSize = ScaleSize 780 440
$form.StartPosition = 'CenterScreen'
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch { }

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

# 左右两栏装进 SplitContainer：中间那条分隔条可以直接左右拖，改两栏宽度比例。
# 底部按钮一律留在表单上（不进左栏面板）——否则左栏被拖窄时按钮会被挤没。
$split = New-Object System.Windows.Forms.SplitContainer
$split.Location = ScalePoint 12 12
$split.Size = ScaleSize 896 380
$split.Anchor = 'Top,Left,Right,Bottom'
$split.SplitterWidth = ScaleInt 6
$split.Panel1MinSize = ScaleInt 220
$split.Panel2MinSize = ScaleInt 260
$split.SplitterDistance = ScaleInt 400
$split.Panel1.BorderStyle = 'FixedSingle'
$split.Panel2.BorderStyle = 'FixedSingle'
$split.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235) # 分隔条的颜色：看得出来能拖
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

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = '添加文件夹…'
$btnAdd.Location = ScalePoint 12 404
$btnAdd.Size = ScaleSize 130 32
$btnAdd.Anchor = 'Left,Bottom'

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = '移除'
$btnRemove.Location = ScalePoint 150 404
$btnRemove.Size = ScaleSize 70 32
$btnRemove.Anchor = 'Left,Bottom'

$btnExplorer = New-Object System.Windows.Forms.Button
$btnExplorer.Text = '资源管理器'
$btnExplorer.Location = ScalePoint 228 404
$btnExplorer.Size = ScaleSize 110 32
$btnExplorer.Anchor = 'Left,Bottom'

$btnEmpty = New-Object System.Windows.Forms.Button
$btnEmpty.Text = '空终端'
$btnEmpty.Location = ScalePoint 346 404
$btnEmpty.Size = ScaleSize 66 32
$btnEmpty.Anchor = 'Left,Bottom'

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
$btnOpen.Location = ScalePoint 436 404
$btnOpen.Size = ScaleSize 472 32
$btnOpen.Anchor = 'Left,Right,Bottom'

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = ScalePoint 12 444
$lblStatus.Size = ScaleSize 896 44
$lblStatus.Anchor = 'Left,Right,Bottom'
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$form.Controls.AddRange(@(
  $split, $btnAdd, $btnRemove, $btnExplorer, $btnEmpty, $btnOpen, $lblStatus
))
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

$form.add_FormClosing({ Save-FolderConfig })

# ---------------------------------------------------------------- 启动

Read-FolderConfig
Refresh-FolderList
if ($lstFolders.Items.Count -eq 0) {
  $lblStatus.Text = '还没有常用文件夹 —— 点「添加文件夹…」挑一个（存在本工具目录的 folders.json）'
} else {
  Update-CommandList
}

[void]$form.ShowDialog()
$form.Dispose()
