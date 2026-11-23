using System.Diagnostics;
using System.Runtime.InteropServices;
using ColorLink.Core;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.ApplicationModel.DataTransfer;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage;
using Windows.Storage.Streams;

namespace ColorLink.App;

/// <summary>剪贴板、系统通知、资源管理器、蓝牙广播。都在界面线程上调用</summary>
sealed class Platform : IPlatform
{
    readonly BleBeacon _beacon = new();
    bool _notificationsReady;

    public void SetUpNotifications()
    {
        try
        {
            var mgr = AppNotificationManager.Default;
            mgr.NotificationInvoked += (_, e) =>
            {
                // 点通知：在资源管理器里显示文件
                if (e.Arguments.TryGetValue("reveal", out var paths) && paths.Length > 0)
                    Reveal(paths.Split('|'));
            };
            mgr.Register("ColorLink", new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "ColorLink.png")));
            _notificationsReady = true;
        }
        catch (Exception e)
        {
            AppLog.Write($"系统通知不可用：{e.Message}");
        }
    }

    public void TearDownNotifications()
    {
        if (_notificationsReady) AppNotificationManager.Default.Unregister();
    }

    public async Task<bool> CopyImageAsync(string path)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            // 图片数据（任何程序都能粘贴）；资源管理器里粘贴则得到文件
            package.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
            Clipboard.SetContent(package);
            Clipboard.Flush();
            return true;
        }
        catch (Exception e)
        {
            AppLog.Write($"图片写入剪贴板失败：{e.Message}");
            return false;
        }
    }

    public async Task<bool> CopyFilesAsync(IReadOnlyList<string> paths)
    {
        try
        {
            var items = new List<IStorageItem>();
            foreach (var p in paths) items.Add(await StorageFile.GetFileFromPathAsync(p));
            var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            package.SetStorageItems(items);
            Clipboard.SetContent(package);
            Clipboard.Flush();
            return true;
        }
        catch (Exception e)
        {
            AppLog.Write($"文件写入剪贴板失败：{e.Message}");
            return false;
        }
    }

    public void CopyText(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        Clipboard.Flush();
    }

    public void Notify(string title, string body, string? image = null, IReadOnlyList<string>? reveal = null, string? tag = null)
    {
        if (!_notificationsReady) return;
        try
        {
            var b = new AppNotificationBuilder().AddText(title);
            if (body.Length > 0) b.AddText(body.Length > 500 ? body[..500] + "…" : body);
            if (image is not null && File.Exists(image)) b.SetInlineImage(new Uri(image));
            if (reveal is { Count: > 0 }) b.AddArgument("reveal", string.Join('|', reveal));
            if (tag is not null) b.SetTag(tag.Length > 64 ? tag[..64] : tag);
            AppNotificationManager.Default.Show(b.BuildNotification());
        }
        catch (Exception e)
        {
            AppLog.Write($"发通知失败：{e.Message}");
        }
    }

    public void Reveal(IReadOnlyList<string> paths)
    {
        var existing = paths.Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (existing.Count == 0) return;
        // 同一个文件夹里的多个文件一起选中
        var folder = Path.GetDirectoryName(existing[0])!;
        try
        {
            if (SHParseDisplayName(folder, IntPtr.Zero, out var pidlFolder, 0, out _) == 0)
            {
                var children = new List<IntPtr>();
                foreach (var p in existing.Where(p => string.Equals(Path.GetDirectoryName(p), folder, StringComparison.OrdinalIgnoreCase)))
                    if (SHParseDisplayName(p, IntPtr.Zero, out var pidl, 0, out _) == 0) children.Add(pidl);
                SHOpenFolderAndSelectItems(pidlFolder, (uint)children.Count, children.ToArray(), 0);
                children.ForEach(Marshal.FreeCoTaskMem);
                Marshal.FreeCoTaskMem(pidlFolder);
                return;
            }
        }
        catch
        {
            // 退回 explorer /select
        }
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{existing[0]}\"") { UseShellExecute = true });
    }

    public void SetBeacon(bool on) => _beacon.Set(on);

    /// <summary>用系统默认程序打开文件</summary>
    public static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHParseDisplayName(string name, IntPtr bindingContext, out IntPtr pidl, uint sfgaoIn, out uint sfgaoOut);

    [DllImport("shell32.dll")]
    static extern int SHOpenFolderAndSelectItems(IntPtr pidlFolder, uint count, IntPtr[] items, uint flags);
}

/// <summary>
/// 蓝牙广播固定的服务 UUID，手机让系统代为扫描，扫到就唤醒 ColorLink（见 PROTOCOL.md）。
/// 用 GATT 服务的广播：Windows 不允许普通广播里放服务 UUID，发布一个 GATT 服务时系统会把它的 UUID 放进广播包。
/// 电脑的蓝牙不支持外围设备角色时什么都不做（只是少一条唤醒途径，敲门和 mDNS 照常）。
/// </summary>
sealed class BleBeacon
{
    public static readonly Guid ServiceUuid = Guid.Parse("7A1C3F0E-5B2D-4E8A-9C61-3D4F2B8E9A10");

    GattServiceProvider? _provider;
    bool _want;
    bool _starting;

    public void Set(bool on)
    {
        _want = on;
        if (on) _ = StartAsync();
        else Stop();
    }

    async Task StartAsync()
    {
        if (_provider is not null || _starting) return;
        _starting = true;
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter is null || !adapter.IsPeripheralRoleSupported)
            {
                AppLog.Write(adapter is null ? "没有蓝牙，跳过蓝牙广播" : "蓝牙不支持外围设备角色，跳过蓝牙广播");
                return;
            }
            var r = await GattServiceProvider.CreateAsync(ServiceUuid);
            if (r.Error != BluetoothError.Success)
            {
                AppLog.Write($"蓝牙广播开不了：{r.Error}");
                return;
            }
            _provider = r.ServiceProvider;
            _provider.AdvertisementStatusChanged += (s, e) => AppLog.Write($"蓝牙广播：{e.Status}{(e.Error != BluetoothError.Success ? $"（{e.Error}）" : "")}");
            _provider.StartAdvertising(new GattServiceProviderAdvertisingParameters { IsConnectable = true, IsDiscoverable = true });
            if (!_want) Stop();
        }
        catch (Exception e)
        {
            AppLog.Write($"蓝牙广播出错：{e.Message}");
            _provider = null;
        }
        finally
        {
            _starting = false;
        }
    }

    void Stop()
    {
        try { _provider?.StopAdvertising(); } catch { }
        _provider = null;
    }
}
