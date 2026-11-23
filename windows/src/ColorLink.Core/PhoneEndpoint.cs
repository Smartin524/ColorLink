namespace ColorLink.Core;

public sealed record PhoneEndpoint(string Host, int Port)
{
    public const int DefaultPort = 8765;

    /// <summary>接受 <c>192.168.1.5</c>、<c>192.168.1.5:8765</c>、<c>localhost:8765</c>。</summary>
    public static PhoneEndpoint Parse(string text, int defaultPort = DefaultPort)
    {
        var s = text.Trim();
        if (s.Length == 0) throw new PhoneException(PhoneErrorKind.BadAddress, text);
        if (!s.Contains(']') && s.Count(c => c == ':') == 1)
        {
            int i = s.LastIndexOf(':');
            if (!int.TryParse(s[(i + 1)..], out int p) || p is <= 0 or > 65535)
                throw new PhoneException(PhoneErrorKind.BadAddress, text);
            return new PhoneEndpoint(s[..i], p);
        }
        return new PhoneEndpoint(s.Trim('[', ']'), defaultPort);
    }

    public Uri BaseUri => new($"https://{(Host.Contains(':') ? $"[{Host}]" : Host)}:{Port}/");

    public override string ToString() => $"{Host}:{Port}";
}
