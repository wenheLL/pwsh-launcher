// ConPTY 的最小封装：起一个跑在「伪控制台」里的子进程，把它的输出流当字节读出来，
// 再把键盘输入写回去。IDE 里的终端就是这套东西（IDEA 用 pty4j，VS Code 用 node-pty）。
//
// 关键点：
//  - 伪控制台没有窗口，所以不会在任务栏留下任何东西；
//  - 输出是一串 VT 控制序列，解析/渲染由前端（xterm.js）负责，这里只管搬运字节；
//  - 唯一的 API 是 CreatePseudoConsole / ResizePseudoConsole / ClosePseudoConsole（Win10 1809+）。
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace PwshLauncher
{
    public sealed class ConPty : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct COORD
        {
            public short X;
            public short Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr hObject, int dwMask, int dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcess(string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
            bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
            ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        private const int HANDLE_FLAG_INHERIT = 0x1;
        private const int STARTF_USESTDHANDLES = 0x100;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;

        private IntPtr hPC = IntPtr.Zero;
        private IntPtr hProcess = IntPtr.Zero;
        private FileStream input;
        private FileStream output;
        private Thread reader;
        private Thread waiter;
        private volatile bool disposed;

        // 读线程只往队列里塞，绝不回调进 PowerShell ——
        // 后台线程直接调用 PowerShell 脚本块会踩 runspace 亲和性（"There is no Runspace available"），
        // UI 那侧用定时器调 DrainOutput() 取走即可。
        private readonly ConcurrentQueue<byte[]> pending = new ConcurrentQueue<byte[]>();

        public int ProcessId { get; private set; }
        public bool HasExited { get; private set; }
        public int ExitCode { get; private set; }

        public ConPty(string commandLine, string workingDirectory, int cols, int rows)
        {
            SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
            sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            sa.bInheritHandle = 1;

            IntPtr ptyIn, ourIn, ptyOut, ourOut;
            if (!CreatePipe(out ptyIn, out ourIn, ref sa, 0)) throw NewWin32("CreatePipe(stdin)");
            if (!CreatePipe(out ourOut, out ptyOut, ref sa, 0)) throw NewWin32("CreatePipe(stdout)");
            // 我们这一端不能被继承，否则子进程拿着句柄不放，读的时候永远等不到 EOF
            SetHandleInformation(ourIn, HANDLE_FLAG_INHERIT, 0);
            SetHandleInformation(ourOut, HANDLE_FLAG_INHERIT, 0);

            int hr = CreatePseudoConsole(new COORD { X = (short)cols, Y = (short)rows }, ptyIn, ptyOut, 0, out hPC);
            if (hr != 0) throw new InvalidOperationException("CreatePseudoConsole 失败: 0x" + hr.ToString("X8"));

            IntPtr attrSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
            IntPtr attrList = Marshal.AllocHGlobal(attrSize);
            try
            {
                if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize)) throw NewWin32("InitializeProcThreadAttributeList");
                if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                    throw NewWin32("UpdateProcThreadAttribute");

                STARTUPINFOEX si = new STARTUPINFOEX();
                si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                si.lpAttributeList = attrList;

                // 【别删这三行】必须显式指定标准句柄、并且都给 NULL。
                // 不指定的话，子进程会把【父进程所在控制台】的句柄继承下去：
                // 结果是它一边挂在新的伪控制台上（mode con 报的是 pty 尺寸），
                // 一边把输出写进父进程的控制台 —— 表现就是"pty 里什么都收不到"。
                // 实测 stdMode=0（不指定）拿不到任何输出，设为 NULL 才正常。
                si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                si.StartupInfo.hStdInput = IntPtr.Zero;
                si.StartupInfo.hStdOutput = IntPtr.Zero;
                si.StartupInfo.hStdError = IntPtr.Zero;

                PROCESS_INFORMATION pi;
                bool ok = CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, true, EXTENDED_STARTUPINFO_PRESENT,
                    IntPtr.Zero, workingDirectory, ref si, out pi);
                if (!ok) throw NewWin32("CreateProcess");

                hProcess = pi.hProcess;
                ProcessId = pi.dwProcessId;
                CloseHandle(pi.hThread);
            }
            finally
            {
                DeleteProcThreadAttributeList(attrList);
                Marshal.FreeHGlobal(attrList);
                // 子进程已经拿到伪控制台两端的副本，父进程把这两个原始句柄关掉
                CloseHandle(ptyIn);
                CloseHandle(ptyOut);
            }

            input = new FileStream(new SafeFileHandle(ourIn, true), FileAccess.Write);
            output = new FileStream(new SafeFileHandle(ourOut, true), FileAccess.Read);

            reader = new Thread(ReadLoop);
            reader.IsBackground = true;
            reader.Name = "ConPty.Reader";
            reader.Start();

            waiter = new Thread(WaitLoop);
            waiter.IsBackground = true;
            waiter.Name = "ConPty.Waiter";
            waiter.Start();
        }

        private static Exception NewWin32(string what)
        {
            return new InvalidOperationException(what + " 失败, Win32 错误码 " + Marshal.GetLastWin32Error());
        }

        private void ReadLoop()
        {
            byte[] buffer = new byte[8192];
            try
            {
                while (!disposed)
                {
                    int n = output.Read(buffer, 0, buffer.Length);
                    if (n <= 0) break;
                    byte[] chunk = new byte[n];
                    Buffer.BlockCopy(buffer, 0, chunk, 0, n);
                    pending.Enqueue(chunk);
                }
            }
            catch (Exception)
            {
                // 伪控制台被关掉时这里会抛，属于正常收尾
            }
        }

        private void WaitLoop()
        {
            try
            {
                if (hProcess != IntPtr.Zero) WaitForSingleObject(hProcess, 0xFFFFFFFF);
            }
            catch (Exception) { }
            try
            {
                uint code;
                if (GetExitCodeProcess(hProcess, out code)) ExitCode = (int)code;
            }
            catch (Exception) { }
            HasExited = true;
        }

        /// <summary>从 UI 线程调用：把攒下的输出一次性取走（没有新数据时返回 null）。</summary>
        public byte[] DrainOutput()
        {
            if (pending.IsEmpty) return null;
            List<byte> all = new List<byte>();
            byte[] chunk;
            while (pending.TryDequeue(out chunk))
            {
                if (chunk != null) all.AddRange(chunk);
            }
            return all.ToArray();
        }

        /// <summary>把键盘输入（UTF-8 字节）送进伪控制台。</summary>
        public void WriteBytes(byte[] data)
        {
            if (disposed || data == null || data.Length == 0) return;
            try
            {
                input.Write(data, 0, data.Length);
                input.Flush();
            }
            catch (Exception) { }
        }

        /// <summary>告诉 shell 终端尺寸变了（前端 fit 之后调用）。</summary>
        public void Resize(int cols, int rows)
        {
            if (disposed || hPC == IntPtr.Zero) return;
            if (cols <= 0 || rows <= 0) return;
            ResizePseudoConsole(hPC, new COORD { X = (short)cols, Y = (short)rows });
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;

            // 顺序有讲究：先关输入写端让 shell 收到 EOF 自行退出，再关伪控制台，最后兜底 kill。
            try { if (input != null) input.Dispose(); } catch { }
            try { if (hPC != IntPtr.Zero) ClosePseudoConsole(hPC); } catch { }
            hPC = IntPtr.Zero;

            try
            {
                if (hProcess != IntPtr.Zero && WaitForSingleObject(hProcess, 800) != 0)
                {
                    TerminateProcess(hProcess, 1);
                }
            }
            catch { }

            try { if (output != null) output.Dispose(); } catch { }
            try { if (hProcess != IntPtr.Zero) CloseHandle(hProcess); } catch { }
            hProcess = IntPtr.Zero;
        }
    }
}
