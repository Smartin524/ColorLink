using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ColorLink.Core;

/// <summary>电脑这边和系统打交道的部分（剪贴板、通知、资源管理器、蓝牙广播），由 App 实现</summary>
public interface IPlatform
{
    Task<bool> CopyImageAsync(string path);
    Task<bool> CopyFilesAsync(IReadOnlyList<string> paths);
    void CopyText(string text);
    /// <param name="reveal">点通知时在资源管理器里显示的文件</param>
    /// <param name="tag">同一个 tag 的通知会替换旧的</param>
    void Notify(string title, string body, string? image = null, IReadOnlyList<string>? reveal = null, string? tag = null);
    void Reveal(IReadOnlyList<string> paths);
    /// <summary>蓝牙广播（让手机知道电脑在旁边）</summary>
    void SetBeacon(bool on);
}

public enum LinkState { Searching, NeedsPairing, Connecting, Connected, Retrying, Paused }

/// <summary>
/// 连接状态机：找手机 → 连接 → 订阅事件 → 断了就退避重连。整个过程无需人工干预。
///
/// 所有属性和方法都在创建它的线程（App 的界面线程）上用：构造时记下 SynchronizationContext，
/// 后台回调（敲门、mDNS）都切回这个线程，所以内部不用加锁，界面可以直接绑定。
/// </summary>
public sealed class LinkController : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    readonly IPlatform _platform;
    readonly SynchronizationContext? _ui;
    readonly Settings _settings = Settings.Shared;
    readonly PhoneBrowser _browser = new();
    readonly KnockListener _knocks = new();
    /// <summary>手机敲门时报来的最新地址，优先于 mDNS 和上次的地址</summary>
    readonly Dictionary<string, PhoneEndpoint> _knocked = [];
    TaskCompletionSource _wake = new(TaskCreationOptions.RunContinuationsAsynchronously);
    CancellationTokenSource? _streamCts;
    CancellationTokenSource? _syncCts;
    CancellationTokenSource? _prefetchCts;
    bool _syncing;
    bool _asleep, _locked;
    DateTimeOffset? _refusedSince;
    readonly Dictionary<string, string> _downloads;

    public string ClientName { get; }

    public LinkController(IPlatform platform, string? clientName = null, bool startDiscovery = true)
    {
        _platform = platform;
        _ui = SynchronizationContext.Current;
        ClientName = clientName ?? PhoneClient.DefaultClientName;
        _downloads = _settings.GetMap("downloads");
        _autoCopyScreenshots = _settings.GetBool("autoCopyScreenshots", true);
        _mirrorNotifications = _settings.GetBool("mirrorNotifications", true);
        _autoCopyCodes = _settings.GetBool("autoCopyCodes", true);

        // 没连上手机也能翻本机保存的相册
        if (PairedStore.All().FirstOrDefault() is { } p) UseLibrary(p.DeviceId);

        _browser.OnChange = phones => Post(() =>
        {
            Discovered = phones;
            Wake();
        });
        if (startDiscovery) _browser.Start();

        _knocks.TokenFor = id => PairedStore.All().FirstOrDefault(x => x.DeviceId == id)?.Token;
        _knocks.OnKnock = knock => Post(() =>
        {
            AppLog.Write($"收到手机敲门：{knock.Endpoint}");
            _knocked[knock.DeviceId] = knock.Endpoint;
            if (IsConnected)
            {
                // 手机只在没有电脑连着（或刚换了网络）时才敲门。我们却显示“已连接”，
                // 说明这条连接已经断了，只是没收到关闭通知（例如手机突然断 Wi-Fi）。立即断开重连。
                AppLog.Write("已连接却收到敲门，判定为假连接，立即重连");
                _streamCts?.Cancel();
            }
            Wake();
        });
        _knocks.Start();
        _platform.SetBeacon(true);
        _ = RunAsync();
    }

    void Post(Action a)
    {
        if (_ui is null) a();
        else _ui.Post(_ => a(), null);
    }

    bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // MARK: 状态

    LinkState _state = LinkState.Searching;
    public LinkState State { get => _state; private set { if (Set(ref _state, value)) { AppLog.Write($"状态：{value} {StateDetail}"); Raise(nameof(IsConnected)); } } }

    string _stateDetail = "";
    /// <summary>状态附带的说明：连的是哪台手机、为什么重试</summary>
    public string StateDetail { get => _stateDetail; private set => Set(ref _stateDetail, value); }

    public bool IsConnected => State == LinkState.Connected;

    IReadOnlyList<DiscoveredPhone> _discovered = [];
    public IReadOnlyList<DiscoveredPhone> Discovered { get => _discovered; private set => Set(ref _discovered, value); }

    bool _phoneAppDown;
    /// <summary>手机在线、但上面的 ColorLink 没在运行（端口拒绝连接超过 5 分钟）</summary>
    public bool PhoneAppDown { get => _phoneAppDown; private set => Set(ref _phoneAppDown, value); }

    PhoneClient? _client;
    public PhoneClient? Client { get => _client; private set => Set(ref _client, value); }

    PairedPhone? _device;
    public PairedPhone? Device { get => _device; private set => Set(ref _device, value); }

    DeviceInfo? _info;
    public DeviceInfo? Info { get => _info; private set { _info = value; Raise(nameof(Info)); } }

    DndMode? _dnd;
    /// <summary>手机的免打扰档位；null：没连上，或手机没开通知使用权（按钮不可用）</summary>
    public DndMode? Dnd { get => _dnd; private set => Set(ref _dnd, value); }

    ThumbnailCache? _thumbs;
    public ThumbnailCache? Thumbs { get => _thumbs; private set => Set(ref _thumbs, value); }

    MediaLibrary? _library;
    /// <summary>手机相册在本机的完整副本</summary>
    public MediaLibrary? Library { get => _library; private set => Set(ref _library, value); }

    Guid _connectionId = Guid.NewGuid();
    /// <summary>每次连上换一个新值，界面据此刷新列表</summary>
    public Guid ConnectionId { get => _connectionId; private set => Set(ref _connectionId, value); }

    string? _lastEvent;
    public string? LastEvent { get => _lastEvent; private set => Set(ref _lastEvent, value); }

    IReadOnlyList<MediaItem> _recent = [];
    /// <summary>手机上最新的三张照片，显示在托盘面板里</summary>
    public IReadOnlyList<MediaItem> Recent { get => _recent; private set => Set(ref _recent, value); }

    string? _transfer;
    /// <summary>发送文件到手机的进度提示；null 表示空闲</summary>
    public string? Transfer { get => _transfer; private set => Set(ref _transfer, value); }

    bool _paused;
    public bool Paused { get => _paused; private set => Set(ref _paused, value); }

    bool _autoCopyScreenshots;
    public bool AutoCopyScreenshots
    {
        get => _autoCopyScreenshots;
        set { if (Set(ref _autoCopyScreenshots, value)) _settings.SetBool("autoCopyScreenshots", value); }
    }

    bool _mirrorNotifications;
    /// <summary>同步手机通知（手机端转发会响的通知，微信除外）</summary>
    public bool MirrorNotifications
    {
        get => _mirrorNotifications;
        set { if (Set(ref _mirrorNotifications, value)) _settings.SetBool("mirrorNotifications", value); }
    }

    bool _autoCopyCodes;
    /// <summary>短信里识别到验证码就直接复制到剪贴板</summary>
    public bool AutoCopyCodes
    {
        get => _autoCopyCodes;
        set { if (Set(ref _autoCopyCodes, value)) _settings.SetBool("autoCopyCodes", value); }
    }

    /// <summary>发现变化、配对完成、电脑唤醒时调用，打断正在进行的等待。</summary>
    public void Wake() => _wake.TrySetResult();

    void UseLibrary(string deviceId)
    {
        if (Library?.DeviceId == deviceId) return;
        Thumbs = new ThumbnailCache(deviceId);
        Library = new MediaLibrary(deviceId);
    }

    // MARK: 锁屏 / 睡眠

    /// <summary>电脑睡眠前主动断开（否则手机要等 TCP 重传放弃、十几分钟后才知道电脑走了）</summary>
    public void SetAsleep(bool v)
    {
        _asleep = v;
        UpdatePaused();
    }

    public void SetLocked(bool v)
    {
        _locked = v;
        UpdatePaused();
    }

    /// <summary>
    /// 暂停：断开事件流（手机那边立刻收到关闭，前台服务退掉），停掉蓝牙广播免得手机白白敲门。
    /// 恢复：醒来时锁屏状态可能晚一拍才到，等 1 秒再连，免得连上又断
    /// </summary>
    void UpdatePaused()
    {
        bool p = _asleep || _locked;
        if (p == Paused) return;
        Paused = p;
        AppLog.Write(p ? $"电脑{(_asleep ? "睡眠" : "锁屏")}，断开手机" : "电脑已解锁，恢复连接");
        _platform.SetBeacon(!p);
        if (p)
        {
            _streamCts?.Cancel();
            Wake();
        }
        else
        {
            _browser.Refresh();
            _ = Task.Delay(1000).ContinueWith(_ => Post(() => { if (!Paused) Wake(); }));
        }
    }

    // MARK: 配对

    public async Task PairAsync(DiscoveredPhone? phone, string manualAddress, string code)
    {
        var endpoint = phone?.Endpoint ?? PhoneEndpoint.Parse(manualAddress);
        var (r, cert) = await PhoneClient.PairAsync(endpoint, code.Trim(), ClientName);
        PairedStore.Save(new PairedPhone { DeviceId = r.DeviceId, Name = r.Name, Token = r.Token, LastEndpoint = endpoint, CertSha256 = cert });
        AppLog.Write($"和「{r.Name}」配对成功，证书 {cert[..16]}…");
        Wake();
    }

    public void Forget()
    {
        if (Device is { } d)
        {
            PairedStore.Remove(d.DeviceId);
            AppLog.Write($"取消和「{d.Name}」的配对");
        }
        _streamCts?.Cancel();
        Wake();
    }

    // MARK: 主循环

    /// <summary>
    /// 找不到手机时看看它本身在不在：手机在线、但 ColorLink 的端口直接拒绝连接，说明手机上的 ColorLink 没在运行。
    /// 被杀后通常几分钟内会自己回来，所以持续 5 分钟以上才提示，每次只发一条通知
    /// </summary>
    async Task CheckPhoneAppAsync()
    {
        if (PairedStore.All().FirstOrDefault()?.LastEndpoint is not { } ep) return;
        if (await PortProbe.CheckAsync(ep.Host, ep.Port) != PortProbe.Result.Refused)
        {
            _refusedSince = null;
            PhoneAppDown = false;
            return;
        }
        var since = _refusedSince ??= DateTimeOffset.Now;
        if (PhoneAppDown || DateTimeOffset.Now - since < TimeSpan.FromMinutes(5)) return;
        PhoneAppDown = true;
        AppLog.Write($"手机在线，但 ColorLink 没在运行（{ep} 拒绝连接已超过 5 分钟）");
        _platform.Notify("手机上的 ColorLink 没在运行", "可能被系统停掉了，在手机上打开一下 ColorLink 就能恢复");
    }

    async Task RunAsync()
    {
        double backoff = 1;
        while (true)
        {
            if (Paused)
            {
                State = LinkState.Paused;
                await PauseAsync(3600); // 解锁 / 醒来时 Wake() 会提前结束
                backoff = 1;
                continue;
            }
            var target = await TargetAsync();
            if (target is null)
            {
                var paired = PairedStore.All().Select(p => p.DeviceId).ToHashSet();
                if (Discovered.FirstOrDefault(d => !paired.Contains(d.DeviceId ?? "")) is { } unpaired)
                {
                    StateDetail = unpaired.Name;
                    State = LinkState.NeedsPairing;
                }
                else
                {
                    StateDetail = "";
                    State = LinkState.Searching;
                }
                if (paired.Count == 0)
                {
                    await PauseAsync(30);
                }
                else
                {
                    await CheckPhoneAppAsync();
                    // 配过对但暂时找不到：按退避间隔继续探测上次的地址和网关
                    await PauseAsync(backoff);
                    backoff = Math.Min(backoff * 2, 15);
                }
                continue;
            }

            var (phone, endpoint) = target.Value;
            StateDetail = phone.Name;
            State = LinkState.Connecting;
            var c = new PhoneClient(endpoint, phone.Token, phone.CertSha256, ClientName);
            try
            {
                var info = await c.InfoAsync(TimeSpan.FromSeconds(4));
                // 连接途中锁屏 / 睡眠：那时还没有事件流可断，这里不接着连，回到循环开头进入暂停
                if (Paused)
                {
                    c.Dispose();
                    continue;
                }
                var p = phone with { LastEndpoint = endpoint, Name = info.Name };
                if (p.CertSha256 is null && c.Pin.Seen is { } cert)
                {
                    // 升级前配的对：第一次用 HTTPS 连上时记下手机的证书，以后只认它
                    p = p with { CertSha256 = cert };
                    AppLog.Write($"记下手机证书指纹 {cert[..16]}…");
                }
                PairedStore.Save(p);

                UseLibrary(p.DeviceId);
                Client = c;
                Device = p;
                Info = info;
                Dnd = DndModeExtensions.Parse(info.Dnd);
                ConnectionId = Guid.NewGuid();
                _refusedSince = null;
                PhoneAppDown = false;
                StateDetail = p.Name;
                State = LinkState.Connected;
                backoff = 1;
                _ = RefreshRecentAsync();
                StartBackgroundSync(c);

                _streamCts = new CancellationTokenSource();
                await foreach (var ev in c.EventsAsync(_streamCts.Token))
                    Handle(ev, c);
            }
            catch (PhoneException e) when (e.Kind == PhoneErrorKind.Unauthorized)
            {
                // 手机上点了「取消所有电脑的配对」
                AppLog.Write("手机返回 401，已取消配对");
                PairedStore.Remove(phone.DeviceId);
                LastEvent = "手机已取消配对，请重新配对";
            }
            catch (Exception) when (c.Pin.Mismatch)
            {
                // 手机重装过 ColorLink（证书跟着换了），或者有别的设备冒充这台手机。令牌没有发出去
                AppLog.Write($"{endpoint} 的证书和配对时不一样，没有连接");
                LastEvent = "手机证书变了，请重新配对";
            }
            catch (Exception e)
            {
                // 锁屏 / 睡眠、收到敲门时是自己取消的，不算失败
                if (!Paused && e is not OperationCanceledException)
                {
                    LastEvent = e.Message;
                    AppLog.Write($"连接 {endpoint} 失败：{e.GetType().Name} {e.Message}");
                }
            }
            finally
            {
                _streamCts?.Dispose();
                _streamCts = null;
            }

            _syncCts?.Cancel();
            _syncCts = null;
            _syncing = false;
            _prefetchCts?.Cancel();
            _prefetchCts = null;
            if (Client is not null)
            {
                Client = null;
                Recent = [];
                Dnd = null;
            }
            c.Dispose();
            StateDetail = LastEvent ?? phone.Name;
            State = LinkState.Retrying;
            if (_knocked.Count > 0) continue; // 手机刚敲过门，不用等
            await PauseAsync(backoff);
            backoff = Math.Min(backoff * 2, 15);
        }
    }

    /// <summary>选一个要连的手机：手机敲门报来的地址 &gt; mDNS 刚发现的地址 &gt; 上次成功的地址 / 网关。</summary>
    async Task<(PairedPhone, PhoneEndpoint)?> TargetAsync()
    {
        var paired = PairedStore.All();
        foreach (var p in paired)
        {
            // 敲门包带签名，已经验证过身份
            if (_knocked.Remove(p.DeviceId, out var ep)) return (p, ep);
        }
        foreach (var p in paired)
        {
            if (Discovered.FirstOrDefault(d => d.DeviceId == p.DeviceId) is { } d) return (p, d.Endpoint);
        }
        // 没有敲门也没有 mDNS：试上次的地址，以及网关（电脑连着手机热点时，网关就是手机）。
        // 先不带令牌核对设备 ID，对上了才连
        var gateways = PhoneBrowser.DefaultGateways();
        foreach (var p in paired)
        {
            var candidates = new List<PhoneEndpoint>();
            if (p.LastEndpoint is { } last) candidates.Add(last);
            foreach (var gw in gateways)
            {
                var ep = new PhoneEndpoint(gw, p.LastEndpoint?.Port ?? PhoneEndpoint.DefaultPort);
                if (!candidates.Contains(ep)) candidates.Add(ep);
            }
            foreach (var ep in candidates)
                if (await PhoneClient.IdentifyAsync(ep, p.CertSha256) == p.DeviceId) return (p, ep);
        }
        return null;
    }

    /// <summary>等待指定秒数，期间若有 Wake() 则提前返回。</summary>
    async Task PauseAsync(double seconds)
    {
        _wake = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await Task.WhenAny(Task.Delay(TimeSpan.FromSeconds(seconds)), _wake.Task);
    }

    // MARK: 事件

    void Handle(PhoneEvent ev, PhoneClient c)
    {
        switch (ev)
        {
            case PhoneEvent.Hello h:
                Info = h.Info;
                Dnd = DndModeExtensions.Parse(h.Info.Dnd);
                UpdatePrefetch();
                break;

            case PhoneEvent.Dnd d:
                AppLog.Write($"手机免打扰：{d.Mode.Title()}");
                Dnd = d.Mode;
                break;

            case PhoneEvent.Power pw:
                AppLog.Write(pw.Charging ? "手机已接上电源" : "手机已拔掉电源");
                if (Info is { } info)
                {
                    info.Charging = pw.Charging;
                    if (pw.Battery is { } b) info.Battery = b;
                    Info = info;
                }
                UpdatePrefetch();
                break;

            case PhoneEvent.Media:
                _ = RefreshRecentAsync();
                break;

            case PhoneEvent.Screenshot s:
                AppLog.Write($"收到截图事件 {s.Item.Name}");
                LastEvent = $"收到截图 {s.Item.Name}";
                _ = RefreshRecentAsync();
                if (AutoCopyScreenshots) _ = CopyScreenshotAsync(s.Item, c);
                break;

            case PhoneEvent.Notification n:
                OnNotification(n.Value);
                break;

            case PhoneEvent.Shared sh:
                AppLog.Write($"收到手机分享的 {sh.Files.Count} 个文件");
                _ = ReceiveSharedAsync(sh.Files, c);
                break;

            case PhoneEvent.Clipboard cb:
                _platform.CopyText(cb.Text);
                _platform.Notify("已收到手机发来的文字", cb.Text);
                LastEvent = "手机文字已复制到剪贴板";
                break;
        }
    }

    async Task CopyScreenshotAsync(MediaItem item, PhoneClient c)
    {
        try
        {
            var path = await c.DownloadAsync(item, AppDirs.Downloads);
            if (await _platform.CopyImageAsync(path))
            {
                _platform.Notify("截图已复制", "可以直接 Ctrl+V 粘贴", image: path, reveal: [path]);
                LastEvent = "截图已复制到剪贴板";
            }
        }
        catch (Exception e)
        {
            LastEvent = $"截图下载失败：{e.Message}";
        }
    }

    void OnNotification(PhoneNotification n)
    {
        if (!MirrorNotifications) return;
        // 只在短信里找验证码：别的 App 的通知里的数字（订单号、金额）不能当验证码复制走。
        // 旧版手机不带 sms 字段，那时只转发短信，按短信处理
        bool isSms = n.Sms ?? true;
        var code = isSms ? VerificationCode.Extract(n.Text) : null;
        // 日志里不记通知内容和验证码
        AppLog.Write($"收到{(isSms ? "短信" : $"通知（{n.App}）")}（{n.Text.Length} 字）" +
                     (isSms ? (code is null ? "，没有识别出验证码" : $"，识别出验证码{(AutoCopyCodes ? "并已复制" : "")}") : ""));
        if (code is not null)
        {
            if (AutoCopyCodes)
            {
                _platform.CopyText(code);
                LastEvent = $"验证码 {code} 已复制";
            }
            _platform.Notify($"验证码 {code}{(AutoCopyCodes ? "（已复制）" : "")}", $"{n.Title}：{n.Text}", tag: n.Key);
        }
        else
        {
            _platform.Notify($"{n.App} · {n.Title}", n.Text, tag: n.Key);
        }
    }

    /// <summary>手机分享的所有文件直接存进「文档\Colorlink」，并放进剪贴板</summary>
    async Task ReceiveSharedAsync(IReadOnlyList<SharedFile> files, PhoneClient c)
    {
        var saved = new List<string>();
        foreach (var f in files)
        {
            try { saved.Add(await c.DownloadAsync(f, AppDirs.Downloads)); }
            catch (Exception e) { AppLog.Write($"取分享的文件失败 {f.Name}：{e.Message}"); }
        }
        if (saved.Count == 0)
        {
            LastEvent = "手机分享的文件没取到";
            return;
        }
        var images = saved.Where(MimeTypes.IsImage).ToList();
        // 一张图片放图片数据，哪里都能粘贴；其他情况放文件
        bool copied = saved.Count == 1 && images.Count == 1 ? await _platform.CopyImageAsync(saved[0]) : await _platform.CopyFilesAsync(saved);
        var what = saved.Count == 1 ? (images.Count == 1 ? "图片" : Path.GetFileName(saved[0]))
            : images.Count == saved.Count ? $"{saved.Count} 张图片" : $"{saved.Count} 个文件";
        _platform.Notify($"收到手机分享的{what}", (copied ? "已复制，可以直接 Ctrl+V 粘贴；" : "") + "点按在资源管理器中显示",
            image: images.FirstOrDefault(), reveal: saved);
        LastEvent = $"收到手机分享的{what}";
    }

    // MARK: 最近照片 / 电量

    public async Task RefreshRecentAsync()
    {
        if (Client is not { } c) return;
        try { Recent = (await c.MediaAsync(MediaKind.Image, 0, 3)).Items; }
        catch { /* 下次再说 */ }
    }

    /// <summary>打开面板时问一次电量。平时不问：电量和充电状态靠手机推的事件更新，定时问会把深睡的手机叫醒</summary>
    public async Task RefreshInfoAsync()
    {
        if (Client is not { } c) return;
        try
        {
            var info = await c.InfoAsync(TimeSpan.FromSeconds(5));
            Info = info;
            Dnd = DndModeExtensions.Parse(info.Dnd);
            UpdatePrefetch();
        }
        catch { /* 连接本身会处理断线 */ }
    }

    // MARK: 免打扰

    /// <summary>面板上的免打扰按钮：关着就开成「仅优先」，开着（不管哪一档）就关。手机等系统改完才回，回的是实际档位</summary>
    public async Task ToggleDndAsync()
    {
        if (Client is not { } c || Dnd is not { } current) return;
        var target = current.IsOn() ? DndMode.All : DndMode.Priority;
        try
        {
            var actual = await c.SetDndAsync(target);
            Dnd = actual;
            if (actual.IsOn() == target.IsOn())
            {
                LastEvent = target.IsOn() ? "免打扰已开" : "免打扰已关";
            }
            else
            {
                // 手机上手动开的勿扰，电脑只能关自己开的那个
                LastEvent = target.IsOn() ? "手机没有开启免打扰" : "免打扰是在手机上开的，电脑关不掉";
                AppLog.Write($"免打扰没改成：想要 {target.Title()}，手机是 {actual.Title()}");
            }
        }
        catch (Exception e)
        {
            LastEvent = $"免打扰设置失败：{e.Message}";
            AppLog.Write($"免打扰设置失败：{e.Message}");
        }
    }

    // MARK: 本机相册副本

    /// <summary>连上后在后台把照片、视频列表和手机核对一遍，核对完再看要不要补缩略图</summary>
    void StartBackgroundSync(PhoneClient c)
    {
        _syncCts?.Cancel();
        if (Library is not { } library) return;
        var cts = _syncCts = new CancellationTokenSource();
        _syncing = true;
        _ = Task.Run(async () =>
        {
            foreach (var kind in new[] { MediaKind.Image, MediaKind.Video })
                await library.SyncAsync(kind, c, cts.Token);
        }).ContinueWith(_ => Post(() =>
        {
            if (cts.IsCancellationRequested) return;
            _syncing = false;
            UpdatePrefetch();
        }));
    }

    /// <summary>
    /// 本机还没有的缩略图只在手机充电时补：生成缩略图要占手机 CPU，不充电时相册里看到哪张再取哪张。
    /// 开始和停下都由手机推来的充电事件（和 hello）决定，不定时去问手机。
    /// </summary>
    void UpdatePrefetch()
    {
        if (Client is not { } c || Library is not { } library || Thumbs is not { } thumbs || Info?.Charging != true || _syncing)
        {
            _prefetchCts?.Cancel();
            _prefetchCts = null;
            return;
        }
        if (_prefetchCts is not null) return;
        var cts = _prefetchCts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            bool announced = false;
            // 取不到的（手机上生成不了缩略图的文件）本次连接里不再重试
            var failed = new HashSet<string>();
            while (!cts.IsCancellationRequested)
            {
                var missing = new[] { MediaKind.Image, MediaKind.Video }
                    .SelectMany(k => library[k]?.Items ?? [])
                    .Where(i => !failed.Contains(i.CacheKey) && !thumbs.Has(i))
                    .Take(200).ToList();
                if (missing.Count == 0)
                {
                    if (announced) AppLog.Write("缩略图已全部存到本机" + (failed.Count == 0 ? "" : $"（{failed.Count} 张手机上生成不了，跳过）"));
                    return;
                }
                if (!announced)
                {
                    AppLog.Write("手机在充电，后台补齐缩略图");
                    announced = true;
                }
                // 每轮最多 200 张、同时 3 个请求；拔掉电源时任务被取消
                await Parallel.ForEachAsync(missing, new ParallelOptions { MaxDegreeOfParallelism = 3, CancellationToken = cts.Token },
                    async (item, ct) =>
                    {
                        if (!await thumbs.PrefetchAsync(item, c, ct))
                            lock (failed) failed.Add(item.CacheKey);
                    });
            }
        }, cts.Token).ContinueWith(_ => Post(() => { if (_prefetchCts == cts) _prefetchCts = null; }));
    }

    // MARK: 已下载

    string DownloadKey(MediaItem item) => $"{Device?.DeviceId ?? Library?.DeviceId ?? ""}/{item.CacheKey}";

    /// <summary>这张照片下载到本机的文件；文件被删了就当没下载过</summary>
    public string? LocalCopy(MediaItem item) =>
        _downloads.TryGetValue(DownloadKey(item), out var path) && File.Exists(path) ? path : null;

    public bool IsDownloaded(MediaItem item) => LocalCopy(item) is not null;

    /// <summary>下载到 dir；已经下载过（不管在哪个文件夹）就直接返回那份，不重新下载</summary>
    public async Task<string> DownloadAsync(MediaItem item, string dir)
    {
        if (LocalCopy(item) is { } local) return local;
        var c = Client ?? throw new PhoneException(PhoneErrorKind.StreamEnded);
        var path = await c.DownloadAsync(item, dir);
        _downloads[DownloadKey(item)] = path;
        _settings.SetMap("downloads", _downloads);
        Raise("Downloads");
        return path;
    }

    // MARK: 删除

    /// <summary>把手机上的照片 / 视频移到「最近删除」。返回给界面显示的一句话</summary>
    public async Task<string> TrashAsync(IReadOnlyList<MediaItem> items)
    {
        if (Client is not { } c) return "手机未连接";
        try
        {
            var r = await c.TrashAsync(items);
            AppLog.Write($"删除手机上的 {items.Count} 项：已移走 {r.Trashed}，等待手机确认 {r.Pending}");
            if (!r.Pending)
                foreach (var g in items.GroupBy(i => i.Kind))
                    Library?.Remove(g.Select(i => i.Id).ToHashSet(), g.Key);
            await RefreshRecentAsync();
            return r.Pending ? "请在手机上确认删除" : "已移到手机的「最近删除」";
        }
        catch (Exception e)
        {
            return $"删除失败：{e.Message}";
        }
    }

    public string? CachedOriginal(MediaItem item)
    {
        if (LocalCopy(item) is { } local) return local;
        var path = Path.Combine(AppDirs.Caches, "originals", item.CacheKey, PhoneClient.SafeFileName(item.Name));
        return File.Exists(path) ? path : null;
    }

    /// <summary>原图的本地文件（以原文件名保存，复制成文件时名字也对）。下载过就用下载的那份，否则缓存一份</summary>
    public async Task<string> OriginalAsync(MediaItem item)
    {
        if (CachedOriginal(item) is { } local) return local;
        var c = Client ?? throw new PhoneException(PhoneErrorKind.StreamEnded);
        var dir = Path.Combine(AppDirs.Caches, "originals", item.CacheKey);
        var cached = Path.Combine(dir, PhoneClient.SafeFileName(item.Name));
        var tmp = await c.DownloadAsync(item, Path.Combine(AppDirs.Caches, "originals", "tmp"));
        Directory.CreateDirectory(dir);
        File.Move(tmp, cached, overwrite: true);
        return cached;
    }

    /// <summary>下载原图存到「文档\Colorlink」</summary>
    public async Task<bool> SaveToDownloadsAsync(MediaItem item)
    {
        try
        {
            var path = await DownloadAsync(item, AppDirs.Downloads);
            LastEvent = $"已存到 文档\\Colorlink：{Path.GetFileName(path)}";
            return true;
        }
        catch (Exception e)
        {
            LastEvent = $"下载失败：{e.Message}";
            return false;
        }
    }

    /// <summary>一张图片：放图片数据，哪里都能粘贴；多项：放文件，粘贴到资源管理器、微信等会是多个文件</summary>
    public async Task<bool> CopyToClipboardAsync(IReadOnlyList<MediaItem> items)
    {
        try
        {
            var paths = new List<string>();
            foreach (var item in items) paths.Add(await OriginalAsync(item));
            bool ok = paths.Count == 1 && items[0].Kind == MediaKind.Image ? await _platform.CopyImageAsync(paths[0]) : await _platform.CopyFilesAsync(paths);
            LastEvent = ok ? $"已复制 {(items.Count == 1 ? items[0].Name : $"{items.Count} 项")}" : "复制失败";
            return ok;
        }
        catch (Exception e)
        {
            LastEvent = $"下载失败：{e.Message}";
            return false;
        }
    }

    /// <summary>把拖进来的文件发给手机。文件夹会被跳过。</summary>
    public async Task SendAsync(IReadOnlyList<string> paths)
    {
        if (Client is not { } c)
        {
            Transfer = "手机未连接";
            await Task.Delay(1500);
            Transfer = null;
            return;
        }
        var files = paths.Where(File.Exists).ToList();
        if (files.Count == 0) return;
        int done = 0;
        var batch = Guid.NewGuid().ToString();
        for (int i = 0; i < files.Count; i++)
        {
            var name = Path.GetFileName(files[i]);
            Transfer = files.Count == 1 ? $"正在发送 {name}…" : $"正在发送 {i + 1}/{files.Count}…";
            try
            {
                await c.UploadAsync(files[i], batch: (batch, i, files.Count));
                done++;
            }
            catch (Exception e)
            {
                LastEvent = $"发送 {name} 失败：{e.Message}";
                AppLog.Write($"发送文件失败：{e.Message}");
            }
        }
        Transfer = done == files.Count ? "已发送到手机 ✓" : $"已发送 {done}/{files.Count}";
        AppLog.Write($"发送文件到手机：成功 {done}/{files.Count}");
        LastEvent = Transfer;
        await RefreshRecentAsync();
        await Task.Delay(1500);
        Transfer = null;
    }

    // MARK: 诊断日志

    /// <summary>诊断日志直接导出到「文档\Colorlink」，同批文件使用相同前缀。返回导出的文件</summary>
    public async Task<IReadOnlyList<string>> ExportDiagnosticsAsync()
    {
        var dir = AppDirs.Downloads;
        var prefix = $"诊断日志-{DateTime.Now:yyyyMMdd'T'HHmmss}-{Guid.NewGuid().ToString()[..8]}";
        Directory.CreateDirectory(dir);
        var summary = new List<string>
        {
            $"导出时间：{DateTimeOffset.Now}",
            $"Windows：{Environment.OSVersion.VersionString}",
            $"状态：{State} {StateDetail}",
            $"手机：{Device?.Name ?? "未配对"} {Client?.Endpoint}",
            $"手机信息：{(Info is { } i ? $"{i.Model} / Android {i.Android} / 电量 {i.Battery ?? -1}%" : "无")}",
            $"设置：截图自动复制={AutoCopyScreenshots} 同步通知={MirrorNotifications} 验证码自动复制={AutoCopyCodes}",
        };
        var files = new List<string>();
        if (Client is { } c)
        {
            try
            {
                var f = Path.Combine(dir, $"{prefix}-手机.log");
                await File.WriteAllTextAsync(f, await c.LogsAsync());
                files.Add(f);
                summary.Add("手机日志：已导出");
            }
            catch (Exception e)
            {
                summary.Add($"手机日志：获取失败（{e.Message}）");
            }
        }
        else
        {
            summary.Add("手机日志：手机未连接，没有导出");
        }
        var pc = Path.Combine(dir, $"{prefix}-电脑.log");
        await File.WriteAllTextAsync(pc, AppLog.Dump());
        var sum = Path.Combine(dir, $"{prefix}-概况.txt");
        await File.WriteAllLinesAsync(sum, summary);
        files.Add(pc);
        files.Add(sum);
        AppLog.Write("已导出诊断日志");
        _platform.Reveal(files);
        return files;
    }
}
