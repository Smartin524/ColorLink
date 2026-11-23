using ColorLink.Core;
using Microsoft.Win32;

namespace ColorLink.App;

/// <summary>开机自启：写 HKCU\...\Run，不需要管理员权限</summary>
static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "ColorLink";

    static string Command => $"\"{Environment.ProcessPath}\" --background";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string s && s.Equals(Command, StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(Name, Command);
            else key.DeleteValue(Name, false);
        }
    }

    /// <summary>第一次运行时默认打开开机自启（Mac 版也是这样），之后尊重用户的选择</summary>
    public static void EnableOnFirstRun()
    {
        if (Settings.Shared.GetBool("autostartInitialized", false)) return;
        Settings.Shared.SetBool("autostartInitialized", true);
        try { Enabled = true; } catch (Exception e) { AppLog.Write($"设置开机自启失败：{e.Message}"); }
    }
}

/// <summary>
/// 资源管理器右键「发送到」菜单里的「ColorLink 手机」：选中文件 → 发送到 → 发给手机。
/// 实际是在 shell:sendto 里放一个快捷方式，指向 ColorLink.exe --send；ColorLink 只允许一个实例，
/// 第二个实例把文件列表转给正在运行的那个。
/// </summary>
static class SendToShortcut
{
    static string LinkPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "ColorLink 手机.lnk");

    public static bool Enabled
    {
        get => File.Exists(LinkPath);
        set
        {
            if (!value)
            {
                File.Delete(LinkPath);
                return;
            }
            // WScript.Shell 是系统自带的 COM 组件，用它建快捷方式最省事
            var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("没有 WScript.Shell");
            dynamic shell = Activator.CreateInstance(type)!;
            dynamic link = shell.CreateShortcut(LinkPath);
            link.TargetPath = Environment.ProcessPath;
            link.Arguments = "--send";
            link.IconLocation = Path.Combine(AppContext.BaseDirectory, "Assets", "ColorLink.ico");
            link.Description = "用 ColorLink 发送到手机";
            link.Save();
        }
    }

    /// <summary>第一次运行时默认加上；以后每次启动顺手修正一下路径（程序挪了位置的话）</summary>
    public static void Ensure()
    {
        try
        {
            bool first = !Settings.Shared.GetBool("sendToInitialized", false);
            if (first) Settings.Shared.SetBool("sendToInitialized", true);
            if (first || Enabled) Enabled = true;
        }
        catch (Exception e)
        {
            AppLog.Write($"设置「发送到」菜单失败：{e.Message}");
        }
    }
}

/// <summary>锁屏 / 解锁、睡眠 / 唤醒：电脑没人用时断开手机，手机那边的前台服务随之退掉</summary>
sealed class SessionWatcher : IDisposable
{
    readonly LinkController _link;
    readonly SynchronizationContext _ui;

    public SessionWatcher(LinkController link)
    {
        _link = link;
        _ui = SynchronizationContext.Current!;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        bool? locked = e.Reason switch
        {
            SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect => true,
            SessionSwitchReason.SessionUnlock or SessionSwitchReason.ConsoleConnect or SessionSwitchReason.RemoteConnect => false,
            _ => null,
        };
        if (locked is { } v) _ui.Post(_ => _link.SetLocked(v), null);
    }

    void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) _ui.Post(_ => _link.SetAsleep(true), null);
        else if (e.Mode == PowerModes.Resume) _ui.Post(_ => _link.SetAsleep(false), null);
    }

    public void Dispose()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
    }
}
