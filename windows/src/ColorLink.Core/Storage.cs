using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ColorLink.Core;

public sealed record PairedPhone
{
    public required string DeviceId { get; init; }
    public required string Name { get; init; }
    public required string Token { get; init; }
    public PhoneEndpoint? LastEndpoint { get; init; }
    /// <summary>手机 HTTPS 证书的 SHA-256 指纹（见 CertPin）。升级前配的对没有，第一次连上时补记</summary>
    public string? CertSha256 { get; init; }
}

public static class AppDirs
{
    /// <summary>可以覆盖（clcheck、测试用），默认 %LOCALAPPDATA%\ColorLink</summary>
    public static string Root { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ColorLink");

    public static string Caches => Path.Combine(Root, "Cache");
    public static string Logs => Path.Combine(Root, "Logs");

    /// <summary>这台手机在本机长期保存的数据（相册列表、缩略图）</summary>
    public static string Library(string deviceId) => Path.Combine(Root, "Phones", PhoneClient.SafeFileName(deviceId));

    /// <summary>用户保存的照片、截图和接收文件直接放在「文档\Colorlink」。可以覆盖（调试用）</summary>
    public static string Downloads { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Colorlink");

    public static void WriteAtomic(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, overwrite: true);
    }
}

/// <summary>
/// 已配对的手机，存在 %LOCALAPPDATA%\ColorLink\paired.json。
/// 令牌用 Windows DPAPI（当前用户）加密后再落盘，别的账户和拷走文件都解不开。
/// </summary>
public static class PairedStore
{
    static readonly Lock Gate = new();
    static string FilePath => Path.Combine(AppDirs.Root, "paired.json");

    sealed record Stored(string DeviceId, string Name, string Token, bool Protected, PhoneEndpoint? LastEndpoint, string? CertSha256);

    public static IReadOnlyList<PairedPhone> All()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return [];
                var list = JsonSerializer.Deserialize<List<Stored>>(File.ReadAllBytes(FilePath), Json.Options) ?? [];
                return list.Select(s => new PairedPhone
                {
                    DeviceId = s.DeviceId, Name = s.Name, Token = s.Protected ? Unprotect(s.Token) : s.Token,
                    LastEndpoint = s.LastEndpoint, CertSha256 = s.CertSha256,
                }).Where(p => p.Token.Length > 0).ToList();
            }
            catch (Exception e)
            {
                AppLog.Write($"读取配对信息失败：{e.Message}");
                return [];
            }
        }
    }

    public static void Save(PairedPhone phone)
    {
        lock (Gate)
        {
            var list = All().Where(p => p.DeviceId != phone.DeviceId).Prepend(phone);
            Write(list);
        }
    }

    public static void Remove(string deviceId)
    {
        lock (Gate) Write(All().Where(p => p.DeviceId != deviceId));
    }

    static void Write(IEnumerable<PairedPhone> list)
    {
        bool canProtect = OperatingSystem.IsWindows();
        var stored = list.Select(p => new Stored(p.DeviceId, p.Name, canProtect ? Protect(p.Token) : p.Token, canProtect, p.LastEndpoint, p.CertSha256));
        AppDirs.WriteAtomic(FilePath, JsonSerializer.SerializeToUtf8Bytes(stored.ToList(), Json.Options));
    }

    static string Protect(string s)
    {
        if (!OperatingSystem.IsWindows()) return s;
        return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(s), null, DataProtectionScope.CurrentUser));
    }

    static string Unprotect(string s)
    {
        if (!OperatingSystem.IsWindows()) return "";
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(s), null, DataProtectionScope.CurrentUser)); }
        catch { return ""; }
    }
}

/// <summary>简单的设置存储：%LOCALAPPDATA%\ColorLink\settings.json</summary>
public sealed class Settings
{
    public static Settings Shared { get; } = new();

    readonly Lock _gate = new();
    JsonObject _data;
    string FilePath => Path.Combine(AppDirs.Root, "settings.json");

    Settings()
    {
        try { _data = File.Exists(FilePath) ? JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject ?? [] : []; }
        catch { _data = []; }
    }

    public bool GetBool(string key, bool fallback)
    {
        lock (_gate) return _data[key]?.GetValue<bool>() ?? fallback;
    }

    public void SetBool(string key, bool value)
    {
        lock (_gate)
        {
            _data[key] = value;
            Save();
        }
    }

    public Dictionary<string, string> GetMap(string key)
    {
        lock (_gate)
            return _data[key] is JsonObject o
                ? o.Where(p => p.Value is not null).ToDictionary(p => p.Key, p => p.Value!.GetValue<string>())
                : [];
    }

    public void SetMap(string key, IReadOnlyDictionary<string, string> map)
    {
        lock (_gate)
        {
            var o = new JsonObject();
            foreach (var (k, v) in map) o[k] = v;
            _data[key] = o;
            Save();
        }
    }

    void Save() => AppDirs.WriteAtomic(FilePath, Encoding.UTF8.GetBytes(_data.ToJsonString(new JsonSerializerOptions { WriteIndented = true })));
}

/// <summary>缩略图两级缓存：内存 + 磁盘。同一张图同时被请求多次时只发一次网络请求。</summary>
public sealed class ThumbnailCache
{
    readonly string _dir;
    readonly ConcurrentDictionary<string, byte[]> _memory = new();
    readonly ConcurrentQueue<string> _order = new();
    readonly ConcurrentDictionary<string, Lazy<Task<byte[]?>>> _inflight = new();
    const int MemoryLimit = 2000;

    public string DeviceId { get; }

    public ThumbnailCache(string deviceId)
    {
        DeviceId = deviceId;
        _dir = Path.Combine(AppDirs.Library(deviceId), "thumbs");
        Directory.CreateDirectory(_dir);
    }

    string FileFor(MediaItem item) => Path.Combine(_dir, item.CacheKey + ".jpg");

    /// <summary>只读本机保存的（手机没连上时用）</summary>
    public byte[]? Stored(MediaItem item)
    {
        if (_memory.TryGetValue(item.CacheKey, out var d)) return d;
        try { return File.Exists(FileFor(item)) ? File.ReadAllBytes(FileFor(item)) : null; } catch { return null; }
    }

    public string? StoredPath(MediaItem item) => File.Exists(FileFor(item)) ? FileFor(item) : null;

    /// <summary>本机是否已经存了这张缩略图</summary>
    public bool Has(MediaItem item) => File.Exists(FileFor(item));

    /// <summary>后台补齐用：只存到磁盘，不占内存缓存。返回是否成功</summary>
    public async Task<bool> PrefetchAsync(MediaItem item, PhoneClient client, CancellationToken ct = default)
    {
        var file = FileFor(item);
        if (File.Exists(file)) return true;
        try
        {
            AppDirs.WriteAtomic(file, await client.ThumbnailAsync(item, ct: ct));
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task<byte[]?> DataAsync(MediaItem item, PhoneClient? client, CancellationToken ct = default)
    {
        var key = item.CacheKey;
        if (_memory.TryGetValue(key, out var hit)) return hit;
        var lazy = _inflight.GetOrAdd(key, _ => new Lazy<Task<byte[]?>>(() => Task.Run(async () =>
        {
            var file = FileFor(item);
            try
            {
                if (File.Exists(file)) return await File.ReadAllBytesAsync(file);
                if (client is null) return null;
                var d = await client.ThumbnailAsync(item);
                AppDirs.WriteAtomic(file, d);
                return d;
            }
            catch
            {
                return null;
            }
        })));
        try
        {
            var d = await lazy.Value.WaitAsync(ct);
            if (d is not null && _memory.TryAdd(key, d))
            {
                _order.Enqueue(key);
                while (_memory.Count > MemoryLimit && _order.TryDequeue(out var old)) _memory.TryRemove(old, out _);
            }
            return d;
        }
        finally
        {
            if (lazy.Value.IsCompleted) _inflight.TryRemove(key, out _);
        }
    }

    public void ClearDisk()
    {
        try { Directory.Delete(_dir, true); } catch { /* 没有就算了 */ }
        Directory.CreateDirectory(_dir);
        _memory.Clear();
    }
}

/// <summary>
/// 日志：写 %LOCALAPPDATA%\ColorLink\Logs\colorlink.log（超过 1 MB 轮换，最多占 2 MB）。
/// 「导出诊断日志」会把它和手机日志一起导出。不记通知内容和验证码。
/// </summary>
public static class AppLog
{
    static readonly Lock Gate = new();
    static string FilePath => Path.Combine(AppDirs.Logs, "colorlink.log");
    public static bool Console { get; set; }

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}";
        if (Console) System.Console.Write("  · " + line);
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(AppDirs.Logs);
                var fi = new FileInfo(FilePath);
                if (fi.Exists && fi.Length > 1 << 20)
                    File.Move(FilePath, Path.Combine(AppDirs.Logs, "colorlink.1.log"), overwrite: true);
                File.AppendAllText(FilePath, line, Encoding.UTF8);
            }
            catch
            {
                // 日志写不了不影响功能
            }
        }
    }

    /// <summary>旧的在前、新的在后</summary>
    public static string Dump()
    {
        lock (Gate)
            return string.Concat(new[] { "colorlink.1.log", "colorlink.log" }
                .Select(n => Path.Combine(AppDirs.Logs, n))
                .Where(File.Exists)
                .Select(File.ReadAllText));
    }
}
