using System.Text.Json;

namespace ColorLink.Core;

/// <summary>
/// 手机相册在本机的完整副本（每种类型一份列表，存在「%LOCALAPPDATA%\ColorLink\Phones\手机 ID\lists」）。
///
/// 打开相册直接显示本地这份，再和手机核对。旧照片基本不会变，所以核对时只取最新的一页：
/// 媒体库「代数」没变：什么都不做；只多了新照片：取到和本地第一项接上为止，把新的接到前面；
/// 有删除或别的变化（总数对不上）：在后台把整个列表重新拉一遍。
/// </summary>
public sealed class MediaLibrary
{
    public sealed record Snapshot(int? MetadataVersion, long? Generation, int Total, List<MediaItem> Items, bool Complete);

    public string DeviceId { get; }
    readonly Lock _gate = new();
    readonly Dictionary<MediaKind, Snapshot> _lists = [];
    readonly Dictionary<MediaKind, Task> _running = [];

    /// <summary>某个类型的列表变了（后台线程）</summary>
    public event Action<MediaKind>? Changed;

    public MediaLibrary(string deviceId)
    {
        DeviceId = deviceId;
        foreach (var kind in Enum.GetValues<MediaKind>())
        {
            try
            {
                if (File.Exists(FileFor(kind)) && JsonSerializer.Deserialize<Snapshot>(File.ReadAllBytes(FileFor(kind)), Json.Options) is { } s)
                    _lists[kind] = s;
            }
            catch
            {
                // 坏了就当没有，下次同步重新拉
            }
        }
    }

    string FileFor(MediaKind kind) => Path.Combine(AppDirs.Library(DeviceId), "lists", $"{kind.Wire()}.json");

    public Snapshot? this[MediaKind kind] { get { lock (_gate) return _lists.GetValueOrDefault(kind); } }

    public bool IsSyncing(MediaKind kind) { lock (_gate) return _running.ContainsKey(kind); }

    /// <summary>和手机核对一次；同一类型同时只跑一个，后来的等它跑完</summary>
    public Task SyncAsync(MediaKind kind, PhoneClient client, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_running.TryGetValue(kind, out var t)) return t;
            t = Task.Run(async () =>
            {
                try { await DoSync(kind, client, ct); }
                finally
                {
                    lock (_gate) _running.Remove(kind);
                    Changed?.Invoke(kind);
                }
            }, ct);
            _running[kind] = t;
            return t;
        }
    }

    /// <summary>在电脑上删掉（移到手机的「最近删除」）后，本地列表同步去掉</summary>
    public void Remove(IReadOnlySet<long> ids, MediaKind kind)
    {
        Snapshot? snap = this[kind];
        if (snap is null) return;
        var items = snap.Items.Where(i => !ids.Contains(i.Id)).ToList();
        Set(kind, snap with { Items = items, Total = snap.Total - (snap.Items.Count - items.Count) });
    }

    async Task DoSync(MediaKind kind, PhoneClient c, CancellationToken ct)
    {
        try
        {
            var first = await c.MediaAsync(kind, 0, 200, ct);
            var cached = this[kind];
            if (cached is { Complete: true } && cached.MetadataVersion == first.MetadataVersion && cached.Total == first.Total)
            {
                bool sameGeneration = first.Generation is not null && first.Generation == cached.Generation;
                // 旧版手机没有代数：第一页完全一样就当没变
                bool sameHead = first.Generation is null && cached.Items.Take(first.Items.Count).SequenceEqual(first.Items);
                if (sameGeneration || sameHead) return;
            }
            if (cached is { Complete: true } && cached.MetadataVersion == first.MetadataVersion
                && await MergeHead(kind, first, cached, c, ct) is { } merged)
            {
                int added = merged.Count - cached.Items.Count;
                Set(kind, new Snapshot(first.MetadataVersion, first.Generation, first.Total, merged, true));
                if (added > 0) AppLog.Write($"{kind.Title()}列表：新增 {added} 项");
                return;
            }
            await FullSync(kind, first, c, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            AppLog.Write($"同步{kind.Title()}列表失败：{e.Message}");
        }
    }

    /// <summary>
    /// 只多了新照片时：往后取到和本地第一项接上为止（最多 2500 项），把新的接到前面。
    /// 接不上、接上的部分对不上、或总数不符，返回 null 交给完整同步
    /// </summary>
    static async Task<List<MediaItem>?> MergeHead(MediaKind kind, MediaPage first, Snapshot cached, PhoneClient c, CancellationToken ct)
    {
        if (cached.Items.Count == 0) return null;
        var anchor = cached.Items[0];
        var head = new List<MediaItem>(first.Items);
        while (!head.Any(i => i.Id == anchor.Id))
        {
            if (head.Count >= first.Total || head.Count >= 2500) return null;
            MediaPage page;
            try { page = await c.MediaAsync(kind, head.Count, 500, ct); } catch { return null; }
            if (page.Items.Count == 0) return null;
            head.AddRange(page.Items);
        }
        int idx = head.FindIndex(i => i.Id == anchor.Id);
        var overlap = head.Skip(idx).ToList();
        if (!cached.Items.Take(overlap.Count).SequenceEqual(overlap)) return null;
        var merged = head.Take(idx).Concat(cached.Items).ToList();
        return merged.Count == first.Total ? merged : null;
    }

    /// <summary>整个列表重新拉一遍。第一次同步时边拉边显示</summary>
    async Task FullSync(MediaKind kind, MediaPage first, PhoneClient c, CancellationToken ct)
    {
        bool progressive = this[kind]?.Complete != true;
        var items = new List<MediaItem>(first.Items);
        if (progressive) Set(kind, new Snapshot(first.MetadataVersion, null, first.Total, [.. items], false), save: false);
        while (items.Count < first.Total)
        {
            var page = await c.MediaAsync(kind, items.Count, 500, ct);
            if (page.Items.Count == 0) break;
            items.AddRange(page.Items);
            if (progressive) Set(kind, new Snapshot(first.MetadataVersion, null, first.Total, [.. items], false), save: false);
        }
        // 拉的过程中手机上新增了照片，分页会错位出重复，按 ID 去重
        var seen = new HashSet<long>();
        items = items.Where(i => seen.Add(i.Id)).ToList();
        Set(kind, new Snapshot(first.MetadataVersion, first.Generation, items.Count, items, true));
        AppLog.Write($"{kind.Title()}列表完整同步：{items.Count} 项");
    }

    void Set(MediaKind kind, Snapshot snap, bool save = true)
    {
        lock (_gate) _lists[kind] = snap;
        Changed?.Invoke(kind);
        if (!save) return;
        var file = FileFor(kind);
        _ = Task.Run(() =>
        {
            try { AppDirs.WriteAtomic(file, JsonSerializer.SerializeToUtf8Bytes(snap, Json.Options)); }
            catch (Exception e) { AppLog.Write($"保存{kind.Title()}列表失败：{e.Message}"); }
        });
    }
}
