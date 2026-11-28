using System.Runtime.InteropServices;
using ColorLink.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace ColorLink.App;

/// <summary>
/// 托盘常驻程序：没有主窗口。左键点托盘图标弹出面板，右键弹出菜单。
/// 启动参数：--background（开机自启，不弹窗）、--send 文件…（资源管理器「发送到」）。
/// </summary>
public partial class App : Application
{
    public static new App? Current { get; private set; }

    internal Platform Platform { get; } = new();
    LinkController? _link;
    TrayIcon? _tray;
    PanelWindow? _panel;
    GalleryWindow? _gallery;
    PairWindow? _pair;
    SessionWatcher? _session;
    DispatcherQueue? _dispatcher;

    public App()
    {
        Current = this;
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            AppLog.Write($"未处理的异常：{e.Exception}");
            e.Handled = true;
        };
    }

    LinkController Link => _link!;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        // 关掉所有窗口也不退出，常驻托盘
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        // 调试用：COLORLINK_DATA 指定单独的数据目录，并且不碰开机自启和「发送到」菜单
        bool sandbox = Environment.GetEnvironmentVariable("COLORLINK_DATA") is { Length: > 0 } dataDir;
        if (sandbox)
        {
            AppDirs.Root = Environment.GetEnvironmentVariable("COLORLINK_DATA")!;
            AppDirs.Downloads = Path.Combine(AppDirs.Root, "Downloads");
        }
        AppLog.Write($"ColorLink 启动（{Environment.ProcessPath}）");

        Platform.SetUpNotifications();
        _link = new LinkController(Platform);
        _tray = new TrayIcon();
        _tray.LeftClick += () => Panel.Toggle(_tray);
        _tray.RightClick += () => _tray.ShowMenu(MenuItems(forPanel: false));
        _link.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(LinkController.State) or nameof(LinkController.Info) or nameof(LinkController.StateDetail)) UpdateTray();
        };
        UpdateTray();
        _session = new SessionWatcher(_link);
        if (!sandbox)
        {
            Autostart.EnableOnFirstRun();
            SendToShortcut.Ensure();
        }

        HandleCommandLine(Environment.GetCommandLineArgs().Skip(1).ToList(), firstLaunch: true);
    }

    PanelWindow Panel => _panel ??= new PanelWindow(Link);

    void UpdateTray()
    {
        var tip = Link.State switch
        {
            LinkState.Connected => $"ColorLink：已连接 {Link.StateDetail}" + (Link.Info?.Battery is { } b ? $"（{b}%）" : ""),
            LinkState.Connecting => "ColorLink：正在连接…",
            LinkState.NeedsPairing => "ColorLink：待配对",
            LinkState.Paused => "ColorLink：已暂停（电脑锁屏）",
            _ => "ColorLink：手机未连接",
        };
        _tray?.SetState(Link.IsConnected, tip);
    }

    /// <summary>托盘右键菜单和面板「⋯」菜单共用</summary>
    internal List<TrayIcon.MenuItem> MenuItems(bool forPanel)
    {
        var items = new List<TrayIcon.MenuItem>();
        if (!forPanel)
        {
            items.Add(new("打开面板", () => Panel.ShowPanel(_tray!)));
            items.Add(new("打开相册", ShowGallery, Enabled: Link.Library is not null));
            items.Add(new("发送文件到手机…", () => _ = PickAndSendAsync(), Enabled: Link.IsConnected));
            items.Add(TrayIcon.MenuItem.Separator);
        }
        items.Add(new("截图自动复制到剪贴板", () => Link.AutoCopyScreenshots = !Link.AutoCopyScreenshots, Link.AutoCopyScreenshots));
        items.Add(new("同步通知", () => Link.MirrorNotifications = !Link.MirrorNotifications, Link.MirrorNotifications));
        items.Add(new("短信验证码自动复制", () => Link.AutoCopyCodes = !Link.AutoCopyCodes, Link.AutoCopyCodes, Enabled: Link.MirrorNotifications));
        items.Add(new("开机自启", () => Toggle(() => Autostart.Enabled = !Autostart.Enabled), Autostart.Enabled));
        items.Add(new("右键「发送到」菜单", () => Toggle(() => SendToShortcut.Enabled = !SendToShortcut.Enabled), SendToShortcut.Enabled));
        items.Add(TrayIcon.MenuItem.Separator);
        items.Add(new("配对手机…", ShowPair));
        if (Link.Device is not null || PairedStore.All().Count > 0) items.Add(new("取消配对", Link.Forget));
        items.Add(TrayIcon.MenuItem.Separator);
        items.Add(new("导出诊断日志", () => _ = Link.ExportDiagnosticsAsync()));
        items.Add(new("退出 ColorLink", Quit));
        return items;
    }

    static void Toggle(Action a)
    {
        try { a(); } catch (Exception e) { AppLog.Write($"设置失败：{e.Message}"); }
    }

    public void ShowGallery()
    {
        if (_gallery is null)
        {
            _gallery = new GalleryWindow(Link);
            _gallery.Closed += (_, _) => _gallery = null;
        }
        WindowHelper.Bring(_gallery);
    }

    public void ShowPair()
    {
        if (_pair is null)
        {
            _pair = new PairWindow(Link);
            _pair.Closed += (_, _) => _pair = null;
        }
        WindowHelper.Bring(_pair);
    }

    async Task PickAndSendAsync()
    {
        // 选文件框需要一个窗口当主人，用相册窗口
        ShowGallery();
        var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(_gallery!.AppWindow.Id);
        picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) await SendWithFeedbackAsync(files.Select(f => f.Path).ToList());
    }

    /// <summary>发送文件，并用面板显示进度（「发送到」菜单走这里）</summary>
    async Task SendWithFeedbackAsync(List<string> paths)
    {
        if (paths.Count == 0) return;
        if (!Link.IsConnected)
        {
            Platform.Notify("手机未连接", "连上手机以后再发送");
            return;
        }
        Panel.ShowPanel(_tray!);
        await Link.SendAsync(paths);
        if (!Panel.IsShown) Platform.Notify(Link.LastEvent ?? "已发送到手机", string.Join("、", paths.Select(Path.GetFileName).Take(3)));
    }

    void HandleCommandLine(List<string> args, bool firstLaunch)
    {
        int send = args.FindIndex(a => a.Equals("--send", StringComparison.OrdinalIgnoreCase));
        if (send >= 0)
        {
            var files = args.Skip(send + 1).Where(File.Exists).ToList();
            AppLog.Write($"「发送到」：{files.Count} 个文件");
            // 刚启动时手机可能还没连上，等一会儿
            _ = Task.Run(async () =>
            {
                for (int i = 0; i < 20 && firstLaunch; i++)
                {
                    bool connected = false;
                    _dispatcher!.TryEnqueue(() => connected = Link.IsConnected);
                    await Task.Delay(500);
                    if (connected) break;
                }
                _dispatcher!.TryEnqueue(() => _ = SendWithFeedbackAsync(files));
            });
            return;
        }
        if (args.Contains("--background")) return;
        // 直接双击打开：没配对就弹配对窗口，配过对就弹面板
        if (PairedStore.All().Count == 0) ShowPair();
        else Panel.ShowPanel(_tray!);
    }

    /// <summary>第二个实例把命令行转过来了（在后台线程上）</summary>
    public void OnRedirected(AppActivationArguments e)
    {
        string line = e.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs l ? l.Arguments : "";
        var args = SplitCommandLine(line);
        // 第一个是程序本身
        if (args.Count > 0 && args[0].EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) args.RemoveAt(0);
        _dispatcher?.TryEnqueue(() => HandleCommandLine(args, firstLaunch: false));
    }

    static List<string> SplitCommandLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return [];
        var argv = CommandLineToArgvW(line, out int n);
        try
        {
            var list = new List<string>();
            for (int i = 0; i < n; i++) list.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size))!);
            return list;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string line, out int count);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);

    void Quit()
    {
        AppLog.Write("退出");
        Link.SetAsleep(true); // 断开事件流，手机立刻知道电脑走了
        _session?.Dispose();
        _tray?.Dispose();
        Platform.SetBeacon(false);
        Platform.TearDownNotifications();
        Exit();
    }
}
