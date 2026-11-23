using System.Runtime.InteropServices;
using Microsoft.Win32;
using static ColorLink.App.Native;

namespace ColorLink.App;

/// <summary>
/// 通知区域（托盘）图标。直接用 Shell_NotifyIcon，不引第三方库：
/// 左键点一下弹出面板，右键弹出系统原生菜单；任务栏深浅色变了换对应颜色的图标，Explorer 重启后自动重新加上。
/// </summary>
sealed class TrayIcon : IDisposable
{
    const uint CallbackMessage = WM_APP + 1;
    const uint IconId = 1;

    readonly WndProc _proc; // 留着引用，免得被回收
    readonly IntPtr _hwnd;
    readonly uint _taskbarCreated;
    IntPtr _icon;
    bool _added;
    bool _connected;
    string _tip = "ColorLink";

    public event Action? LeftClick;
    public event Action? RightClick;

    public IntPtr Handle => _hwnd;

    public TrayIcon()
    {
        _proc = Proc;
        var wc = new WNDCLASSEX
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc),
            hInstance = GetModuleHandle(null),
            lpszClassName = "ColorLinkTrayWindow",
        };
        RegisterClassEx(ref wc);
        // 普通的隐藏顶层窗口（不是 message-only），才能收到 TaskbarCreated 广播
        _hwnd = CreateWindowEx(0, wc.lpszClassName, "ColorLink", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        Add();
    }

    /// <summary>连接状态：连着是彩色链环，断开是淡色单色链环</summary>
    public void SetState(bool connected, string tip)
    {
        _connected = connected;
        _tip = tip.Length > 120 ? tip[..120] : tip;
        Update();
    }

    static bool TaskbarIsLight()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    IntPtr LoadIcon()
    {
        // 连上：彩色链环（和应用图标一样）；断开：跟任务栏深浅色走的淡色单色链环。16px 下只靠透明度区分看不出来
        var name = _connected ? "ColorLink.ico" : $"Tray-{(TaskbarIsLight() ? "Light" : "Dark")}-Off.ico";
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", name);
        uint dpi = GetDpiForWindow(_hwnd) is var d and > 0 ? d : GetDpiForSystem();
        int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
        return LoadImage(IntPtr.Zero, path, IMAGE_ICON, size, size, LR_LOADFROMFILE);
    }

    NOTIFYICONDATA Data()
    {
        var old = _icon;
        _icon = LoadIcon();
        if (old != IntPtr.Zero) DestroyIcon(old);
        return new NOTIFYICONDATA
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = IconId,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage = CallbackMessage,
            hIcon = _icon,
            szTip = _tip,
            szInfo = "",
            szInfoTitle = "",
        };
    }

    void Add()
    {
        var d = Data();
        _added = Shell_NotifyIcon(NIM_ADD, ref d);
        d.uVersion = 4; // NOTIFYICON_VERSION_4：点击报 NIN_SELECT、右键报 WM_CONTEXTMENU，并带上坐标
        Shell_NotifyIcon(NIM_SETVERSION, ref d);
    }

    void Update()
    {
        if (!_added)
        {
            Add();
            return;
        }
        var d = Data();
        Shell_NotifyIcon(NIM_MODIFY, ref d);
    }

    /// <summary>托盘图标在屏幕上的位置（物理像素）；拿不到时返回 null</summary>
    public RECT? GetRect()
    {
        var id = new NOTIFYICONIDENTIFIER { cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = _hwnd, uID = IconId };
        return Shell_NotifyIconGetRect(ref id, out var r) == 0 ? r : null;
    }

    /// <param name="Check">null：普通菜单项；true / false：带勾选的开关</param>
    public sealed record MenuItem(string Title, Action? Run, bool? Check = null, bool Enabled = true)
    {
        public static readonly MenuItem Separator = new("-", null);
        public bool Checkable => Check is not null;
        public bool Checked => Check == true;
    }

    /// <summary>在鼠标位置弹出系统原生菜单</summary>
    public void ShowMenu(IReadOnlyList<MenuItem> items)
    {
        var menu = CreatePopupMenu();
        for (int i = 0; i < items.Count; i++)
        {
            var it = items[i];
            if (ReferenceEquals(it, MenuItem.Separator))
                AppendMenu(menu, MF_SEPARATOR, UIntPtr.Zero, null);
            else
                AppendMenu(menu, MF_STRING | (it.Checked ? MF_CHECKED : 0) | (it.Enabled ? 0 : MF_GRAYED), (UIntPtr)(i + 1), it.Title);
        }
        GetCursorPos(out var p);
        // 不先把自己设为前台窗口，点菜单外面时菜单不会消失
        SetForegroundWindow(_hwnd);
        uint cmd = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_RIGHTALIGN, p.X, p.Y, _hwnd, IntPtr.Zero);
        PostMessage(_hwnd, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(menu);
        if (cmd > 0 && cmd <= items.Count) items[(int)cmd - 1].Run?.Invoke();
    }

    IntPtr Proc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == CallbackMessage)
        {
            switch (LoWord(lParam))
            {
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    LeftClick?.Invoke();
                    break;
                case WM_CONTEXTMENU:
                    RightClick?.Invoke();
                    break;
            }
            return IntPtr.Zero;
        }
        if (msg == _taskbarCreated)
        {
            // Explorer 重启了，图标要重新加
            _added = false;
            Add();
            return IntPtr.Zero;
        }
        if (msg == WM_SETTINGCHANGE && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            // 任务栏深浅色变了
            Update();
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        var d = new NOTIFYICONDATA { cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(), hWnd = _hwnd, uID = IconId, szTip = "", szInfo = "", szInfoTitle = "" };
        Shell_NotifyIcon(NIM_DELETE, ref d);
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        DestroyWindow(_hwnd);
    }
}
