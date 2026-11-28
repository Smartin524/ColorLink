using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Zeroconf;

namespace ColorLink.Core;

public sealed record DiscoveredPhone(string Name, string? DeviceId, PhoneEndpoint Endpoint);

/// <summary>
/// 持续寻找局域网里的 <c>_colorlink._tcp</c> 服务（mDNS / DNS-SD）。
/// Windows 上没有 Bonjour 那样的常驻浏览，这里定时发查询：没找到时 4 秒一次，找到了就放慢到 20 秒一次。
/// 手机换网络、醒来时会主动敲门，不靠这里抢时间。
/// </summary>
public sealed class PhoneBrowser : IDisposable
{
    public const string ServiceType = "_colorlink._tcp.local.";

    /// <summary>发现的手机有变化时回调（后台线程）</summary>
    public Action<IReadOnlyList<DiscoveredPhone>>? OnChange { get; set; }

    CancellationTokenSource? _cts;
    IReadOnlyList<DiscoveredPhone> _last = [];
    readonly SemaphoreSlim _kick = new(0);

    public IReadOnlyList<DiscoveredPhone> Current => _last;

    public void Start()
    {
        if (_cts is not null) return;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                IReadOnlyList<DiscoveredPhone> phones;
                try
                {
                    phones = await BrowseOnceAsync(TimeSpan.FromSeconds(2), ct);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception e)
                {
                    AppLog.Write($"mDNS 查询失败：{e.Message}");
                    phones = _last;
                }
                if (!phones.SequenceEqual(_last))
                {
                    _last = phones;
                    OnChange?.Invoke(phones);
                }
                // 网络变化时提前再查一次
                try { await _kick.WaitAsync(TimeSpan.FromSeconds(phones.Count == 0 ? 4 : 20), ct); } catch { return; }
            }
        }, ct);
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
    }

    void OnNetworkChanged(object? sender, EventArgs e) => Refresh();

    /// <summary>立即再查一次（网络变化、唤醒时）</summary>
    public void Refresh()
    {
        if (_kick.CurrentCount == 0) _kick.Release();
    }

    public void Stop()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        _cts?.Cancel();
        _cts = null;
    }

    public void Dispose() => Stop();

    public static async Task<IReadOnlyList<DiscoveredPhone>> BrowseOnceAsync(TimeSpan scanTime, CancellationToken ct = default)
    {
        var hosts = await ZeroconfResolver.ResolveAsync(ServiceType, scanTime, cancellationToken: ct);
        var list = new List<DiscoveredPhone>();
        foreach (var h in hosts)
        {
            // 避开 IPv6 链路本地地址：优先 IPv4
            var ip = h.IPAddresses.FirstOrDefault(a => IPAddress.TryParse(a, out var x) && x.AddressFamily == AddressFamily.InterNetwork)
                     ?? h.IPAddress;
            if (string.IsNullOrEmpty(ip)) continue;
            foreach (var (key, svc) in h.Services)
            {
                if (!key.Contains("_colorlink._tcp", StringComparison.OrdinalIgnoreCase)) continue;
                string? id = null, txtName = null;
                foreach (var props in svc.Properties)
                {
                    if (props.TryGetValue("id", out var v)) id = v;
                    if (props.TryGetValue("name", out var n)) txtName = n;
                }
                // 实例名（Bonjour 里显示的那个）在 DisplayName；万一是空的就用 TXT 里的机型
                var name = !string.IsNullOrWhiteSpace(h.DisplayName) && !h.DisplayName.StartsWith('_') ? h.DisplayName : txtName ?? ip;
                int dot = name.IndexOf("._colorlink", StringComparison.OrdinalIgnoreCase);
                if (dot > 0) name = name[..dot];
                list.Add(new DiscoveredPhone(name, id, new PhoneEndpoint(ip, svc.Port)));
            }
        }
        return list.OrderBy(p => p.Name, StringComparer.Ordinal).ThenBy(p => p.Endpoint.Host).DistinctBy(p => p.DeviceId ?? p.Endpoint.ToString()).ToList();
    }

    /// <summary>这台电脑当前的默认网关。连着手机热点时，网关就是手机本身。</summary>
    public static IReadOnlyList<string> DefaultGateways() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().GatewayAddresses)
            .Select(g => g.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(IPAddress.Any))
            .Select(a => a.ToString())
            .Distinct()
            .ToList();
}

/// <summary>看手机上 ColorLink 的端口：通了、被拒绝（手机在线但 ColorLink 没在运行），还是根本连不到。</summary>
public static class PortProbe
{
    public enum Result { Open, Refused, Unreachable }

    public static async Task<Result> CheckAsync(string host, int port, TimeSpan? timeout = null)
    {
        using var cts = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(3));
        using var tcp = new TcpClient();
        try
        {
            await tcp.ConnectAsync(host, port, cts.Token);
            return Result.Open;
        }
        catch (SocketException e) when (e.SocketErrorCode == SocketError.ConnectionRefused)
        {
            return Result.Refused;
        }
        catch
        {
            return Result.Unreachable;
        }
    }
}
