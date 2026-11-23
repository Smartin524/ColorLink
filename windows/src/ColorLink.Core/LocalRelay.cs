using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace ColorLink.Core;

/// <summary>
/// 给播放器用的本机转发。
///
/// 系统播放器没法自定义证书校验，连不上手机自签名的 HTTPS。所以让它连 127.0.0.1 上的明文地址，
/// 这里再带着令牌、按固定的证书去手机分块取，视频照样能边下边播、随意拖动。
/// 只监听本机回环地址；每个地址带一段随机路径，本机别的程序猜不到。
/// </summary>
public sealed class LocalRelay
{
    public static LocalRelay Shared { get; } = new();

    readonly Lock _gate = new();
    TcpListener? _listener;
    /// <summary>路径 → 要取的文件；只留最近的几个</summary>
    readonly List<(string Key, PhoneClient Client, MediaItem Item)> _routes = [];

    public Task<Uri> UriFor(MediaItem item, PhoneClient client)
    {
        int port = Start();
        var key = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        lock (_gate)
        {
            _routes.Add((key, client, item));
            if (_routes.Count > 20) _routes.RemoveRange(0, _routes.Count - 20);
        }
        // 带上扩展名，播放器靠它判断格式
        var ext = Path.GetExtension(item.Name);
        return Task.FromResult(new Uri($"http://127.0.0.1:{port}/{key}{ext}"));
    }

    int Start()
    {
        lock (_gate)
        {
            if (_listener is not null) return ((IPEndPoint)_listener.LocalEndpoint).Port;
            var l = new TcpListener(IPAddress.Loopback, 0);
            l.Start();
            _listener = l;
            _ = Task.Run(() => AcceptLoop(l));
            return ((IPEndPoint)l.LocalEndpoint).Port;
        }
    }

    async Task AcceptLoop(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(); }
            catch { return; }
            _ = Task.Run(() => Serve(c));
        }
    }

    async Task Serve(TcpClient tcp)
    {
        using var _ = tcp;
        var net = tcp.GetStream();
        try
        {
            while (true)
            {
                var head = await ReadHead(net);
                if (head is null) return;
                var lines = head.Split("\r\n");
                var parts = lines[0].Split(' ');
                if (parts.Length < 2) return;
                bool isHead = parts[0] == "HEAD";
                string? range = null;
                bool close = false;
                foreach (var line in lines.Skip(1))
                {
                    int i = line.IndexOf(':');
                    if (i <= 0) continue;
                    var name = line[..i].Trim();
                    var value = line[(i + 1)..].Trim();
                    if (name.Equals("Range", StringComparison.OrdinalIgnoreCase)) range = value;
                    if (name.Equals("Connection", StringComparison.OrdinalIgnoreCase) && value.Equals("close", StringComparison.OrdinalIgnoreCase)) close = true;
                }
                var key = Path.GetFileNameWithoutExtension(parts[1].TrimStart('/').Split('?')[0]);
                (string Key, PhoneClient Client, MediaItem Item)? route;
                lock (_gate) route = _routes.LastOrDefault(r => r.Key == key) is { Key: not null } r ? r : null;
                if (route is null)
                {
                    await WriteSimple(net, 404, "Not Found");
                    return;
                }
                using var resp = await route.Value.Client.RawRequestAsync(route.Value.Item, range);
                var sb = new StringBuilder();
                sb.Append($"HTTP/1.1 {(int)resp.StatusCode} {resp.ReasonPhrase}\r\n");
                sb.Append($"Content-Type: {resp.Content.Headers.ContentType?.ToString() ?? route.Value.Item.Mime}\r\n");
                if (resp.Content.Headers.ContentLength is { } len) sb.Append($"Content-Length: {len}\r\n");
                if (resp.Content.Headers.ContentRange is { } cr) sb.Append($"Content-Range: {cr}\r\n");
                sb.Append("Accept-Ranges: bytes\r\n");
                sb.Append(close ? "Connection: close\r\n" : "Connection: keep-alive\r\n");
                sb.Append("\r\n");
                await net.WriteAsync(Encoding.ASCII.GetBytes(sb.ToString()));
                if (!isHead)
                {
                    await using var body = await resp.Content.ReadAsStreamAsync();
                    await body.CopyToAsync(net);
                }
                await net.FlushAsync();
                if (close || resp.Content.Headers.ContentLength is null) return;
            }
        }
        catch
        {
            // 播放器拖动进度条时会直接断开旧连接，正常
        }
    }

    static async Task<string?> ReadHead(NetworkStream s)
    {
        var buf = new List<byte>(1024);
        var one = new byte[1];
        while (buf.Count < 16 * 1024)
        {
            int n = await s.ReadAsync(one);
            if (n == 0) return null;
            buf.Add(one[0]);
            int c = buf.Count;
            if (c >= 4 && buf[c - 4] == '\r' && buf[c - 3] == '\n' && buf[c - 2] == '\r' && buf[c - 1] == '\n')
                return Encoding.ASCII.GetString(buf.ToArray(), 0, c - 4);
        }
        return null;
    }

    static Task WriteSimple(NetworkStream s, int code, string text) =>
        s.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {code} {text}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")).AsTask();
}
