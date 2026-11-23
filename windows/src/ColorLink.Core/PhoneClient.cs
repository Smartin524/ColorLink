using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace ColorLink.Core;

/// <summary>手机端 HTTPS 协议的客户端，协议见 PROTOCOL.md。</summary>
public sealed class PhoneClient : IDisposable
{
    public PhoneEndpoint Endpoint { get; }
    public string Token { get; }
    /// <summary>告诉手机这台电脑叫什么，显示在流体云里</summary>
    public string ClientName { get; }
    /// <summary>手机证书的指纹核对，见 CertPin</summary>
    public CertPin Pin { get; }

    readonly HttpClient _http;
    readonly HttpClient _events;

    /// <param name="certSha256">为 null（升级前配的对）时接受任何证书，连上后由调用方把 Pin.Seen 存起来</param>
    public PhoneClient(PhoneEndpoint endpoint, string token, string? certSha256, string? clientName = null)
    {
        Endpoint = endpoint;
        Token = token;
        ClientName = clientName ?? DefaultClientName;
        Pin = new CertPin(certSha256);
        // 缩略图并发拉取
        _http = new HttpClient(Handler(Pin, 6)) { BaseAddress = endpoint.BaseUri, Timeout = Timeout.InfiniteTimeSpan };
        // 断线由 Events() 自己判断：手机深睡时 ping 会停，单靠超时会反复误判断线
        _events = new HttpClient(Handler(Pin, 2)) { BaseAddress = endpoint.BaseUri, Timeout = Timeout.InfiniteTimeSpan };
    }

    public static string DefaultClientName => Environment.MachineName is { Length: > 0 } n ? n : "Windows";

    public void Dispose()
    {
        _http.Dispose();
        _events.Dispose();
    }

    static SocketsHttpHandler Handler(CertPin pin, int maxConnections) => new()
    {
        MaxConnectionsPerServer = maxConnections,
        ConnectTimeout = TimeSpan.FromSeconds(6),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        AutomaticDecompression = DecompressionMethods.None,
        UseProxy = false,
        SslOptions = { RemoteCertificateValidationCallback = pin.Validate },
    };

    // MARK: 配对

    /// <summary>配对；返回结果和这次握手看到的证书指纹（以后只认它）</summary>
    public static async Task<(PairResult Result, string Cert)> PairAsync(PhoneEndpoint endpoint, string code, string clientName, CancellationToken ct = default)
    {
        var pin = new CertPin(null);
        using var http = new HttpClient(Handler(pin, 1)) { BaseAddress = endpoint.BaseUri, Timeout = TimeSpan.FromSeconds(8) };
        using var resp = await http.GetAsync(Url("api/pair", new() { ["code"] = code, ["client"] = clientName }), ct);
        switch ((int)resp.StatusCode)
        {
            case 200:
                var cert = pin.Seen ?? throw new PhoneException(PhoneErrorKind.Http, status: 0);
                var r = Json.Parse<PairResult>(await resp.Content.ReadAsByteArrayAsync(ct)) ?? throw new PhoneException(PhoneErrorKind.Http, status: 200);
                return (r, cert);
            case 403: throw new PhoneException(PhoneErrorKind.BadPairingCode);
            case var s: throw new PhoneException(PhoneErrorKind.Http, status: s);
        }
    }

    /// <summary>
    /// 不带令牌问一下这个地址上是哪台手机；对不上（或根本不是 ColorLink）就返回 null。
    /// 用来在发令牌之前确认身份，避免把令牌发给同一 IP 上的别的设备。已知证书指纹时一并核对。
    /// </summary>
    public static async Task<string?> IdentifyAsync(PhoneEndpoint endpoint, string? certSha256, TimeSpan? timeout = null)
    {
        try
        {
            using var http = new HttpClient(Handler(new CertPin(certSha256), 1))
            { BaseAddress = endpoint.BaseUri, Timeout = timeout ?? TimeSpan.FromSeconds(2) };
            using var resp = await http.GetAsync("api/id");
            if (resp.StatusCode != HttpStatusCode.OK) return null;
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsByteArrayAsync());
            return doc.RootElement.TryGetProperty("deviceId", out var id) ? id.GetString() : null;
        }
        catch
        {
            return null;
        }
    }

    // MARK: 普通接口

    static string Url(string path, Dictionary<string, string>? query = null)
    {
        if (query is null || query.Count == 0) return path;
        var sb = new StringBuilder(path).Append('?');
        bool first = true;
        foreach (var (k, v) in query.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            if (!first) sb.Append('&');
            first = false;
            sb.Append(Uri.EscapeDataString(k)).Append('=').Append(Uri.EscapeDataString(v));
        }
        return sb.ToString();
    }

    HttpRequestMessage Request(HttpMethod method, string path, Dictionary<string, string>? query = null)
    {
        var r = new HttpRequestMessage(method, Url(path, query));
        r.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
        return r;
    }

    static void Check(HttpResponseMessage resp)
    {
        int code = (int)resp.StatusCode;
        if (code == 401) throw new PhoneException(PhoneErrorKind.Unauthorized);
        if (code is < 200 or >= 300) throw new PhoneException(PhoneErrorKind.Http, status: code);
    }

    /// <summary>发请求；超时、证书对不上统一换成 PhoneException</summary>
    async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, TimeSpan timeout, CancellationToken ct,
        HttpCompletionOption option = HttpCompletionOption.ResponseContentRead, HttpClient? client = null)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        try
        {
            var resp = await (client ?? _http).SendAsync(req, option, cts.Token);
            Check(resp);
            return resp;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new PhoneException(PhoneErrorKind.Timeout);
        }
        catch (HttpRequestException e) when (Pin.Mismatch)
        {
            throw new PhoneException(PhoneErrorKind.CertMismatch, inner: e);
        }
    }

    async Task<byte[]> GetAsync(string path, Dictionary<string, string>? query = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        using var req = Request(HttpMethod.Get, path, query);
        using var resp = await SendAsync(req, timeout ?? TimeSpan.FromSeconds(15), ct);
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    public async Task<DeviceInfo> InfoAsync(TimeSpan? timeout = null, CancellationToken ct = default) =>
        Json.Parse<DeviceInfo>(await GetAsync("api/info", timeout: timeout ?? TimeSpan.FromSeconds(5), ct: ct))!;

    /// <summary>手机端的日志文件（导出诊断日志用）</summary>
    public async Task<string> LogsAsync(CancellationToken ct = default) =>
        Encoding.UTF8.GetString(await GetAsync("api/logs", timeout: TimeSpan.FromSeconds(10), ct: ct));

    public async Task<MediaPage> MediaAsync(MediaKind kind, int offset, int limit = 200, CancellationToken ct = default) =>
        Json.Parse<MediaPage>(await GetAsync("api/media", new()
        {
            ["kind"] = kind.Wire(), ["offset"] = offset.ToString(), ["limit"] = limit.ToString(),
        }, ct: ct))!;

    public Task<byte[]> ThumbnailAsync(MediaItem item, int size = 256, CancellationToken ct = default) =>
        GetAsync("api/thumb", new()
        {
            ["kind"] = item.Kind.Wire(), ["id"] = item.Id.ToString(), ["v"] = item.Modified.ToString(), ["size"] = size.ToString(),
        }, ct: ct);

    public sealed record TrashResult(int Trashed, bool Pending);

    /// <summary>移到手机的「最近删除」（可以在手机上恢复）</summary>
    public async Task<TrashResult> TrashAsync(IEnumerable<MediaItem> items, CancellationToken ct = default)
    {
        using var req = Request(HttpMethod.Post, "api/trash");
        var body = new { items = items.Select(i => new { kind = i.Kind.Wire(), id = i.Id }) };
        req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var resp = await SendAsync(req, TimeSpan.FromSeconds(15), ct);
        return Json.Parse<TrashResult>(await resp.Content.ReadAsByteArrayAsync(ct))!;
    }

    /// <summary>改手机的免打扰档位。手机没开通知使用权时返回 503</summary>
    public async Task<DndMode> SetDndAsync(DndMode mode, CancellationToken ct = default)
    {
        using var req = Request(HttpMethod.Post, "api/dnd", new() { ["mode"] = mode.Wire() });
        using var resp = await SendAsync(req, TimeSpan.FromSeconds(8), ct);
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsByteArrayAsync(ct));
        return DndModeExtensions.Parse(doc.RootElement.GetProperty("mode").GetString()) ?? mode;
    }

    /// <summary>取手机分享过来的文件，存进 dir，重名时自动加序号</summary>
    public Task<string> DownloadAsync(SharedFile file, string dir, CancellationToken ct = default) =>
        DownloadToAsync(Request(HttpMethod.Get, "api/shared", new() { ["id"] = file.Id }), file.Name, dir, TimeSpan.FromMinutes(10), ct);

    /// <summary>下载到指定目录，重名时自动加序号。</summary>
    public Task<string> DownloadAsync(MediaItem item, string dir, CancellationToken ct = default) =>
        DownloadToAsync(Request(HttpMethod.Get, "api/file", FileQuery(item)), item.Name, dir, TimeSpan.FromMinutes(10), ct);

    static Dictionary<string, string> FileQuery(MediaItem item) => new() { ["kind"] = item.Kind.Wire(), ["id"] = item.Id.ToString() };

    async Task<string> DownloadToAsync(HttpRequestMessage req, string name, string dir, TimeSpan timeout, CancellationToken ct)
    {
        using var _ = req;
        using var resp = await SendAsync(req, timeout, ct, HttpCompletionOption.ResponseHeadersRead);
        Directory.CreateDirectory(dir);
        var tmp = System.IO.Path.Combine(dir, $".{Guid.NewGuid():N}.part");
        try
        {
            await using (var fs = File.Create(tmp))
            {
                await using var s = await resp.Content.ReadAsStreamAsync(ct);
                await s.CopyToAsync(fs, ct);
            }
            var dest = UniquePath(dir, name);
            File.Move(tmp, dest);
            return dest;
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    }

    /// <summary>
    /// 把文件发到手机。图片存进手机的 Pictures/ColorLink，其他文件存进 Download/ColorLink。
    /// batch：一次发送的多个文件共用一个批次号，手机收完最后一个才提示「已收到 N 个文件」
    /// </summary>
    public async Task<MediaItem?> UploadAsync(string file, string? name = null, (string Id, int Index, int Count)? batch = null,
        IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var fileName = name ?? System.IO.Path.GetFileName(file);
        var query = new Dictionary<string, string> { ["name"] = fileName, ["mime"] = MimeTypes.For(fileName) };
        if (batch is { } b)
        {
            query["batch"] = b.Id;
            query["index"] = b.Index.ToString();
            query["count"] = b.Count.ToString();
        }
        using var req = Request(HttpMethod.Post, "api/upload", query);
        await using var fs = File.OpenRead(file);
        req.Content = new ProgressStreamContent(fs, progress);
        req.Content.Headers.ContentType = new MediaTypeHeaderValue(query["mime"]);
        req.Content.Headers.ContentLength = fs.Length;
        using var resp = await SendAsync(req, TimeSpan.FromMinutes(10), ct);
        try
        {
            var data = await resp.Content.ReadAsByteArrayAsync(ct);
            using var doc = JsonDocument.Parse(data);
            return doc.RootElement.TryGetProperty("id", out _) ? Json.Parse<MediaItem>(data) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>带 Range 取原文件的一段（本机播放转发和测试用）。调用方负责释放返回的响应</summary>
    public async Task<HttpResponseMessage> RawRequestAsync(MediaItem item, string? range, CancellationToken ct = default)
    {
        var req = Request(HttpMethod.Get, "api/file", FileQuery(item));
        if (range is not null) req.Headers.TryAddWithoutValidation("Range", range);
        // 只等到响应头；正文由调用方边读边转发
        var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (resp.StatusCode == HttpStatusCode.Unauthorized) throw new PhoneException(PhoneErrorKind.Unauthorized);
        return resp;
    }

    /// <summary>给播放器的地址。播放器没法自定义证书校验，所以走本机转发（见 LocalRelay）</summary>
    public Task<Uri> PlaybackUriAsync(MediaItem item) => LocalRelay.Shared.UriFor(item, this);

    public static string UniquePath(string dir, string name)
    {
        name = SafeFileName(name);
        var stem = System.IO.Path.GetFileNameWithoutExtension(name);
        var ext = System.IO.Path.GetExtension(name);
        var candidate = System.IO.Path.Combine(dir, name);
        for (int n = 2; File.Exists(candidate) || Directory.Exists(candidate); n++)
            candidate = System.IO.Path.Combine(dir, $"{stem} {n}{ext}");
        return candidate;
    }

    /// <summary>Windows 文件名里不能有的字符换成下划线，不让手机传来的名字带出目录</summary>
    public static string SafeFileName(string name)
    {
        // 只留最后一段；不用 Path.GetFileName，它会把「a:b」当成盘符吃掉前半截
        name = name[(name.LastIndexOfAny(['/', '\\']) + 1)..];
        var bad = System.IO.Path.GetInvalidFileNameChars();
        var s = new string(name.Select(c => bad.Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.');
        return s.Length == 0 ? "file" : s;
    }

    // MARK: 事件流

    /// <summary>
    /// 订阅手机事件（SSE）。连接断开时以异常结束，由调用方负责重连。
    ///
    /// 手机每 20 秒发一次 ping，但手机深睡时 CPU 停着，ping 会停上很久，连接其实还在。
    /// 所以流里安静超过 3 分钟时，另开一个请求问一下手机：请求会把手机叫醒，手机当场往流里回一行 ping。
    /// 答不上、或答上了流里仍然没有动静，才判定断线。
    /// </summary>
    public async IAsyncEnumerable<PhoneEvent> EventsAsync([EnumeratorCancellation] CancellationToken ct = default)
    {
        var channel = Channel.CreateUnbounded<PhoneEvent>(new() { SingleReader = true });
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        long lastActivity = Environment.TickCount64;

        var reader = Task.Run(async () =>
        {
            try
            {
                using var req = Request(HttpMethod.Get, "api/events", new() { ["name"] = ClientName });
                using var resp = await SendAsync(req, TimeSpan.FromSeconds(10), cts.Token, HttpCompletionOption.ResponseHeadersRead, _events);
                await using var stream = await resp.Content.ReadAsStreamAsync(cts.Token);
                using var sr = new StreamReader(stream, Encoding.UTF8);
                string name = "message";
                while (await sr.ReadLineAsync(cts.Token) is { } line)
                {
                    Interlocked.Exchange(ref lastActivity, Environment.TickCount64);
                    if (line.StartsWith(':')) continue; // ping
                    if (line.StartsWith("event:"))
                    {
                        name = line[6..].Trim();
                    }
                    else if (line.StartsWith("data:"))
                    {
                        // 协议约定每个事件只有一行 data，读到 data 就直接派发
                        await channel.Writer.WriteAsync(Decode(name, line[5..].Trim()), cts.Token);
                        name = "message";
                    }
                }
                channel.Writer.TryComplete(new PhoneException(PhoneErrorKind.StreamEnded));
            }
            catch (Exception e)
            {
                channel.Writer.TryComplete(e);
            }
        });

        var watchdog = Task.Run(async () =>
        {
            long? probedAt = null;
            while (!cts.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(15), cts.Token); } catch { return; }
                long now = Environment.TickCount64;
                if (now - Interlocked.Read(ref lastActivity) < 180_000) { probedAt = null; continue; }
                if (probedAt is { } p && now - p > 30_000)
                {
                    // 手机答得上，事件流却一直没动静：流已经断了（比如手机进程重启过）
                    channel.Writer.TryComplete(new PhoneException(PhoneErrorKind.Timeout));
                    return;
                }
                if (probedAt is not null) continue;
                try
                {
                    await InfoAsync(TimeSpan.FromSeconds(10), cts.Token);
                    probedAt = Environment.TickCount64;
                }
                catch
                {
                    channel.Writer.TryComplete(new PhoneException(PhoneErrorKind.Timeout));
                    return;
                }
            }
        });

        try
        {
            await foreach (var ev in channel.Reader.ReadAllAsync(ct))
                yield return ev;
        }
        finally
        {
            cts.Cancel();
            try { await Task.WhenAll(reader, watchdog); } catch { /* 已经结束 */ }
        }
    }

    public static PhoneEvent Decode(string name, string data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            switch (name)
            {
                case "hello": return new PhoneEvent.Hello(Json.Parse<DeviceInfo>(data)!);
                case "screenshot": return new PhoneEvent.Screenshot(Json.Parse<MediaItem>(data)!);
                case "media": return new PhoneEvent.Media(Json.Parse<MediaItem>(data)!);
                case "notification": return new PhoneEvent.Notification(Json.Parse<PhoneNotification>(data)!);
                case "clipboard": return new PhoneEvent.Clipboard(root.GetProperty("text").GetString() ?? "");
                case "shared":
                    return new PhoneEvent.Shared(root.GetProperty("items").Deserialize<List<SharedFile>>(Json.Options) ?? []);
                case "power":
                    return new PhoneEvent.Power(root.GetProperty("charging").GetBoolean(),
                        root.TryGetProperty("battery", out var b) && b.ValueKind == JsonValueKind.Number ? b.GetInt32() : null);
                case "dnd":
                    if (DndModeExtensions.Parse(root.GetProperty("mode").GetString()) is { } m) return new PhoneEvent.Dnd(m);
                    break;
            }
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            // 解析不了的事件当作未知事件
        }
        return new PhoneEvent.Unknown(name);
    }
}

/// <summary>上传时报告已发送字节数</summary>
sealed class ProgressStreamContent(Stream stream, IProgress<long>? progress) : HttpContent
{
    protected override async Task SerializeToStreamAsync(Stream target, TransportContext? context) =>
        await SerializeToStreamAsync(target, context, CancellationToken.None);

    protected override async Task SerializeToStreamAsync(Stream target, TransportContext? context, CancellationToken ct)
    {
        var buffer = new byte[81920];
        long sent = 0;
        int n;
        while ((n = await stream.ReadAsync(buffer, ct)) > 0)
        {
            await target.WriteAsync(buffer.AsMemory(0, n), ct);
            sent += n;
            progress?.Report(sent);
        }
    }

    protected override bool TryComputeLength(out long length)
    {
        length = stream.Length;
        return true;
    }
}
