using System.Text.Json;
using System.Text.Json.Serialization;

namespace ColorLink.Core;

[JsonConverter(typeof(JsonStringEnumConverter<MediaKind>))]
public enum MediaKind
{
    [JsonStringEnumMemberName("image")] Image,
    [JsonStringEnumMemberName("video")] Video,
    [JsonStringEnumMemberName("audio")] Audio,
}

public static class MediaKindExtensions
{
    public static string Wire(this MediaKind k) => k switch
    {
        MediaKind.Image => "image",
        MediaKind.Video => "video",
        _ => "audio",
    };

    public static string Title(this MediaKind k) => k switch
    {
        MediaKind.Image => "照片",
        MediaKind.Video => "视频",
        _ => "音频",
    };
}

public sealed record MediaItem
{
    public long Id { get; init; }
    public MediaKind Kind { get; init; }
    public string Name { get; init; } = "";
    public string Mime { get; init; } = "application/octet-stream";
    public long Size { get; init; }
    /// <summary>修改时间（秒）。和 id 一起唯一确定一张缩略图。</summary>
    public long Modified { get; init; }
    /// <summary>加入手机媒体库的时间（秒），用于增量同步，不代表拍摄日期。</summary>
    public long? Added { get; init; }
    /// <summary>原始拍摄时间（秒），来自手机的图片 / 视频元数据。</summary>
    public long? Taken { get; init; }
    public int? Width { get; init; }
    public int? Height { get; init; }
    /// <summary>毫秒</summary>
    public long? Duration { get; init; }
    public string? Path { get; init; }

    [JsonIgnore] public string CacheKey => $"{Kind.Wire()}_{Id}_{Modified}";

    [JsonIgnore]
    public DateTimeOffset CapturedDate
    {
        get
        {
            long ts = new[] { Taken, Modified, Added }.FirstOrDefault(v => v is > 0) ?? 0;
            return DateTimeOffset.FromUnixTimeSeconds(ts);
        }
    }
}

public sealed record MediaPage
{
    /// <summary>协议元数据变化也需要刷新旧列表，即使手机媒体库代数没有改变。</summary>
    public int? MetadataVersion { get; init; }
    public int Total { get; init; }
    /// <summary>手机媒体库的「代数」：有任何增删改就会变（旧版手机 / 模拟手机没有）</summary>
    public long? Generation { get; init; }
    public List<MediaItem> Items { get; init; } = [];
}

public sealed record PairResult(string Token, string DeviceId, string Name);

public sealed class DeviceInfo
{
    public string DeviceId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Model { get; set; } = "";
    public string Android { get; set; } = "";
    /// <summary>电量和充电状态随手机的 power 事件更新</summary>
    public int? Battery { get; set; }
    public bool? Charging { get; set; }
    /// <summary>免打扰档位；null 表示手机没开通知使用权，改不了</summary>
    public string? Dnd { get; set; }
}

/// <summary>手机的免打扰档位，和安卓的中断过滤一一对应</summary>
[JsonConverter(typeof(JsonStringEnumConverter<DndMode>))]
public enum DndMode
{
    [JsonStringEnumMemberName("all")] All,
    [JsonStringEnumMemberName("priority")] Priority,
    [JsonStringEnumMemberName("alarms")] Alarms,
    /// <summary>协议里叫 none</summary>
    [JsonStringEnumMemberName("none")] Silent,
}

public static class DndModeExtensions
{
    public static string Wire(this DndMode m) => m switch
    {
        DndMode.All => "all",
        DndMode.Priority => "priority",
        DndMode.Alarms => "alarms",
        _ => "none",
    };

    public static DndMode? Parse(string? s) => s switch
    {
        "all" => DndMode.All,
        "priority" => DndMode.Priority,
        "alarms" => DndMode.Alarms,
        "none" => DndMode.Silent,
        _ => null,
    };

    public static string Title(this DndMode m) => m switch
    {
        DndMode.All => "关",
        DndMode.Priority => "仅优先",
        DndMode.Alarms => "仅闹钟",
        _ => "完全静音",
    };

    /// <summary>是否算“开着免打扰”</summary>
    public static bool IsOn(this DndMode m) => m != DndMode.All;
}

public sealed record PhoneNotification
{
    public string Key { get; init; } = "";
    public string Pkg { get; init; } = "";
    public string App { get; init; } = "";
    /// <summary>来自短信 App；只在短信里找验证码（旧版手机不带这个字段，按短信处理）</summary>
    public bool? Sms { get; init; }
    public string Title { get; init; } = "";
    public string Text { get; init; } = "";
    public long Time { get; init; }
}

/// <summary>手机分享过来、等电脑去取的文件（GET /api/shared?id=）</summary>
public sealed record SharedFile(string Id, string Name, string Mime, long Size);

public abstract record PhoneEvent
{
    public sealed record Hello(DeviceInfo Info) : PhoneEvent;
    public sealed record Screenshot(MediaItem Item) : PhoneEvent;
    /// <summary>手机上多了一张新照片（不是截图）</summary>
    public sealed record Media(MediaItem Item) : PhoneEvent;
    public sealed record Notification(PhoneNotification Value) : PhoneEvent;
    public sealed record Clipboard(string Text) : PhoneEvent;
    /// <summary>手机上从分享菜单「发送到电脑」的文件</summary>
    public sealed record Shared(IReadOnlyList<SharedFile> Files) : PhoneEvent;
    /// <summary>手机插上 / 拔掉电源。后台补缩略图只在充电时做</summary>
    public sealed record Power(bool Charging, int? Battery) : PhoneEvent;
    /// <summary>免打扰档位变了</summary>
    public sealed record Dnd(DndMode Mode) : PhoneEvent;
    public sealed record Unknown(string Name) : PhoneEvent;
}

public enum PhoneErrorKind { Http, Unauthorized, BadPairingCode, BadAddress, StreamEnded, Timeout, CertMismatch }

public sealed class PhoneException(PhoneErrorKind kind, string? detail = null, int status = 0, Exception? inner = null)
    : Exception(Describe(kind, detail, status), inner)
{
    public PhoneErrorKind Kind { get; } = kind;
    public int Status { get; } = status;

    static string Describe(PhoneErrorKind kind, string? detail, int status) => kind switch
    {
        PhoneErrorKind.Http => $"手机返回错误 {status}",
        PhoneErrorKind.Unauthorized => "配对已失效，请重新配对",
        PhoneErrorKind.BadPairingCode => "配对码不对",
        PhoneErrorKind.BadAddress => $"地址格式不对：{detail}",
        PhoneErrorKind.StreamEnded => "连接被手机关闭",
        PhoneErrorKind.Timeout => "连接超时",
        PhoneErrorKind.CertMismatch => "手机证书变了，请重新配对",
        _ => detail ?? kind.ToString(),
    };
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public static T? Parse<T>(byte[] data) => JsonSerializer.Deserialize<T>(data, Options);
    public static T? Parse<T>(string data) => JsonSerializer.Deserialize<T>(data, Options);
    public static string Write<T>(T value) => JsonSerializer.Serialize(value, Options);
}
