using System.ComponentModel;
using ColorLink.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Text.RegularExpressions;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;

namespace ColorLink.App;

/// <summary>
/// 托盘面板：顶部连接状态与小按钮，下方照片区（最近三张，悬停：上半下载、下半复制）。
/// 拖文件进来时整个面板都是放置区，松手就发给手机。不常用的开关收在「⋯」菜单里。
/// 点面板外面就收起。
/// </summary>
public sealed partial class PanelWindow : Window
{
    const double PanelWidth = 320;

    readonly LinkController _link;
    readonly RecentTile[] _tiles;
    DateTime _hiddenAt = DateTime.MinValue;
    bool _dragging;

    public PanelWindow(LinkController link)
    {
        _link = link;
        InitializeComponent();
        Title = "ColorLink";
        AppWindow.SetIcon(WindowHelper.IconPath);
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
            p.IsAlwaysOnTop = true;
            // 保留细边框（Windows 11 上带圆角和阴影），去掉标题栏
            p.SetBorderAndTitleBar(true, false);
        }

        _tiles = [.. Enumerable.Range(0, 3).Select(i =>
        {
            var t = new RecentTile(link);
            Grid.SetColumn(t, i);
            StripGrid.Children.Add(t);
            return t;
        })];

        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated && !_dragging) HidePanel();
        };
        AppWindow.Closing += (_, e) =>
        {
            e.Cancel = true;
            HidePanel();
        };
        _link.PropertyChanged += OnLinkChanged;
        Refresh();
    }

    public bool IsShown => AppWindow.IsVisible;

    void OnLinkChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(LinkController.Transfer) && _link.Transfer is { } t)
            ShowOverlay(t, uploading: true);
        else if (e.PropertyName is nameof(LinkController.Transfer) && !_dragging)
        {
            // 传完：收起提示，面板恢复原样（「发送到」/ 右键菜单发送不经过 Root_Drop，要在这里复原）
            DropOverlay.Visibility = Visibility.Collapsed;
            Body.Opacity = 1;
        }
        Refresh();
    }

    /// <summary>托盘图标被点：开着就收起，收着就弹出</summary>
    internal void Toggle(TrayIcon tray)
    {
        if (IsShown)
        {
            HidePanel();
            return;
        }
        // 点托盘图标的那一下会先让面板失去焦点而收起，紧接着又收到点击：这种情况不要马上又弹出来
        if ((DateTime.Now - _hiddenAt).TotalMilliseconds < 300) return;
        ShowPanel(tray);
    }

    internal void ShowPanel(TrayIcon tray)
    {
        Refresh();
        _ = _link.RefreshInfoAsync();
        _ = _link.RefreshRecentAsync();
        Position(tray);
        AppWindow.Show(true);
        Activate();
        Native.SetForegroundWindow(WindowHelper.Hwnd(this));
    }

    public void HidePanel()
    {
        if (!IsShown) return;
        _hiddenAt = DateTime.Now;
        AppWindow.Hide();
    }

    /// <summary>面板贴着的那条边：任务栏在下面时底边不动，往上长；在上面时顶边不动</summary>
    RectInt32 _work;
    PointInt32 _anchor;

    /// <summary>放在托盘图标旁边、任务栏上方（任务栏在别的边时同理）</summary>
    void Position(TrayIcon tray)
    {
        if (tray.GetRect() is { } r) _anchor = new PointInt32((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2);
        else
        {
            Native.GetCursorPos(out var c);
            _anchor = new PointInt32(c.X, c.Y);
        }
        _work = DisplayArea.GetFromPoint(_anchor, DisplayAreaFallback.Nearest).WorkArea;
        // 先挪到那块屏幕上，按那块屏幕的缩放算大小
        AppWindow.Move(new PointInt32(_work.X + 10, _work.Y + 10));
        Body.Measure(new Windows.Foundation.Size(PanelWidth, double.PositiveInfinity));
        Fit(Body.DesiredSize.Height);
    }

    void Fit(double heightDip)
    {
        if (_work.Width == 0) return;
        double s = WindowHelper.Scale(this);
        // 窗口有 1 像素的系统边框，算在外面
        int w = (int)Math.Ceiling(PanelWidth * s) + 2, h = (int)Math.Ceiling(Math.Max(80, heightDip) * s) + 2, gap = (int)(12 * s);
        int x = Math.Clamp(_anchor.X - w / 2, _work.X + gap, _work.X + _work.Width - w - gap);
        int y = _anchor.Y > _work.Y + _work.Height / 2 ? _work.Y + _work.Height - h - gap : _work.Y + gap;
        if (_anchor.X < _work.X) x = _work.X + gap; // 任务栏在左边
        if (_anchor.X > _work.X + _work.Width) x = _work.X + _work.Width - w - gap; // 任务栏在右边
        AppWindow.MoveAndResize(new RectInt32(x, y, w, h));
    }

    /// <summary>内容变高 / 变矮（连上、断开、有新消息）时窗口跟着变</summary>
    void Body_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (Math.Abs(e.NewSize.Height - e.PreviousSize.Height) > 0.5) Fit(e.NewSize.Height);
    }

    void Refresh()
    {
        bool connected = _link.IsConnected;
        // 和 Mac 端一样：标题只放状态或手机名，副标题只放连上后的电量，不另加说明
        TitleText.Text = _link.State switch
        {
            LinkState.Connected => ShortName(_link.StateDetail),
            LinkState.Connecting => "正在连接",
            LinkState.NeedsPairing => "待配对",
            LinkState.Paused => "已暂停",
            _ => "手机未连接",
        };
        SubtitleText.Text = connected && _link.Info is { Battery: { } battery } info
            ? $"{battery}%{(info.Charging == true ? " · 充电中" : "")}"
            : "";
        SubtitleText.Visibility = SubtitleText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        PhoneGlyph.Foreground = connected
            ? (Brush)Application.Current.Resources["ConnectedBrush"]
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];

        DndButton.Visibility = GalleryButton.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
        var dnd = _link.Dnd;
        DndButton.IsEnabled = dnd is not null;
        ToolTipService.SetToolTip(DndButton, dnd is null ? "需要手机开通知使用权" : dnd.Value.IsOn() ? $"免打扰：{dnd.Value.Title()}" : "免打扰");
        if (dnd?.IsOn() == true) DndButton.Style = (Style)Application.Current.Resources["AccentCircleButton"];
        else DndButton.Style = (Style)Application.Current.Resources["CircleButton"];

        Strip.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
        for (int i = 0; i < _tiles.Length; i++) _tiles[i].Item = i < _link.Recent.Count ? _link.Recent[i] : null;
    }

    /// <summary>面板很窄：去掉品牌前缀和版本后缀，「OPPO Find X9 Ultra 卫星通信版」→「Find X9 Ultra」</summary>
    internal static string ShortName(string name)
    {
        var s = Regex.Replace(name.Trim(), @"^(OPPO|OnePlus|realme)\s+", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"\s+\S*版$", "");
        return s.Length > 0 ? s : name;
    }

    async void Dnd_Click(object sender, RoutedEventArgs e) => await _link.ToggleDndAsync();

    void Gallery_Click(object sender, RoutedEventArgs e)
    {
        HidePanel();
        App.Current!.ShowGallery();
    }

    void MoreMenu_Opening(object? sender, object e)
    {
        MoreMenu.Items.Clear();
        foreach (var item in App.Current!.MenuItems(forPanel: true))
        {
            if (ReferenceEquals(item, TrayIcon.MenuItem.Separator))
            {
                MoreMenu.Items.Add(new MenuFlyoutSeparator());
                continue;
            }
            MenuFlyoutItemBase mi;
            if (item.Checkable)
            {
                var t = new ToggleMenuFlyoutItem { Text = item.Title, IsChecked = item.Checked, IsEnabled = item.Enabled };
                t.Click += (_, _) => item.Run?.Invoke();
                mi = t;
            }
            else
            {
                var m = new MenuFlyoutItem { Text = item.Title, IsEnabled = item.Enabled };
                m.Click += (_, _) => item.Run?.Invoke();
                mi = m;
            }
            MoreMenu.Items.Add(mi);
        }
    }

    // MARK: 拖放发送

    void ShowOverlay(string text, bool uploading)
    {
        DropText.Text = text;
        DropGlyph.Glyph = uploading ? "" : "";
        DropOverlay.Visibility = Visibility.Visible;
        Body.Opacity = 0.2;
    }

    void Root_DragOver(object sender, DragEventArgs e)
    {
        bool ok = e.DataView.Contains(StandardDataFormats.StorageItems) || e.DataView.Contains(StandardDataFormats.Bitmap);
        e.AcceptedOperation = ok ? DataPackageOperation.Copy : DataPackageOperation.None;
        if (!ok) return;
        _dragging = true;
        e.DragUIOverride.Caption = "发送到手机";
        if (_link.Transfer is null) ShowOverlay(_link.IsConnected ? "松手发送到手机" : "手机未连接", uploading: false);
    }

    void Root_DragLeave(object sender, DragEventArgs e)
    {
        _dragging = false;
        if (_link.Transfer is null)
        {
            DropOverlay.Visibility = Visibility.Collapsed;
            Body.Opacity = 1;
        }
    }

    async void Root_Drop(object sender, DragEventArgs e)
    {
        _dragging = false;
        var deferral = e.GetDeferral();
        List<string> paths;
        try
        {
            paths = await DropContent.FilesAsync(e.DataView);
        }
        finally
        {
            deferral.Complete();
        }
        AppLog.Write($"拖入 {paths.Count} 个文件");
        await _link.SendAsync(paths);
        DropOverlay.Visibility = Visibility.Collapsed;
        Body.Opacity = 1;
    }
}

/// <summary>从拖放 / 粘贴的内容里取出要发送的文件：文件夹跳过；只有图片数据（浏览器拖图）时存成临时 PNG</summary>
static class DropContent
{
    public static async Task<List<string>> FilesAsync(DataPackageView view)
    {
        var paths = new List<string>();
        if (view.Contains(StandardDataFormats.StorageItems))
        {
            foreach (var item in await view.GetStorageItemsAsync())
                if (item is StorageFile f && !string.IsNullOrEmpty(f.Path) && !paths.Contains(f.Path)) paths.Add(f.Path);
        }
        else if (view.Contains(StandardDataFormats.Bitmap))
        {
            var bmp = await view.GetBitmapAsync();
            using var stream = await bmp.OpenReadAsync();
            var dir = Path.Combine(AppDirs.Caches, "dropped");
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, $"图片-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid().ToString()[..4]}.png");
            // 剪贴板 / 拖拽里的位图可能是 BMP，统一转成 PNG
            var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
            var pixels = await decoder.GetSoftwareBitmapAsync();
            var sf = await StorageFile.GetFileFromPathAsync((await CreateEmpty(file)));
            using var output = await sf.OpenAsync(FileAccessMode.ReadWrite);
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, output);
            encoder.SetSoftwareBitmap(pixels);
            await encoder.FlushAsync();
            paths.Add(file);
        }
        return paths;
    }

    static async Task<string> CreateEmpty(string path)
    {
        await File.WriteAllBytesAsync(path, []);
        return path;
    }
}
