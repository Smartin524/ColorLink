using ColorLink.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Storage.Streams;

namespace ColorLink.App;

static class WindowHelper
{
    public static string IconPath => Path.Combine(AppContext.BaseDirectory, "Assets", "ColorLink.ico");

    public static IntPtr Hwnd(Window w) => WinRT.Interop.WindowNative.GetWindowHandle(w);

    public static double Scale(Window w) => Native.GetDpiForWindow(Hwnd(w)) / 96.0;

    /// <summary>按逻辑像素（DIP）设置窗口大小，并放在当前屏幕中间</summary>
    public static void SizeAndCenter(Window w, double width, double height)
    {
        double s = Scale(w);
        var size = new SizeInt32((int)(width * s), (int)(height * s));
        var area = DisplayArea.GetFromWindowId(w.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        w.AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2, size.Width, size.Height));
    }

    /// <summary>普通窗口：品牌图标、标题栏融进内容（配 Mica）</summary>
    public static void Decorate(Window w, string title)
    {
        w.Title = title;
        w.AppWindow.SetIcon(IconPath);
        w.ExtendsContentIntoTitleBar = true;
        w.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
    }

    /// <summary>把已经在后台的窗口拉到前面</summary>
    public static void Bring(Window w)
    {
        if (w.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        w.Activate();
        Native.SetForegroundWindow(Hwnd(w));
    }

    /// <summary>JPEG 缩略图字节 → 界面上用的图片</summary>
    public static async Task<BitmapImage?> DecodeAsync(byte[]? data, int decodeWidth)
    {
        if (data is null || data.Length == 0) return null;
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(data.AsBuffer());
            stream.Seek(0);
            var bmp = new BitmapImage { DecodePixelWidth = decodeWidth, DecodePixelType = DecodePixelType.Logical };
            await bmp.SetSourceAsync(stream);
            return bmp;
        }
        catch
        {
            return null;
        }
    }

    public static async Task<BitmapImage?> ThumbAsync(LinkController link, MediaItem item, int decodeWidth)
    {
        if (link.Thumbs is not { } cache) return null;
        var data = cache.Stored(item) ?? await cache.DataAsync(item, link.Client);
        return await DecodeAsync(data, decodeWidth);
    }
}

static class BufferExtensions
{
    public static Windows.Storage.Streams.IBuffer AsBuffer(this byte[] data) =>
        System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(data);
}
