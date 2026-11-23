using System.Runtime.InteropServices;

namespace ColorLink.Shell;

/// <summary>
/// COM 服务进程：注册「发送到手机」命令的类工厂，资源管理器用完后空闲一会儿自己退出。
/// 由稀疏包清单（tools/context-menu/AppxManifest.xml）里的 com:ExeServer 声明，资源管理器按需启动。
/// </summary>
static class Program
{
    public static readonly Guid Clsid = new("439BE09B-BA94-42A6-AF64-A06F628AFD16");

    /// <summary>最后一次被资源管理器用到的时间；空闲超过这么久就退出</summary>
    static long _lastUse = Environment.TickCount64;
    static readonly TimeSpan IdleExit = TimeSpan.FromMinutes(2);

    public static void Touch() => Interlocked.Exchange(ref _lastUse, Environment.TickCount64);

    [MTAThread]
    static int Main(string[] args)
    {
        // 直接双击运行没有意义，只做 COM 服务
        if (!args.Any(a => a.TrimStart('-', '/').Equals("Embedding", StringComparison.OrdinalIgnoreCase))) return 0;

        var clsid = Clsid;
        int hr = CoRegisterClassObject(ref clsid, new CommandFactory(), 4 /* CLSCTX_LOCAL_SERVER */, 1 /* REGCLS_MULTIPLEUSE */, out uint cookie);
        if (hr < 0) return hr;
        while (Environment.TickCount64 - Interlocked.Read(ref _lastUse) < IdleExit.TotalMilliseconds)
            Thread.Sleep(5000);
        CoRevokeClassObject(cookie);
        return 0;
    }

    /// <summary>和 ColorLink.exe 放在同一个文件夹</summary>
    public static string AppExe => Path.Combine(AppContext.BaseDirectory, "ColorLink.exe");

    /// <summary>
    /// 菜单标题用配对手机的名字：「发送到 Find X9 Ultra」。ColorLink 把缩短后的名字写在同一目录的 phone-name.txt。
    /// 不读 %LOCALAPPDATA%\ColorLink 和 HKCU：本程序带包标识运行，AppData 和 HKCU 都是包自己的私有视图，看不到 ColorLink 的数据；
    /// 安装目录（包的外部位置）是真实的。
    /// </summary>
    public static string Title()
    {
        try
        {
            var name = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "phone-name.txt")).Trim();
            if (name.Length > 0) return $"发送到 {name}";
        }
        catch
        {
            // 还没配对：用通用的名字
        }
        return "发送到 ColorLink 手机";
    }

    /// <summary>
    /// 交给 ColorLink.exe --send。要让它跑在包环境外面（breakaway）：
    /// 否则它继承本进程的包标识，看到的是包私有的 AppData，也找不到正在运行的那份 ColorLink 来转交。
    /// </summary>
    public static void Send(IReadOnlyList<string> files)
    {
        if (files.Count == 0) return;
        var cmd = new System.Text.StringBuilder(Quote(AppExe)).Append(" --send");
        foreach (var f in files) cmd.Append(' ').Append(Quote(f));

        nint size = 0;
        InitializeProcThreadAttributeList(0, 1, 0, ref size);
        var list = Marshal.AllocHGlobal(size);
        var policy = Marshal.AllocHGlobal(sizeof(uint));
        try
        {
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new System.ComponentModel.Win32Exception();
            Marshal.WriteInt32(policy, PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_OVERRIDE);
            if (!UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY, policy, sizeof(uint), 0, 0))
                throw new System.ComponentModel.Win32Exception();
            var si = new STARTUPINFOEX { StartupInfo = { cb = Marshal.SizeOf<STARTUPINFOEX>() }, AttributeList = list };
            if (!CreateProcess(AppExe, cmd, 0, 0, false, EXTENDED_STARTUPINFO_PRESENT, 0, AppContext.BaseDirectory, ref si, out var pi))
                throw new System.ComponentModel.Win32Exception();
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
        }
        finally
        {
            DeleteProcThreadAttributeList(list);
            Marshal.FreeHGlobal(list);
            Marshal.FreeHGlobal(policy);
        }
    }

    static string Quote(string s) => "\"" + s.Replace("\"", "\\\"") + "\"";

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x80000;
    const nint PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY = 0x20012;
    const int PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_OVERRIDE = 0x4;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public nint lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public nint AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public nint hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(nint list, int count, int flags, ref nint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(nint list, uint flags, nint attribute, nint value, nint size, nint previous, nint returnSize);

    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(nint list);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, System.Text.StringBuilder cmd, nint procAttr, nint threadAttr, bool inherit, uint flags,
        nint env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(nint h);

    [DllImport("ole32.dll")]
    static extern int CoRegisterClassObject(ref Guid clsid, [MarshalAs(UnmanagedType.IUnknown)] object factory, uint context, uint flags, out uint cookie);

    [DllImport("ole32.dll")]
    static extern int CoRevokeClassObject(uint cookie);
}

[ComVisible(true)]
sealed class CommandFactory : IClassFactory
{
    const int CLASS_E_NOAGGREGATION = unchecked((int)0x80040110);

    public int CreateInstance(IntPtr outer, ref Guid riid, out IntPtr ppv)
    {
        ppv = IntPtr.Zero;
        if (outer != IntPtr.Zero) return CLASS_E_NOAGGREGATION;
        Program.Touch();
        var unk = Marshal.GetIUnknownForObject(new SendCommand());
        try { return Marshal.QueryInterface(unk, in riid, out ppv); }
        finally { Marshal.Release(unk); }
    }

    public int LockServer(bool fLock) => 0;
}

/// <summary>右键菜单里的「发送到 手机名」</summary>
[ComVisible(true)]
sealed class SendCommand : IExplorerCommand
{
    const int S_OK = 0, E_NOTIMPL = unchecked((int)0x80004001);
    const uint SIGDN_FILESYSPATH = 0x80058000;

    public int GetTitle(IntPtr items, out IntPtr name)
    {
        Program.Touch();
        name = Marshal.StringToCoTaskMemUni(Program.Title());
        return S_OK;
    }

    public int GetIcon(IntPtr items, out IntPtr icon)
    {
        icon = Marshal.StringToCoTaskMemUni(Program.AppExe + ",0");
        return S_OK;
    }

    public int GetToolTip(IntPtr items, out IntPtr tip)
    {
        tip = IntPtr.Zero;
        return E_NOTIMPL;
    }

    public int GetCanonicalName(out Guid guid)
    {
        guid = Program.Clsid;
        return S_OK;
    }

    public int GetState(IntPtr items, bool okToBeSlow, out uint state)
    {
        state = 0; // ECS_ENABLED
        return S_OK;
    }

    public int Invoke(IntPtr items, IntPtr bindCtx)
    {
        Program.Touch();
        try { Program.Send(Paths(items)); }
        catch
        {
            // 发不出去也不能让资源管理器报错
        }
        return S_OK;
    }

    public int GetFlags(out uint flags)
    {
        flags = 0; // ECF_DEFAULT
        return S_OK;
    }

    public int EnumSubCommands(out IntPtr commands)
    {
        commands = IntPtr.Zero;
        return E_NOTIMPL;
    }

    /// <summary>选中的文件（文件夹等没有文件路径的跳过）</summary>
    static List<string> Paths(IntPtr items)
    {
        var list = new List<string>();
        if (items == IntPtr.Zero) return list;
        var array = (IShellItemArray)Marshal.GetObjectForIUnknown(items);
        try
        {
            array.GetCount(out uint count);
            for (uint i = 0; i < count; i++)
            {
                array.GetItemAt(i, out var item);
                try
                {
                    if (item.GetDisplayName(SIGDN_FILESYSPATH, out var p) >= 0 && p != IntPtr.Zero)
                    {
                        var path = Marshal.PtrToStringUni(p);
                        Marshal.FreeCoTaskMem(p);
                        if (path is not null && File.Exists(path)) list.Add(path);
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(item);
                }
            }
        }
        finally
        {
            Marshal.ReleaseComObject(array);
        }
        return list;
    }
}

[ComImport, Guid("00000001-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IClassFactory
{
    [PreserveSig] int CreateInstance(IntPtr outer, ref Guid riid, out IntPtr ppv);
    [PreserveSig] int LockServer([MarshalAs(UnmanagedType.Bool)] bool fLock);
}

[ComImport, Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IExplorerCommand
{
    [PreserveSig] int GetTitle(IntPtr items, out IntPtr name);
    [PreserveSig] int GetIcon(IntPtr items, out IntPtr icon);
    [PreserveSig] int GetToolTip(IntPtr items, out IntPtr tip);
    [PreserveSig] int GetCanonicalName(out Guid guid);
    [PreserveSig] int GetState(IntPtr items, [MarshalAs(UnmanagedType.Bool)] bool okToBeSlow, out uint state);
    [PreserveSig] int Invoke(IntPtr items, IntPtr bindCtx);
    [PreserveSig] int GetFlags(out uint flags);
    [PreserveSig] int EnumSubCommands(out IntPtr commands);
}

[ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellItemArray
{
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetPropertyStore(int flags, ref Guid riid, out IntPtr ppv);
    void GetPropertyDescriptionList(IntPtr keyType, ref Guid riid, out IntPtr ppv);
    void GetAttributes(int attribFlags, uint sfgaoMask, out uint attribs);
    void GetCount(out uint count);
    void GetItemAt(uint index, out IShellItem item);
    void EnumItems(out IntPtr enumShellItems);
}

[ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellItem
{
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem parent);
    [PreserveSig] int GetDisplayName(uint sigdn, out IntPtr name);
    void GetAttributes(uint sfgaoMask, out uint attribs);
    void Compare(IShellItem other, uint hint, out int order);
}
