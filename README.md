# pwsh 启动器

一个轻量的 Windows 图形小工具：可视化地管理常用工作区目录，选中目录 + 选中命令，点一下就在新终端里开一个 **命令已经敲好、等你按回车** 的 pwsh。

和 `claude-launcher` 是同一套约定（脚本同目录放配置、快捷方式走 `-STA`），区别是它不管 AI，只负责把终端开到你想去的地方、把命令填好。

## 功能

- 左边收藏常用文件夹（添加 / 删除 / 在资源管理器中打开 / 开空终端）
- 左右两栏之间的分隔条**可以直接拖**，改两栏的宽度比例（左栏最窄 220、右栏最窄 260，按 96 DPI 计）
- 自带图标（`icon.ico`）：快捷方式和我们自己的任务栏按钮都用它
- 右边命令**不用手工维护**：读该文件夹 `package.json` 的 `scripts` 生成，常用脚本排前面（dev → build → test → typecheck → lint → dist:win → dist → …），最多 14 条
- 没有 `package.json` 就退回 `git status -sb` / `git pull --ff-only`
- 选中命令后双击或回车 → 新窗口里 `cd` 到该目录并预填命令，**按回车才执行**，执行前还能改
- **内置终端**（默认）：会话长在启动器自己的标签页里，不需要 Windows Terminal，任务栏始终只有一个按钮
- 也可以取消勾选「在启动器内打开」，退回「同一个 Windows Terminal 窗口的不同标签页」模式
- 不常驻、不后台，关掉窗口就结束

## 环境要求

- Windows + PowerShell 7（`pwsh`）
- 建议 `-STA`（和 `claude-launcher` 保持一致）。实测 pwsh 7 在 Windows 上**默认就是 STA**，所以正常启动本来就没问题；万一有人用 `-MTA` 跑，脚本会用 `-STA` 自动重开一份兜底（靠 `PWSH_LAUNCHER_RELAUNCHED` 环境变量防循环，已实测）

## 使用

```powershell
pwsh -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ".\pwsh-launcher.ps1"
```

也可以照上面这行建一个快捷方式，工作目录填本目录，再固定到任务栏。

## 配置

收藏列表在脚本同目录的 `folders.json`（相对 `$PSScriptRoot` 解析，整个文件夹挪走也能用）：

```json
{ "folders": ["C:\\Users\\you\\IdeaProjects\\my-project"] }
```

- 该文件按用户/机器本地生成，已被 `.gitignore` 忽略，不会提交。
- 首次运行是空列表，界面上点「添加文件夹…」即可。

## 三个脚本

| 文件 | 作用 |
| --- | --- |
| `pwsh-launcher.ps1` | 图形界面（WinForms）：文件夹列表 + 命令列表 + 开终端 |
| `open-shell.ps1` | 开一个 pwsh、`cd` 到目标目录、把命令预填进 PSReadLine 缓冲区 |
| `create-shortcut.ps1` | 通用 `.lnk` 生成器，文件头有两段可直接复制的用法 |
| `make-icon.ps1` | 用 GDI+ 画 `icon.ico`（16~256 共 9 个尺寸），改配色/形状就改它再跑一次 |
| `icon.ico` | 图标本体；快捷方式指向它，窗口也加载它 |
| `conpty.cs` | 伪控制台封装（C#/P-Invoke）：起无窗口的 pwsh、读输出、写输入、改尺寸 |
| `terminal-session.ps1` | 把 ConPTY 和 xterm.js 接起来：标签页、消息路由、输出搬运 |
| `web/terminal.html` | xterm.js 宿主页面（在 WebView2 里跑） |
| `fetch-deps.ps1` | 下载 WebView2 SDK 和 xterm.js 到 `vendor/`（不进 git） |

## 内置终端是怎么实现的

和 IDEA（pty4j + 自带模拟器）、VS Code（node-pty + xterm.js）是同一个套路，**不是**去复用系统的控制台窗口：

```
pwsh ──(伪控制台/ConPTY)──> 字节流（VT 控制序列）──> WebView2 里的 xterm.js ──> 画成字符网格
  ^                                                                              │
  └──────────────── 键盘输入 ────── postMessage ─────────────────────────────────┘
```

伪控制台没有窗口，所以任务栏干干净净；VT 序列的解析与绘制交给 xterm.js。

### 关键实现细节（都踩过坑）

- **`CreateProcess` 必须显式 `STARTF_USESTDHANDLES` + 三个句柄给 NULL**。不指定的话，子进程会把*父进程所在控制台*的句柄继承下去：它一边挂在新的伪控制台上（`mode con` 报的是 pty 的尺寸），一边把输出写进父进程的控制台 —— 表现就是"pty 里什么都收不到"。实测不指定时一个字节都拿不到。
- **ConPTY 的读线程绝不回调 PowerShell**，只往 `ConcurrentQueue` 里塞；UI 线程用 30ms 定时器 `DrainOutput()` 取走再转给 WebView2（WebView2 只能在 UI 线程调，后台线程直接调脚本块还会踩 runspace 亲和性）。
- **事件回调里不要依赖闭包捕获函数局部变量**。PowerShell 里从函数内部创建的事件处理器，回调触发时局部变量已经取不到了（`$webView` 会是 `$null`），于是 `SetVirtualHostNameToFolderMapping` 报 "null-valued expression"，标签页一片黑。现在统一用 `$sender.Tag` 和按 `CoreWebView2` 反查会话。
- **`CoreWebView2Environment.CreateAsync` 的第一个参数是 `browserExecutableFolder`**（固定版本模式），不是用户数据目录；传 `$null` 才用系统装的 Evergreen 运行时。必须在建窗口之前同步等（等 UI 起来再阻塞会死锁）。
- `WebView2Loader.dll` 是原生库，得先 `NativeLibrary.Load` 到进程里，托管侧才找得到。
- 布局用 `Dock` 而不是绝对坐标：`SplitContainer` 改成 `Dock=Fill` 之后，布局前的宽度还是默认值，此时设 `SplitterDistance` 会直接抛异常，得挪到窗口 `Shown` 里设。

### 已知限制

- 每个会话一个 WebView2 控件，各自有渲染进程（几十 MB 量级），开很多个会吃内存。
- 会话绑在启动器生命周期上：关掉启动器，里面的会话一起结束（关闭前会确认）。
- 中文输入法处于**组字状态**时，回车会被输入法吃掉（所有终端都这样），要执行命令先按 Esc 或切到英文输入。

## 任务栏图标是怎么生效的（重要）

任务栏按钮的**图标和名字都不来自 .lnk**，而是按 **AppUserModelID** 分组后取那一组的信息。所以：

- 用 `pwsh.exe` 启动的窗口，默认会被并进「PowerShell / 终端」那一组 —— 你设的 `Form.Icon` 根本不会出现在任务栏按钮上（claude-launcher 图标"加载不出来"就是这个原因，跟 .ico 文件本身无关）。
- 解决办法是给**窗口**写一个自己的 AppUserModelID：`PwshLauncher.AppId` 那段 C# 往窗口的 `IPropertyStore` 里写 `PKEY_AppUserModel_ID`。
- **进程级**的 `SetCurrentProcessExplicitAppUserModelID` 在 pwsh 里已经太晚（控制台窗口早就建好了），实测不生效。
- 任务栏按钮的名字目前显示为「PowerShell 7」（未注册的 AUMID 会退回去用 exe 的名字）。想让名字也变成「pwsh 启动器」，需要在开始菜单放一个同名快捷方式并把 AUMID 写上；图标不受这个影响。

## 标签页行为怎么调

开终端走的是 `wt.exe -w <窗口名> nt …`，所以标签页去哪由这一个参数决定：

| 想要的效果 | 改法 |
| --- | --- |
| 全都进同一个专属窗口（默认） | `-TerminalWindowName 'pwsh-launcher'` |
| 进「当前/最近用的」那个 WT 窗口 | `-TerminalWindowName '0'` |
| 每次都开新窗口（老行为） | `-TerminalWindowName '-1'` |
| 本机没装 WT | 自动退回 `Start-Process pwsh` 开新窗口 |

改完记得同步改快捷方式里的命令行（或者直接把 `pwsh-launcher.ps1` 的参数默认值改掉）。

## 维护备忘（踩过的坑，别改回去）

- **预填必须走 `PowerShell.OnIdle` 事件**。`pwsh -Command "...Insert('x')"` 会抛 `Object reference not set to an instance of an object`——`-Command` 阶段 PSReadLine 的缓冲区还没建好。`-MaxTriggerCount 1` 保证只插一次。
- **不要在 pwsh 里用 WinForms 的 `AutoScaleMode='Dpi'`**。实测不生效：字号跟着 DPI 变大、控件尺寸不变，缩放一高就把文字挤出去。现在是布局按 96 DPI 写死、运行时用 `ScaleInt`/`ScalePoint`/`ScaleSize` 乘 `GetDpiForSystem()/96`。
- **辅助函数不要起短名**。命令解析优先级是「别名 > 函数」，最初把缩放函数叫 `SP`，直接撞上 `sp`（`Set-ItemProperty` 的别名），脚本卡在参数提示上、窗口根本出不来。`ScaleInt`/`ScalePoint`/`ScaleSize` 是改过名的。
- `.ps1` 一律存 **UTF-8 BOM + CRLF**。无 BOM 时 Windows PowerShell 5.1 会按 GBK 读，中文注释能把下一行代码吞进注释里（真发生过）。
- **`wt.exe` 是 GUI 程序**：用 `&` 调它不会等它退出、也不会更新 `$LASTEXITCODE`，所以别写 `if ($LASTEXITCODE -eq 0) { return }` 来判断成功——那读的是上一条命令的残留值，会误判成失败并再开一个窗口。
- **测试完记得收标签页**：WT 默认 `closeOnExit: graceful`，进程被强杀后标签页会留在那儿；关窗口会弹「是否要关闭所有标签页?」确认框。
- **快捷方式用 `conhost.exe --headless` 当宿主**，不要用 `pwsh -WindowStyle Hidden`：后者在「默认终端 = Windows Terminal」的机器上会额外造一个**隐藏的 WT 窗口**，任务栏「终端」组的计数会白白 +1（点进去是个看不见的窗口）。`--headless` 的 conhost 不建窗口，计数干净。代价是这台机器必须是 Win11（`--headless` 参数是 conhost 重写后加的）。
- **任务栏分组看 AUMID，不看窗口图标**：详见上一节。别指望只设 `Form.Icon` 就能让任务栏显示自己的图标。
