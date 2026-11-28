using ColorLink.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ColorLink.App;

/// <summary>面板上的一张最近照片：悬停时上半是“下载”（存到「文档\Colorlink」），下半是“复制”（原图放进剪贴板）</summary>
sealed class RecentTile : Grid
{
    readonly LinkController _link;
    readonly Image _image = new() { Stretch = Stretch.UniformToFill };
    readonly Grid _hover = new() { Visibility = Visibility.Collapsed };
    readonly Grid _badge = new() { Visibility = Visibility.Collapsed, Background = new SolidColorBrush(ColorHelper.FromArgb(0x70, 0, 0, 0)) };
    readonly TextBlock _badgeText = new() { Foreground = new SolidColorBrush(Colors.White), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
    readonly ProgressRing _ring = new() { Width = 20, Height = 20, IsActive = false, Foreground = new SolidColorBrush(Colors.White) };
    readonly FontIcon _check = new() { Glyph = "", FontSize = 10, Foreground = new SolidColorBrush(Colors.White), Visibility = Visibility.Collapsed };
    MediaItem? _item;
    bool _busy;

    public RecentTile(LinkController link)
    {
        _link = link;
        CornerRadius = new CornerRadius(7);
        Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
        Children.Add(_image);

        _hover.RowDefinitions.Add(new RowDefinition());
        _hover.RowDefinitions.Add(new RowDefinition());
        var down = Half("下载", "", async () => await _link.SaveToDownloadsAsync(_item!) ? "已存" : null);
        var copy = Half("复制", "", async () => await _link.CopyToClipboardAsync([_item!]) ? "已复制" : null);
        SetRow(copy, 1);
        _hover.Children.Add(down);
        _hover.Children.Add(copy);
        Children.Add(_hover);

        // 已经下载到这台电脑的：左上角一个小对勾
        var mark = new Border
        {
            Width = 16, Height = 16, CornerRadius = new CornerRadius(8), Margin = new Thickness(4),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(ColorHelper.FromArgb(0x90, 0, 0, 0)), Child = _check,
        };
        mark.SetBinding(VisibilityProperty, new Microsoft.UI.Xaml.Data.Binding { Source = _check, Path = new PropertyPath("Visibility") });
        Children.Add(mark);

        var badgeStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        badgeStack.Children.Add(_ring);
        badgeStack.Children.Add(_badgeText);
        _badge.Children.Add(badgeStack);
        Children.Add(_badge);

        PointerEntered += (_, _) => { if (_item is not null && !_busy) _hover.Visibility = Visibility.Visible; };
        PointerExited += (_, _) => _hover.Visibility = Visibility.Collapsed;
        _link.PropertyChanged += (_, e) => { if (e.PropertyName == "Downloads") UpdateCheck(); };
    }

    public MediaItem? Item
    {
        get => _item;
        set
        {
            if (_item?.CacheKey == value?.CacheKey) return;
            _item = value;
            _image.Source = null;
            ToolTipService.SetToolTip(this, value?.Name);
            UpdateCheck();
            if (value is not null) _ = LoadAsync(value);
        }
    }

    void UpdateCheck() => _check.Visibility = _item is not null && _link.IsDownloaded(_item) ? Visibility.Visible : Visibility.Collapsed;

    async Task LoadAsync(MediaItem item)
    {
        var bmp = await WindowHelper.ThumbAsync(_link, item, 120);
        if (_item?.CacheKey == item.CacheKey) _image.Source = bmp;
    }

    Button Half(string text, string glyph, Func<Task<string?>> action)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12 });
        content.Children.Add(new TextBlock { Text = text, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var b = new Button { Content = content, Style = (Style)Application.Current.Resources["HalfButton"] };
        b.Click += async (_, _) =>
        {
            if (_item is null) return;
            _busy = true;
            _hover.Visibility = Visibility.Collapsed;
            _badge.Visibility = Visibility.Visible;
            _ring.IsActive = true;
            _ring.Visibility = Visibility.Visible;
            _badgeText.Text = "";
            var result = await action();
            _ring.IsActive = false;
            _ring.Visibility = Visibility.Collapsed;
            _badgeText.Text = result is null ? "✕ 失败" : $"✓ {result}";
            await Task.Delay(1200);
            _badge.Visibility = Visibility.Collapsed;
            _busy = false;
            UpdateCheck();
        };
        return b;
    }
}
