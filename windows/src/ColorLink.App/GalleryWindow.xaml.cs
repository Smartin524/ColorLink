using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using ColorLink.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.System;

namespace ColorLink.App;

/// <summary>界面上的一项：媒体信息 + 懒加载的缩略图</summary>
public sealed class MediaItemVM(MediaItem item) : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    public MediaItem Item { get; } = item;

    BitmapImage? _thumb;
    public BitmapImage? Thumb { get => _thumb; set { _thumb = value; Raise(); } }

    bool _downloaded;
    public bool Downloaded { get => _downloaded; set { if (_downloaded != value) { _downloaded = value; Raise(nameof(DownloadedVisibility)); } } }
    public Visibility DownloadedVisibility => Downloaded ? Visibility.Visible : Visibility.Collapsed;

    public string DurationText => Item.Duration is > 0 and var ms ? FormatDuration(ms) : "";
    public Visibility DurationVisibility => DurationText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string Subtitle => $"{Item.CapturedDate.ToLocalTime():yyyy-MM-dd HH:mm} · {FormatSize(Item.Size)}";

    internal bool Loading;

    void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public static string FormatDuration(long ms)
    {
        var t = TimeSpan.FromMilliseconds(ms);
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        >= 1 << 30 => $"{bytes / (double)(1 << 30):0.0} GB",
        >= 1 << 20 => $"{bytes / (double)(1 << 20):0.0} MB",
        >= 1 << 10 => $"{bytes / 1024} KB",
        _ => $"{bytes} B",
    };
}

/// <summary>按拍摄日期分的一组</summary>
public sealed class DayGroup(DateTime day, string title, IEnumerable<MediaItemVM> items) : ObservableCollection<MediaItemVM>(items)
{
    public DateTime Day { get; } = day;
    public string Title { get; } = title;
}

/// <summary>
/// 相册窗口：手机相册在本机的完整副本，按天分组。先显示本地保存的列表，再和手机核对。
/// 双击打开（照片用系统看图，视频 / 录音边下边播），右键复制 / 下载 / 删除，可以拖出到资源管理器或别的程序，
/// 也可以把文件拖进来发给手机。
/// </summary>
public sealed partial class GalleryWindow : Window
{
    readonly LinkController _link;
    MediaKind _kind = MediaKind.Image;
    MediaLibrary? _library;
    readonly Dictionary<string, MediaItemVM> _vms = [];
    List<MediaItemVM> _current = [];
    string? _shownSignature;

    public GalleryWindow(LinkController link)
    {
        _link = link;
        InitializeComponent();
        WindowHelper.Decorate(this, "相册 - ColorLink");
        SetTitleBar(TitleBar);
        WindowHelper.SizeAndCenter(this, 1100, 760);
        _link.PropertyChanged += OnLinkChanged;
        Closed += (_, _) =>
        {
            _link.PropertyChanged -= OnLinkChanged;
            if (_library is not null) _library.Changed -= OnLibraryChanged;
        };
        AttachLibrary();
        UpdateTitle();
        Show();
        _ = SyncAsync();
    }

    void OnLinkChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(LinkController.Library):
                AttachLibrary();
                Show();
                break;
            case nameof(LinkController.ConnectionId):
                _ = SyncAsync();
                break;
            case nameof(LinkController.State):
                UpdateTitle();
                Show(); // 计数里的「手机未连接」
                break;
            case "Downloads":
                foreach (var vm in _current) vm.Downloaded = _link.IsDownloaded(vm.Item);
                break;
            case nameof(LinkController.Transfer) or nameof(LinkController.LastEvent):
                if (_link.Transfer is { } t) ShowStatus(t, InfoBarSeverity.Informational);
                break;
        }
    }

    void AttachLibrary()
    {
        if (_library is not null) _library.Changed -= OnLibraryChanged;
        _library = _link.Library;
        if (_library is not null) _library.Changed += OnLibraryChanged;
        _vms.Clear();
    }

    void OnLibraryChanged(MediaKind kind)
    {
        if (kind != _kind) return;
        DispatcherQueue.TryEnqueue(Show);
    }

    void UpdateTitle()
    {
        // 标题跟着当前分类走（照片 / 视频 / 音频）+ 缩短的手机名；连没连上写在计数那里
        var name = _link.Device?.Name ?? PairedStore.All().FirstOrDefault()?.Name;
        WindowTitle.Text = name is null ? _kind.Title() : $"{_kind.Title()} · {PanelWindow.ShortName(name)}";
        Title = $"{_kind.Title()} - ColorLink";
        SendButton.IsEnabled = _link.IsConnected;
    }

    async Task SyncAsync()
    {
        if (_link.Client is not { } c || _library is not { } lib) return;
        SyncRing.IsActive = true;
        try { await lib.SyncAsync(_kind, c); }
        finally { SyncRing.IsActive = lib.IsSyncing(_kind); }
    }

    /// <summary>把当前类型的列表显示出来；列表没变就不动（免得滚动位置被重置）</summary>
    void Show()
    {
        var snap = _library?[_kind];
        // 照片 / 视频按拍摄时间从新到旧（手机按加入媒体库的顺序给，拍摄时间早的可能排在前面）
        IReadOnlyList<MediaItem> items = snap?.Items ?? [];
        if (_kind != MediaKind.Audio)
            items = items.OrderByDescending(i => i.CapturedDate).ThenByDescending(i => i.Id).ToList();
        var sig = $"{_kind}|{items.Count}|{items.FirstOrDefault()?.CacheKey}|{items.LastOrDefault()?.CacheKey}|{snap?.Complete}";
        var unit = _kind == MediaKind.Image ? "张" : "个";
        CountText.Text = snap is null || snap.Total == 0 ? (_link.IsConnected ? "" : "手机未连接")
            : !_link.IsConnected ? $"{snap.Total} {unit} · 手机未连接"
            : items.Count < snap.Total ? $"正在同步 {items.Count} / {snap.Total} {unit}"
            : $"{snap.Total} {unit}";
        SyncRing.IsActive = _library?.IsSyncing(_kind) == true;
        if (sig == _shownSignature) return;
        _shownSignature = sig;

        _current = items.Select(i =>
        {
            if (!_vms.TryGetValue(i.CacheKey, out var vm)) _vms[i.CacheKey] = vm = new MediaItemVM(i);
            vm.Downloaded = _link.IsDownloaded(i);
            return vm;
        }).ToList();

        bool audio = _kind == MediaKind.Audio;
        Grid.Visibility = audio ? Visibility.Collapsed : Visibility.Visible;
        AudioList.Visibility = audio ? Visibility.Visible : Visibility.Collapsed;
        if (audio)
        {
            AudioList.ItemsSource = _current;
        }
        else
        {
            Groups.Source = Group(_current);
            Grid.ItemsSource = Groups.View;
        }
        EmptyState.Visibility = _current.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = _library is null ? "还没有配对手机" : _link.IsConnected ? $"手机上没有{_kind.Title()}" : "连上手机以后这里会自动刷新";
    }

    static List<DayGroup> Group(List<MediaItemVM> items)
    {
        var result = new List<DayGroup>();
        // 已经按时间排好，相邻同一天的归一组
        foreach (var item in items)
        {
            var day = item.Item.CapturedDate.ToLocalTime().Date;
            if (result.Count == 0 || result[^1].Day != day) result.Add(new DayGroup(day, DayTitle(day), []));
            result[^1].Add(item);
        }
        return result;
    }

    static string DayTitle(DateTime day)
    {
        var today = DateTime.Today;
        if (day == today) return "今天";
        if (day == today.AddDays(-1)) return "昨天";
        var week = CultureInfo.GetCultureInfo("zh-CN").DateTimeFormat.GetDayName(day.DayOfWeek);
        return day.Year == today.Year ? $"{day:M月d日} {week}" : $"{day:yyyy年M月d日}";
    }

    void KindBar_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _kind = sender.SelectedItem?.Tag switch { "video" => MediaKind.Video, "audio" => MediaKind.Audio, _ => MediaKind.Image };
        UpdateTitle();
        _shownSignature = null;
        Show();
        _ = SyncAsync();
    }

    /// <summary>格子出现在屏幕上时才取缩略图（先查本机，再问手机）</summary>
    void Grid_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.Item is not MediaItemVM vm) return;
        if (args.Phase == 0)
        {
            args.RegisterUpdateCallback(Grid_ContainerContentChanging);
            return;
        }
        if (vm.Thumb is not null || vm.Loading) return;
        vm.Loading = true;
        _ = LoadThumbAsync(vm);
    }

    async Task LoadThumbAsync(MediaItemVM vm)
    {
        try { vm.Thumb = await WindowHelper.ThumbAsync(_link, vm.Item, 180); }
        finally { vm.Loading = false; }
    }

    // MARK: 选择和操作

    ListViewBase ActiveList => _kind == MediaKind.Audio ? AudioList : Grid;

    List<MediaItem> Selected() => ActiveList.SelectedItems.OfType<MediaItemVM>().Select(v => v.Item).ToList();

    void Items_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is MediaItemVM vm) _ = OpenAsync(vm.Item);
    }

    void Items_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        bool ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var sel = Selected();
        if (sel.Count == 0) return;
        if (e.Key == VirtualKey.Enter) { foreach (var i in sel.Take(10)) _ = OpenAsync(i); e.Handled = true; }
        else if (e.Key == VirtualKey.Delete) { _ = TrashAsync(sel); e.Handled = true; }
        else if (ctrl && e.Key == VirtualKey.C) { _ = CopyAsync(sel); e.Handled = true; }
        else if (ctrl && e.Key == VirtualKey.S) { _ = SaveAsync(sel); e.Handled = true; }
    }

    void Items_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        // 右键点在没选中的项上：先只选中它
        if ((args.OriginalSource as FrameworkElement)?.DataContext is MediaItemVM vm && !ActiveList.SelectedItems.Contains(vm))
        {
            ActiveList.SelectedItems.Clear();
            ActiveList.SelectedItems.Add(vm);
        }
        var targets = Selected();
        if (targets.Count == 0) return;
        var menu = new MenuFlyout();
        void Add(string text, string glyph, Action run, string? key = null)
        {
            var mi = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            if (key is not null) mi.KeyboardAcceleratorTextOverride = key;
            mi.Click += (_, _) => run();
            menu.Items.Add(mi);
        }
        Add(targets.Count == 1 ? "打开" : $"打开 {Math.Min(targets.Count, 10)} 项", "", () => { foreach (var i in targets.Take(10)) _ = OpenAsync(i); }, "Enter");
        Add("复制", "", () => _ = CopyAsync(targets), "Ctrl+C");
        Add("下载到「文档\\Colorlink」", "", () => _ = SaveAsync(targets), "Ctrl+S");
        var local = targets.Select(_link.LocalCopy).OfType<string>().ToList();
        if (local.Count > 0) Add("在资源管理器中显示", "", () => App.Current!.Platform.Reveal(local));
        if (_kind != MediaKind.Audio)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            Add("删除（移到手机的「最近删除」）", "", () => _ = TrashAsync(targets), "Delete");
        }
        if (args.TryGetPosition(sender, out var p)) menu.ShowAt(sender, p);
        else menu.ShowAt(sender as FrameworkElement);
        args.Handled = true;
    }

    async Task OpenAsync(MediaItem item)
    {
        try
        {
            if (item.Kind == MediaKind.Image)
            {
                ShowStatus($"正在打开 {item.Name}…", InfoBarSeverity.Informational);
                Platform.Open(await _link.OriginalAsync(item));
                Status.IsOpen = false;
            }
            else if (_link.CachedOriginal(item) is { } local)
            {
                Platform.Open(local);
            }
            else if (_link.Client is { } c)
            {
                new PlayerWindow(item, await c.PlaybackUriAsync(item)).Activate();
            }
            else
            {
                ShowStatus("手机未连接", InfoBarSeverity.Warning);
            }
        }
        catch (Exception e)
        {
            ShowStatus($"打开失败：{e.Message}", InfoBarSeverity.Error);
        }
    }

    async Task CopyAsync(List<MediaItem> items)
    {
        ShowStatus(items.Count == 1 ? $"正在复制 {items[0].Name}…" : $"正在复制 {items.Count} 项…", InfoBarSeverity.Informational);
        bool ok = await _link.CopyToClipboardAsync(items);
        ShowStatus(ok ? _link.LastEvent ?? "已复制" :_link.LastEvent ?? "复制失败", ok ? InfoBarSeverity.Success : InfoBarSeverity.Error);
    }

    async Task SaveAsync(List<MediaItem> items)
    {
        int done = 0;
        var saved = new List<string>();
        foreach (var item in items)
        {
            ShowStatus(items.Count == 1 ? $"正在下载 {item.Name}…" : $"正在下载 {done + 1}/{items.Count}…", InfoBarSeverity.Informational);
            try
            {
                saved.Add(await _link.DownloadAsync(item, AppDirs.Downloads));
                done++;
            }
            catch (Exception e)
            {
                ShowStatus($"下载 {item.Name} 失败：{e.Message}", InfoBarSeverity.Error);
                return;
            }
        }
        ShowStatus($"已下载 {done} 项到「文档\\Colorlink」", InfoBarSeverity.Success, reveal: saved);
    }

    async Task TrashAsync(List<MediaItem> items)
    {
        if (_kind == MediaKind.Audio) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = items.Count == 1 ? $"删除「{items[0].Name}」？" : $"删除这 {items.Count} 项？",
            Content = "会移到手机的「最近删除」，30 天内可以在手机上恢复。",
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var msg = await _link.TrashAsync(items);
        ShowStatus(msg, msg.StartsWith("删除失败") ? InfoBarSeverity.Error : InfoBarSeverity.Success);
    }

    /// <summary>拖出到资源管理器 / 微信等：松手时才去下载原图</summary>
    void Grid_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        var items = e.Items.OfType<MediaItemVM>().Select(v => v.Item).Take(50).ToList();
        if (items.Count == 0 || _link.Client is null && items.Any(i => _link.CachedOriginal(i) is null))
        {
            e.Cancel = true;
            return;
        }
        e.Data.RequestedOperation = DataPackageOperation.Copy;
        e.Data.SetDataProvider(StandardDataFormats.StorageItems, async request =>
        {
            var deferral = request.GetDeferral();
            try
            {
                var files = new List<IStorageItem>();
                foreach (var i in items) files.Add(await StorageFile.GetFileFromPathAsync(await _link.OriginalAsync(i)));
                request.SetData(files);
            }
            catch (Exception ex)
            {
                AppLog.Write($"拖出文件失败：{ex.Message}");
            }
            finally
            {
                deferral.Complete();
            }
        });
    }

    // MARK: 发送到手机

    void Root_DragOver(object sender, DragEventArgs e)
    {
        // 从本窗口拖出去的不算
        if (e.DataView.Properties.ContainsKey("ColorLinkInternal")) return;
        bool ok = _link.IsConnected && (e.DataView.Contains(StandardDataFormats.StorageItems) || e.DataView.Contains(StandardDataFormats.Bitmap));
        e.AcceptedOperation = ok ? DataPackageOperation.Copy : DataPackageOperation.None;
        if (ok) e.DragUIOverride.Caption = "发送到手机";
    }

    async void Root_Drop(object sender, DragEventArgs e)
    {
        var deferral = e.GetDeferral();
        List<string> paths;
        try { paths = await DropContent.FilesAsync(e.DataView); }
        finally { deferral.Complete(); }
        await _link.SendAsync(paths);
        ShowStatus(_link.LastEvent ?? "已发送", InfoBarSeverity.Success);
    }

    async void Send_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(AppWindow.Id) { ViewMode = Microsoft.Windows.Storage.Pickers.PickerViewMode.Thumbnail };
        picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        if (files is null || files.Count == 0) return;
        await _link.SendAsync(files.Select(f => f.Path).ToList());
        ShowStatus(_link.LastEvent ?? "已发送", InfoBarSeverity.Success);
    }

    async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        _shownSignature = null;
        await SyncAsync();
        Show();
    }

    void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(AppDirs.Downloads);
        Platform.Open(AppDirs.Downloads);
    }

    void ShowStatus(string text, InfoBarSeverity severity, IReadOnlyList<string>? reveal = null)
    {
        Status.Message = text;
        Status.Severity = severity;
        Status.ActionButton = null;
        if (reveal is { Count: > 0 })
        {
            var b = new Button { Content = "在资源管理器中显示" };
            b.Click += (_, _) => App.Current!.Platform.Reveal(reveal);
            Status.ActionButton = b;
        }
        Status.IsOpen = true;
    }
}
