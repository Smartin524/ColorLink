using ColorLink.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace ColorLink.App;

/// <summary>播放手机上的视频 / 录音：边下边播，可以随意拖动（数据经本机转发，见 LocalRelay）</summary>
sealed class PlayerWindow : Window
{
    readonly MediaPlayerElement _player = new()
    {
        AreTransportControlsEnabled = true,
        Stretch = Stretch.Uniform,
        AutoPlay = true,
    };

    public PlayerWindow(MediaItem item, Uri source)
    {
        SystemBackdrop = new MicaBackdrop();
        WindowHelper.Decorate(this, $"{item.Name} - ColorLink");
        var bar = new Grid { Height = 48, Padding = new Thickness(16, 0, 140, 0) };
        bar.Children.Add(new TextBlock { Text = item.Name, VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.Children.Add(bar);
        Grid.SetRow(_player, 1);
        root.Children.Add(_player);
        Content = root;
        SetTitleBar(bar);

        _player.TransportControls.IsCompact = item.Kind == MediaKind.Audio;
        _player.TransportControls.IsZoomButtonVisible = false;
        _player.Source = MediaSource.CreateFromUri(source);

        double w = 960, h = 600;
        if (item.Kind == MediaKind.Audio) (w, h) = (520, 200);
        else if (item.Width is > 0 and var vw && item.Height is > 0 and var vh)
        {
            // 竖着拍的视频给个竖窗口
            double ratio = (double)vw / vh;
            (w, h) = ratio >= 1 ? (960.0, 960 / ratio + 48) : (560 * ratio, 560.0 + 48);
            w = Math.Max(w, 420);
        }
        WindowHelper.SizeAndCenter(this, w, h);
        Closed += (_, _) =>
        {
            _player.MediaPlayer?.Pause();
            _player.Source = null;
        };
        _player.MediaPlayer.MediaFailed += (_, e) => AppLog.Write($"播放失败 {item.Name}：{e.Error} {e.ErrorMessage}");
    }
}
