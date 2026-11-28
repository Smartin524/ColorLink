using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ColorLink.Core;

public sealed record Knock(string DeviceId, PhoneEndpoint Endpoint);

/// <summary>
/// 接收手机的“敲门”UDP 包：手机醒来或换网络时发来，收到就立刻去连，不用等重试计时。
///
/// 包内容 <c>{"v":1,"id","port","ts","sig"}</c>，sig = HMAC-SHA256(令牌, "id|port|ts")。
/// 只信任签名正确、时间在 5 分钟以内的包；IP 取 UDP 包的来源地址，不信任包里写的。
/// </summary>
public sealed class KnockListener : IDisposable
{
    public const int Port = 8766;

    /// <summary>根据设备 ID 查配对令牌（在后台线程上调用）</summary>
    public Func<string, string?>? TokenFor { get; set; }
    /// <summary>验证通过后回调（在后台线程上调用）</summary>
    public Action<Knock>? OnKnock { get; set; }

    readonly CancellationTokenSource _cts = new();

    public void Start() => _ = Task.Run(LoopAsync);

    async Task LoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                using var udp = new UdpClient(AddressFamily.InterNetwork);
                udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, Port));
                AppLog.Write($"敲门监听已开：UDP {Port}");
                while (!_cts.IsCancellationRequested)
                {
                    var r = await udp.ReceiveAsync(_cts.Token);
                    if (Verify(r.Buffer, r.RemoteEndPoint.Address.ToString(), TokenFor ?? (_ => null)) is { } knock)
                        OnKnock?.Invoke(knock);
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception e)
            {
                AppLog.Write($"敲门监听出错，5 秒后重开：{e.Message}");
                try { await Task.Delay(5000, _cts.Token); } catch { return; }
            }
        }
    }

    public static Knock? Verify(byte[] data, string fromHost, Func<string, string?> tokenFor, DateTimeOffset? now = null)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var r = doc.RootElement;
            if (r.GetProperty("v").GetInt32() != 1) return null;
            var id = r.GetProperty("id").GetString() ?? "";
            int port = r.GetProperty("port").GetInt32();
            long ts = r.GetProperty("ts").GetInt64();
            var sig = r.GetProperty("sig").GetString() ?? "";
            if (Math.Abs((now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds() - ts) >= 300) return null;
            if (tokenFor(id) is not { } token) return null;
            var expected = Sign(token, $"{id}|{port}|{ts}");
            if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(expected), Encoding.ASCII.GetBytes(sig.ToLowerInvariant())))
                return null;
            // IPv4 映射的 IPv6 地址（::ffff:1.2.3.4）还原成 IPv4；去掉网卡后缀
            var host = fromHost.StartsWith("::ffff:") ? fromHost[7..] : fromHost.Split('%')[0];
            return new Knock(id, new PhoneEndpoint(host, port));
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    public static string Sign(string token, string message) =>
        Convert.ToHexStringLower(HMACSHA256.HashData(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes(message)));

    public void Dispose() => _cts.Cancel();
}
