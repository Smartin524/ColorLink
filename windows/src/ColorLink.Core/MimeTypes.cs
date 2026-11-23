namespace ColorLink.Core;

/// <summary>按扩展名猜 MIME 类型。手机按它决定存进相册、音乐还是下载目录</summary>
public static class MimeTypes
{
    static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg", [".jfif"] = "image/jpeg", [".png"] = "image/png",
        [".gif"] = "image/gif", [".webp"] = "image/webp", [".heic"] = "image/heic", [".heif"] = "image/heif",
        [".bmp"] = "image/bmp", [".tif"] = "image/tiff", [".tiff"] = "image/tiff", [".avif"] = "image/avif",
        [".dng"] = "image/x-adobe-dng", [".svg"] = "image/svg+xml",
        [".mp4"] = "video/mp4", [".m4v"] = "video/x-m4v", [".mov"] = "video/quicktime", [".mkv"] = "video/x-matroska",
        [".webm"] = "video/webm", [".avi"] = "video/x-msvideo", [".wmv"] = "video/x-ms-wmv", [".3gp"] = "video/3gpp",
        [".mp3"] = "audio/mpeg", [".m4a"] = "audio/mp4", [".aac"] = "audio/aac", [".wav"] = "audio/wav",
        [".flac"] = "audio/flac", [".ogg"] = "audio/ogg", [".opus"] = "audio/opus", [".wma"] = "audio/x-ms-wma",
        [".amr"] = "audio/amr",
        [".pdf"] = "application/pdf", [".txt"] = "text/plain", [".zip"] = "application/zip",
        [".apk"] = "application/vnd.android.package-archive",
        [".doc"] = "application/msword",
        [".docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        [".xls"] = "application/vnd.ms-excel",
        [".xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        [".ppt"] = "application/vnd.ms-powerpoint",
        [".pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    };

    public static string For(string fileName) =>
        Map.TryGetValue(Path.GetExtension(fileName), out var m) ? m : "application/octet-stream";

    public static bool IsImage(string fileName) => For(fileName).StartsWith("image/");
}
