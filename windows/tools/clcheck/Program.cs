// 命令行联调：在没有手机的情况下，对着 mock/mock_phone.py 走一遍 Windows 端的完整流程。
//
//   dotnet run --project tools/clcheck -- --code 123456            # 通过 mDNS 找手机
//   dotnet run --project tools/clcheck -- --host 127.0.0.1 --code 123456
//
// 加 --trigger 会让模拟手机“截一张图”、发一条验证码短信、再敲一次门，验证这几条链路（只能对本机的 mock_phone.py 用）。

using System.Diagnostics;
using System.Net;
using ColorLink.Core;

Console.OutputEncoding = System.Text.Encoding.UTF8;
// 不碰正式数据：配对、缩略图都放在临时目录
AppDirs.Root = Path.Combine(Path.GetTempPath(), "colorlink-clcheck");

string? Arg(string name)
{
    int i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

void Step(string s) => Console.WriteLine($"\n▶ {s}");
void Ok(string s) => Console.WriteLine($"  ✓ {s}");
void Fail(string s)
{
    Console.WriteLine($"  ✗ {s}");
    Environment.Exit(1);
}
string Ms(Stopwatch sw) => $"{sw.ElapsedMilliseconds} ms";

var code = Arg("--code") ?? "123456";
bool trigger = args.Contains("--trigger");

// ① 发现
PhoneEndpoint endpoint;
if (Arg("--host") is { } h)
{
    endpoint = PhoneEndpoint.Parse(h);
    Step($"使用指定地址 {endpoint}");
}
else
{
    Step($"通过 mDNS 查找 {PhoneBrowser.ServiceType}");
    var sw = Stopwatch.StartNew();
    IReadOnlyList<DiscoveredPhone> found = [];
    while (found.Count == 0 && sw.Elapsed < TimeSpan.FromSeconds(10))
        found = await PhoneBrowser.BrowseOnceAsync(TimeSpan.FromSeconds(2));
    if (found.Count == 0) Fail("10 秒内没有发现手机");
    var f = found[0];
    Ok($"发现「{f.Name}」id={f.DeviceId ?? "?"}，地址 {f.Endpoint}（{Ms(sw)}）");
    endpoint = f.Endpoint;
}

// ② 未授权访问应被拒绝
Step("未配对时访问应返回 401");
try
{
    using var bad = new PhoneClient(endpoint, "wrong", null);
    await bad.InfoAsync();
    Fail("没有被拒绝");
}
catch (PhoneException e) when (e.Kind == PhoneErrorKind.Unauthorized)
{
    Ok("被拒绝");
}

// ③ 配对
Step("配对（错误的码应失败，正确的码应成功）");
try
{
    await PhoneClient.PairAsync(endpoint, "000000", "clcheck");
    Fail("错误配对码居然成功了");
}
catch (PhoneException e) when (e.Kind == PhoneErrorKind.BadPairingCode)
{
    Ok("错误配对码被拒绝");
}
var (pr, cert) = await PhoneClient.PairAsync(endpoint, code, "clcheck");
Ok($"配对成功：{pr.Name}，证书指纹 {cert[..16]}…");
using var client = new PhoneClient(endpoint, pr.Token, cert, "clcheck");

Step("证书固定（指纹对不上应拒绝连接，令牌不发出去）");
var zeros = new string('0', 64);
using (var impostor = new PhoneClient(endpoint, pr.Token, zeros))
{
    try
    {
        await impostor.InfoAsync(TimeSpan.FromSeconds(4));
        Fail("指纹不对居然连上了");
    }
    catch (Exception e)
    {
        if (!impostor.Pin.Mismatch) Fail($"失败了，但不是因为证书：{e.Message}");
        if (e is not PhoneException { Kind: PhoneErrorKind.CertMismatch }) Fail($"应报证书不对，实际：{e.GetType().Name} {e.Message}");
        Ok("被拒绝（CertMismatch）");
    }
}
if (await PhoneClient.IdentifyAsync(endpoint, cert) != pr.DeviceId || await PhoneClient.IdentifyAsync(endpoint, zeros) is not null)
    Fail("identify 没按指纹核对");
Ok("identify 按指纹核对");

var info = await client.InfoAsync();
Ok($"设备信息：{info.Model} / Android {info.Android} / 电量 {info.Battery?.ToString() ?? "?"}%");

// ④ 媒体列表
Step("媒体列表");
List<MediaItem> images = [];
foreach (var kind in Enum.GetValues<MediaKind>())
{
    var sw = Stopwatch.StartNew();
    var page = await client.MediaAsync(kind, 0, 100);
    Ok($"{kind.Title()}：共 {page.Total} 个，首页 {page.Items.Count} 个（{Ms(sw)}）");
    if (kind == MediaKind.Image) images = page.Items;
}
if (images.Count == 0) Fail("没有照片，无法继续");
var first = images[0];

// ⑤ 缩略图：冷缓存 vs 热缓存
var batch = images.Take(40).ToList();
Step($"缩略图（并发拉取 {batch.Count} 张）");
var cache = new ThumbnailCache($"clcheck-{pr.DeviceId}");
cache.ClearDisk();
async Task<(int, long)> FetchAll(ThumbnailCache tc)
{
    var r = await Task.WhenAll(batch.Select(i => tc.DataAsync(i, client)));
    return (r.Count(d => d is not null), r.Sum(d => (long)(d?.Length ?? 0)));
}
var t = Stopwatch.StartNew();
var (n1, b1) = await FetchAll(cache);
Ok($"从手机拉取：{n1} 张，{b1 / 1024} KB（{Ms(t)}）");
t.Restart();
// 同时请求同一张只发一次网络请求
var dup = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => cache.DataAsync(first, client)));
if (dup.Any(d => d is null)) Fail("并发请求同一张缩略图失败");
var (n2, _) = await FetchAll(new ThumbnailCache($"clcheck-{pr.DeviceId}")); // 新实例 = 只剩磁盘缓存
Ok($"读磁盘缓存：{n2} 张（{Ms(t)}）");

// ⑥ Range
Step("Range 请求（视频拖动进度条靠它）");
using (var resp = await client.RawRequestAsync(first, "bytes=0-99"))
{
    var data = await resp.Content.ReadAsByteArrayAsync();
    if (resp.StatusCode != HttpStatusCode.PartialContent || data.Length != 100)
        Fail($"期望 206 + 100 字节，实际 {(int)resp.StatusCode} + {data.Length}");
    Ok($"206 Partial Content，{resp.Content.Headers.ContentRange}");
}

Step("本机播放转发（系统播放器走它）");
var playUri = await client.PlaybackUriAsync(first);
using (var local = new HttpClient())
{
    var req = new HttpRequestMessage(HttpMethod.Get, playUri);
    req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(100, 199);
    using var presp = await local.SendAsync(req);
    var pdata = await presp.Content.ReadAsByteArrayAsync();
    using var direct = await client.RawRequestAsync(first, "bytes=100-199");
    var ddata = await direct.Content.ReadAsByteArrayAsync();
    if (presp.StatusCode != HttpStatusCode.PartialContent || pdata.Length != 100 || !pdata.AsEnumerable().SequenceEqual(ddata))
        Fail($"转发的 Range 不对：{(int)presp.StatusCode} + {pdata.Length}");
    var whole = await local.GetByteArrayAsync(playUri);
    if (whole.Length != first.Size) Fail($"转发整个文件 {whole.Length} 字节，应为 {first.Size}");
    foreach (var (range, status, length) in new[] { ($"bytes=-50", 206, 50), ($"bytes={first.Size}-", 416, 0) })
    {
        var r = new HttpRequestMessage(HttpMethod.Get, playUri);
        r.Headers.TryAddWithoutValidation("Range", range);
        using var rr = await local.SendAsync(r);
        var d = await rr.Content.ReadAsByteArrayAsync();
        if ((int)rr.StatusCode != status || d.Length != length) Fail($"{range} 应返回 {status} + {length} 字节，实际 {(int)rr.StatusCode} + {d.Length}");
    }
    using var guess = await local.GetAsync($"http://127.0.0.1:{playUri.Port}/guess.jpg");
    if (guess.StatusCode != HttpStatusCode.NotFound) Fail("猜的路径没有被拒绝");
    Ok($"Range 和整文件都对，{playUri.Host}:{playUri.Port}，猜路径返回 404");
}

t.Restart();
var dl = await client.DownloadAsync(first, Path.Combine(Path.GetTempPath(), "clcheck"));
Ok($"下载原图 {first.Name}：{new FileInfo(dl).Length / 1024} KB（{Ms(t)}）");

// ⑦ 发送文件到手机
Step("发送图片到手机（拖到托盘面板时走的就是这条路）");
var sample = Path.Combine(Path.GetTempPath(), "ColorLink 测试图.jpg");
File.Copy(dl, sample, overwrite: true);
t.Restart();
var uploaded = await client.UploadAsync(sample);
Ok($"上传 {Path.GetFileName(sample)}（{new FileInfo(sample).Length / 1024} KB）用时 {Ms(t)}，手机返回 {uploaded?.Name ?? "（非图片）"}");
var newest = await client.MediaAsync(MediaKind.Image, 0, 3);
if (newest.Items.FirstOrDefault()?.Name != uploaded?.Name) Fail("上传的图片没有出现在「最近照片」第一位");
Ok("「最近照片」第一张就是刚发过去的图片");

// ⑧ 短信验证码识别
Step("短信验证码识别");
(string, string?)[] samples =
[
    ("【招商银行】您的验证码为 482913，5分钟内有效，请勿泄露。", "482913"),
    ("【淘宝】验证码：7731，用于身份验证，10分钟内有效。", "7731"),
    ("您正在支付1000元，动态码 835120，切勿告知他人。", "835120"),
    ("G-583201 is your Google verification code.", "583201"),
    ("Your Uber code is 4821. Never share this code.", "4821"),
    ("【京东】校验码 Ab3k9Q，请于5分钟内输入。", "Ab3k9Q"),
    ("您尾号6789的卡于10月22日消费128.00元。", null),
    ("明天下午3点开会，会议室 2048。", null),
];
foreach (var (text, expected) in samples)
{
    var got = VerificationCode.Extract(text);
    if (got != expected) Fail($"「{text}」应识别为 {expected ?? "无"}，实际 {got ?? "无"}");
}
Ok($"{samples.Length} 条样例全部识别正确（含 3 条干扰数字和 2 条非验证码短信）");

// ⑨ 端口探测
Step("端口探测");
var probeOpen = await PortProbe.CheckAsync(endpoint.Host, endpoint.Port);
var probeRefused = await PortProbe.CheckAsync("127.0.0.1", 9);
var probeAway = await PortProbe.CheckAsync("10.255.255.1", 8765, TimeSpan.FromSeconds(1.5));
if (probeOpen != PortProbe.Result.Open || probeRefused != PortProbe.Result.Refused || probeAway != PortProbe.Result.Unreachable)
    Fail($"应为 通/拒绝/连不到，实际 {probeOpen}/{probeRefused}/{probeAway}");
Ok("手机端口在听 → 通；在线但没在运行 → 拒绝；不在网络里 → 连不到");

// ⑩ 事件流
Step("事件流");
using var evCts = new CancellationTokenSource();
var events = client.EventsAsync(evCts.Token).GetAsyncEnumerator();
if (!await events.MoveNextAsync() || events.Current is not PhoneEvent.Hello) Fail("没收到 hello");
Ok("收到 hello");

if (trigger)
{
    // 模拟手机的调试接口只接受本机请求，所以固定走 127.0.0.1
    var pin = new CertPin(cert);
    using var debug = new HttpClient(new SocketsHttpHandler { SslOptions = { RemoteCertificateValidationCallback = pin.Validate } })
    { BaseAddress = new PhoneEndpoint("127.0.0.1", endpoint.Port).BaseUri };

    async Task<T> Next<T>(TimeSpan timeout) where T : PhoneEvent
    {
        using var cts = new CancellationTokenSource(timeout);
        while (true)
        {
            var move = events.MoveNextAsync().AsTask();
            if (await Task.WhenAny(move, Task.Delay(Timeout.Infinite, cts.Token).ContinueWith(_ => { })) != move)
                throw new TimeoutException($"{timeout.TotalSeconds} 秒内没收到 {typeof(T).Name}");
            if (!await move) throw new Exception("事件流结束了");
            if (events.Current is T ev) return ev;
        }
    }

    var r1 = await debug.PostAsync("debug/screenshot", null);
    if (!r1.IsSuccessStatusCode) Fail("触发模拟截图失败（--trigger 只能对本机的 mock_phone.py 使用）");
    t.Restart();
    var shot = await Next<PhoneEvent.Screenshot>(TimeSpan.FromSeconds(10));
    Ok($"收到截图事件 {shot.Item.Name}（{Ms(t)}）");
    var shotFile = await client.DownloadAsync(shot.Item, Path.Combine(AppDirs.Root, "shots"));
    Ok($"截图已下载：{Path.GetFileName(shotFile)}，{new FileInfo(shotFile).Length / 1024} KB，从截图到下载完 {Ms(t)}");

    await debug.PostAsync("debug/notify", null);
    t.Restart();
    var n = await Next<PhoneEvent.Notification>(TimeSpan.FromSeconds(10));
    var vc = VerificationCode.Extract(n.Value.Text);
    if (vc is null) Fail($"短信事件里没识别出验证码：{n.Value.Text}");
    Ok($"收到短信事件（{n.Value.App}），识别出验证码 {vc}（{Ms(t)}）");

    await debug.PostAsync("debug/clipboard?text=" + Uri.EscapeDataString("你好，ColorLink"), null);
    var clip = await Next<PhoneEvent.Clipboard>(TimeSpan.FromSeconds(10));
    if (clip.Text != "你好，ColorLink") Fail($"文字不对：{clip.Text}");
    Ok("收到手机分享的中文文字");

    await debug.PostAsync("debug/power?charging=1", null);
    var power = await Next<PhoneEvent.Power>(TimeSpan.FromSeconds(10));
    Ok($"收到充电事件：charging={power.Charging} battery={power.Battery}");

    var dndNow = await client.SetDndAsync(DndMode.Priority);
    var dndEv = await Next<PhoneEvent.Dnd>(TimeSpan.FromSeconds(10));
    await client.SetDndAsync(DndMode.All);
    if (dndNow != DndMode.Priority || dndEv.Mode != DndMode.Priority) Fail("免打扰没改成");
    Ok("免打扰：开成「仅优先」并收到回调，再关掉");

    // 敲门：监听 UDP 8766，让模拟手机敲门，验证签名通过
    Step("敲门（UDP 8766，HMAC 签名）");
    using var knocks = new KnockListener { TokenFor = id => id == pr.DeviceId ? pr.Token : null };
    var got = new TaskCompletionSource<Knock>();
    knocks.OnKnock = k => got.TrySetResult(k);
    knocks.Start();
    await Task.Delay(500);
    // 手机只在没有电脑连着时敲门，所以先断开事件流
    await evCts.CancelAsync();
    try { await events.DisposeAsync(); } catch { }
    await Task.Delay(300);
    t.Restart();
    await debug.PostAsync("debug/knock", null);
    var knock = await got.Task.WaitAsync(TimeSpan.FromSeconds(5));
    Ok($"收到敲门：{knock.DeviceId} @ {knock.Endpoint}（{Ms(t)}）");
}
else
{
    Console.WriteLine("  （加 --trigger 可测试截图、短信、文字、充电、免打扰、敲门）");
}

Console.WriteLine("\n全部通过 ✅");
