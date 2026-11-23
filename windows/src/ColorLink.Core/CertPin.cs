using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace ColorLink.Core;

/// <summary>
/// 手机的 HTTPS 证书是它自己签的，系统不认。这里不看证书链和主机名，只比对证书（DER）的 SHA-256 指纹：
/// 配对时（还没有指纹）谁都接受，记下看到的指纹，和令牌一起存起来；之后只接受这一张，对不上就在握手阶段断开，令牌不会发出去。
/// </summary>
public sealed class CertPin(string? expected)
{
    readonly Lock _lock = new();
    string? _seen;
    bool _mismatch;

    public string? Expected { get; } = expected;

    /// <summary>最近一次握手看到的证书指纹</summary>
    public string? Seen { get { lock (_lock) return _seen; } }

    /// <summary>是否遇到过对不上的证书（同一地址上换了设备，或有人冒充）</summary>
    public bool Mismatch { get { lock (_lock) return _mismatch; } }

    public bool Validate(object? sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors errors)
    {
        if (certificate is null) return false;
        var fp = Fingerprint(certificate.GetRawCertData());
        bool ok = Expected is null || string.Equals(Expected, fp, StringComparison.OrdinalIgnoreCase);
        lock (_lock)
        {
            _seen = fp;
            if (!ok) _mismatch = true;
        }
        return ok;
    }

    public static string Fingerprint(byte[] der) => Convert.ToHexStringLower(SHA256.HashData(der));
}
