// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NetFluss.Core;

/// <summary>Bytes in each direction. Port of the macOS <c>StatisticsTrafficAmounts</c>.</summary>
public sealed class TrafficAmounts
{
    public ulong DownloadBytes { get; set; }

    public ulong UploadBytes { get; set; }

    [JsonIgnore]
    public ulong TotalBytes => DownloadBytes + UploadBytes;

    public void Add(ulong download, ulong upload)
    {
        DownloadBytes += download;
        UploadBytes += upload;
    }

    public void Merge(TrafficAmounts other) => Add(other.DownloadBytes, other.UploadBytes);

    public TrafficAmounts Copy() => new() { DownloadBytes = DownloadBytes, UploadBytes = UploadBytes };
}

/// <summary>Since midnight and since the 1st — the popover's Data Usage block.</summary>
public sealed record UsageSummary(TrafficAmounts Today, TrafficAmounts Month)
{
    public static UsageSummary Empty => new(new TrafficAmounts(), new TrafficAmounts());
}

/// <summary>
/// The on-disk history. Field names match the macOS <c>StatisticsArchive</c> so the two
/// platforms' files stay diffable; <see cref="AdapterTunnels"/> is the one Windows addition.
/// </summary>
public sealed class StatisticsArchive
{
    public const int CurrentAppTrafficSchemaVersion = 3;

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;

    public DateTimeOffset? LastAdapterSampleAt { get; set; }

    public DateTimeOffset? LastAppSampleAt { get; set; }

    public int AppTrafficSchemaVersion { get; set; } = CurrentAppTrafficSchemaVersion;

    public Dictionary<string, string> AdapterDisplayNames { get; set; } = [];

    /// <summary>
    /// Adapters that were tunnels when recorded. macOS reads this from the BSD name ("utun3")
    /// at report time; a Windows interface GUID says nothing about what it is, so the
    /// classification is stored with the history it applies to.
    /// </summary>
    public List<string> AdapterTunnels { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> AdapterMinute { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> AdapterHourly { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> AdapterDaily { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> AppMinute { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> AppHourly { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> AppDaily { get; set; } = [];

    /// <summary>
    /// Per-proxy-node traffic from the Clash API (macOS 2.7). Absent from archives written
    /// before, which is why these default to empty rather than failing the load.
    /// </summary>
    public DateTimeOffset? LastNodeSampleAt { get; set; }

    public Dictionary<string, Dictionary<string, TrafficAmounts>> NodeMinute { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> NodeHourly { get; set; } = [];

    public Dictionary<string, Dictionary<string, TrafficAmounts>> NodeDaily { get; set; } = [];
}

public readonly record struct AdapterDelta(string Id, string DisplayName, bool IsTunnel, ulong DownloadBytes, ulong UploadBytes);

public readonly record struct AppDelta(string Name, ulong DownloadBytes, ulong UploadBytes);

/// <summary>The preset ranges of the Statistics window — macOS raw values.</summary>
public enum StatisticsRange
{
    LastHour,
    Last24Hours,
    Last7Days,
    Last30Days,
    LastYear,
}

public enum TimelineGranularity
{
    Minute,
    Hour,
    Day,
    Month,
}

public sealed record TimelinePoint(string Id, DateTime Date, ulong DownloadBytes, ulong UploadBytes);

public sealed record AdapterRow(string Id, string Name, ulong DownloadBytes, ulong UploadBytes)
{
    public ulong TotalBytes => DownloadBytes + UploadBytes;
}

public sealed record AppRow(string Name, ulong Bytes);

/// <summary>
/// A proxy node's totals for the range: sent and received side by side, because a quota
/// reader wants both, not two separate top-ten lists.
/// </summary>
public sealed record NodeRow(string Name, ulong DownloadBytes, ulong UploadBytes)
{
    public ulong TotalBytes => DownloadBytes + UploadBytes;
}

public sealed record StatisticsReport
{
    public required string Title { get; init; }

    public required string BucketTitle { get; init; }

    public required TimelineGranularity Granularity { get; init; }

    public required DateTime TimelineStart { get; init; }

    public required DateTime TimelineEnd { get; init; }

    public DateTime? CoverageStart { get; init; }

    public DateTimeOffset? LastAdapterSampleAt { get; init; }

    public DateTimeOffset? LastAppSampleAt { get; init; }

    public ulong TotalDownloadBytes { get; init; }

    public ulong TotalUploadBytes { get; init; }

    public IReadOnlyList<TimelinePoint> Timeline { get; init; } = [];

    public IReadOnlyList<AdapterRow> Adapters { get; init; } = [];

    public IReadOnlyList<AppRow> TopDownloadApps { get; init; } = [];

    public IReadOnlyList<AppRow> TopUploadApps { get; init; } = [];

    /// <summary>Every node that moved anything, biggest first — not capped, so it adds up.</summary>
    public IReadOnlyList<NodeRow> Nodes { get; init; } = [];

    public bool HasAdapterData => TotalDownloadBytes > 0 || TotalUploadBytes > 0 || Adapters.Count > 0;

    public bool HasAppData => TopDownloadApps.Count > 0 || TopUploadApps.Count > 0;
}

public static class StatisticsRanges
{
    public static string Code(this StatisticsRange range) => range switch
    {
        StatisticsRange.LastHour => "1H",
        StatisticsRange.Last24Hours => "24H",
        StatisticsRange.Last7Days => "7D",
        StatisticsRange.Last30Days => "30D",
        _ => "1Y",
    };

    public static string TitleKey(this StatisticsRange range) => range switch
    {
        StatisticsRange.LastHour => "Last Hour",
        StatisticsRange.Last24Hours => "Last 24 Hours",
        StatisticsRange.Last7Days => "Last 7 Days",
        StatisticsRange.Last30Days => "Last 30 Days",
        _ => "Last Year",
    };

    public static string BucketTitleKey(TimelineGranularity granularity) => granularity switch
    {
        TimelineGranularity.Minute => "Minute Traffic",
        TimelineGranularity.Hour => "Hourly Traffic",
        TimelineGranularity.Day => "Daily Traffic",
        _ => "Monthly Traffic",
    };
}

/// <summary>
/// Adapter and app traffic history in minute, hour and day buckets. Port of the macOS
/// <c>StatisticsStore</c> with the same retention (3 h of minutes, 72 h of hours, 400 days)
/// and the same report shape, so both platforms' Statistics windows answer the same
/// questions from the same kind of data.
///
/// <para>Bucket keys are local calendar time, as on macOS: "today" in Data Usage means
/// since local midnight, which is what a person means by today.</para>
///
/// <para>Thread-safe: recording happens on the UI tick, reports and saves on the pool.</para>
/// </summary>
public sealed class StatisticsStore
{
    public static readonly TimeSpan FlushInterval = TimeSpan.FromMinutes(5);

    private const int MinuteRetentionMinutes = 180;
    private const int HourlyRetentionHours = 72;
    private const int DailyRetentionDays = 400;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    private readonly string? _path;
    private readonly object _gate = new();
    private StatisticsArchive _archive;
    private bool _loaded;
    private bool _dirty;
    private DateTime? _lastFlush;
    private DateTime? _lastPrune;

    public StatisticsStore(string path)
    {
        _path = path;
        _archive = new StatisticsArchive();
    }

    /// <summary>An in-memory store over a ready-made archive — demo data and tests.</summary>
    public StatisticsStore(StatisticsArchive archive)
    {
        _archive = archive;
        _loaded = true;
    }

    public static string DefaultPath(string localAppData) => Path.Combine(localAppData, "NetFluss", "statistics.json");

    public void RecordAdapterDeltas(IEnumerable<AdapterDelta> deltas, DateTime now)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var any = false;
            var minute = MinuteKey(now);
            var hour = HourKey(now);
            var day = DayKey(now);

            foreach (var delta in deltas)
            {
                if (delta.DownloadBytes == 0 && delta.UploadBytes == 0)
                {
                    continue;
                }

                any = true;
                _archive.AdapterDisplayNames[delta.Id] = delta.DisplayName;
                if (delta.IsTunnel && !_archive.AdapterTunnels.Contains(delta.Id))
                {
                    _archive.AdapterTunnels.Add(delta.Id);
                }

                Accumulate(_archive.AdapterMinute, minute, delta.Id, delta.DownloadBytes, delta.UploadBytes);
                Accumulate(_archive.AdapterHourly, hour, delta.Id, delta.DownloadBytes, delta.UploadBytes);
                Accumulate(_archive.AdapterDaily, day, delta.Id, delta.DownloadBytes, delta.UploadBytes);
            }

            if (!any)
            {
                return;
            }

            _archive.LastAdapterSampleAt = new DateTimeOffset(now);
            _dirty = true;
            Prune(now);
        }
    }

    public void RecordAppDeltas(IEnumerable<AppDelta> deltas, DateTime now)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var any = false;
            var minute = MinuteKey(now);
            var hour = HourKey(now);
            var day = DayKey(now);

            foreach (var delta in deltas)
            {
                if (delta.DownloadBytes == 0 && delta.UploadBytes == 0)
                {
                    continue;
                }

                any = true;
                Accumulate(_archive.AppMinute, minute, delta.Name, delta.DownloadBytes, delta.UploadBytes);
                Accumulate(_archive.AppHourly, hour, delta.Name, delta.DownloadBytes, delta.UploadBytes);
                Accumulate(_archive.AppDaily, day, delta.Name, delta.DownloadBytes, delta.UploadBytes);
            }

            if (!any)
            {
                return;
            }

            _archive.LastAppSampleAt = new DateTimeOffset(now);
            _dirty = true;
            Prune(now);
        }
    }

    /// <summary>Per-proxy-node traffic from the Clash API.</summary>
    public void RecordNodeDeltas(IEnumerable<NodeDelta> deltas, DateTime now)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var any = false;
            var minute = MinuteKey(now);
            var hour = HourKey(now);
            var day = DayKey(now);

            foreach (var delta in deltas)
            {
                if (delta.DownloadBytes == 0 && delta.UploadBytes == 0)
                {
                    continue;
                }

                any = true;
                Accumulate(_archive.NodeMinute, minute, delta.Name, delta.DownloadBytes, delta.UploadBytes);
                Accumulate(_archive.NodeHourly, hour, delta.Name, delta.DownloadBytes, delta.UploadBytes);
                Accumulate(_archive.NodeDaily, day, delta.Name, delta.DownloadBytes, delta.UploadBytes);
            }

            if (!any)
            {
                return;
            }

            _archive.LastNodeSampleAt = new DateTimeOffset(now);
            _dirty = true;
            Prune(now);
        }
    }

    /// <summary>Writes the archive if it changed and the flush interval passed (or if forced).</summary>
    public void Flush(bool force, DateTime now)
    {
        string json;
        lock (_gate)
        {
            if (!_dirty || _path is null)
            {
                return;
            }

            if (!force && _lastFlush is { } last && now - last < FlushInterval)
            {
                return;
            }

            json = JsonSerializer.Serialize(_archive, Json);
            _dirty = false;
            _lastFlush = now;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temporary = _path + ".tmp";
            File.WriteAllText(temporary, json);
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Keep the data in memory; the next flush may succeed.
            lock (_gate)
            {
                _dirty = true;
            }
        }
    }

    /// <summary>Forgets every recorded byte — the "Reset statistics" button.</summary>
    public void Clear()
    {
        lock (_gate)
        {
            _archive = new StatisticsArchive();
            _loaded = true;
            _dirty = true;
        }
    }

    public StatisticsReport Report(
        StatisticsRange range,
        DateTime now,
        IReadOnlyDictionary<string, string> customNames,
        ISet<string> hiddenApps,
        bool excludeTunnels,
        IReadOnlyDictionary<string, TrafficAmounts>? appTotalsOverride = null)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var (source, appSource, nodeSource, keys, granularity, start) = range switch
            {
                StatisticsRange.LastHour => (_archive.AdapterMinute, _archive.AppMinute, _archive.NodeMinute, MinuteKeysEndingAt(now, 60), TimelineGranularity.Minute, now.AddMinutes(-59)),
                StatisticsRange.Last24Hours => (_archive.AdapterHourly, _archive.AppHourly, _archive.NodeHourly, HourKeysEndingAt(now, 24), TimelineGranularity.Hour, now.AddHours(-23)),
                StatisticsRange.Last7Days => (_archive.AdapterDaily, _archive.AppDaily, _archive.NodeDaily, DayKeysEndingAt(now, 7), TimelineGranularity.Day, now.AddDays(-6)),
                StatisticsRange.Last30Days => (_archive.AdapterDaily, _archive.AppDaily, _archive.NodeDaily, DayKeysEndingAt(now, 30), TimelineGranularity.Day, now.AddDays(-29)),
                _ => (_archive.AdapterDaily, _archive.AppDaily, _archive.NodeDaily, DayKeysEndingAt(now, 365), TimelineGranularity.Month, now.AddDays(-364)),
            };

            return MakeReport(range.TitleKey(), StatisticsRanges.BucketTitleKey(granularity), granularity, start, now,
                source, appSource, nodeSource, keys, customNames, hiddenApps, excludeTunnels, appTotalsOverride);
        }
    }

    /// <summary>A report over an arbitrary span, at the finest granularity still retained for it.</summary>
    public StatisticsReport Report(
        DateTime customStart,
        DateTime customEnd,
        DateTime now,
        IReadOnlyDictionary<string, string> customNames,
        ISet<string> hiddenApps,
        bool excludeTunnels,
        IReadOnlyDictionary<string, TrafficAmounts>? appTotalsOverride = null)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var end = Min(Max(customStart, customEnd), now);
            var start = Min(customStart, end);
            var span = end - start;

            Dictionary<string, Dictionary<string, TrafficAmounts>> source;
            Dictionary<string, Dictionary<string, TrafficAmounts>> appSource;
            Dictionary<string, Dictionary<string, TrafficAmounts>> nodeSource;
            List<string> keys;
            TimelineGranularity granularity;

            if (span <= TimeSpan.FromHours(3) && start >= now.AddMinutes(-MinuteRetentionMinutes))
            {
                (source, appSource, nodeSource, keys, granularity) = (_archive.AdapterMinute, _archive.AppMinute, _archive.NodeMinute, MinuteKeys(start, end), TimelineGranularity.Minute);
            }
            else if (span <= TimeSpan.FromHours(72) && start >= now.AddHours(-HourlyRetentionHours))
            {
                (source, appSource, nodeSource, keys, granularity) = (_archive.AdapterHourly, _archive.AppHourly, _archive.NodeHourly, HourKeys(start, end), TimelineGranularity.Hour);
            }
            else
            {
                (source, appSource, nodeSource, keys, granularity) = (_archive.AdapterDaily, _archive.AppDaily, _archive.NodeDaily, DayKeys(start, end),
                    span > TimeSpan.FromDays(90) ? TimelineGranularity.Month : TimelineGranularity.Day);
            }

            var title = string.Create(CultureInfo.CurrentCulture, $"{start:d} – {end:d}");
            return MakeReport(title, StatisticsRanges.BucketTitleKey(granularity), granularity, start, end,
                source, appSource, nodeSource, keys, customNames, hiddenApps, excludeTunnels, appTotalsOverride);
        }
    }

    /// <summary>
    /// Today (since local midnight) and this month (since the 1st) from the daily rollups.
    /// Cheap — at most ~31 buckets — so the popover can call it on every tick.
    /// </summary>
    public UsageSummary Usage(DateTime now, bool excludeTunnels)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var tunnels = _archive.AdapterTunnels.ToHashSet(StringComparer.OrdinalIgnoreCase);

            TrafficAmounts Total(IEnumerable<string> keys)
            {
                var total = new TrafficAmounts();
                foreach (var (id, amounts) in Aggregate(_archive.AdapterDaily, keys))
                {
                    if (!excludeTunnels || !tunnels.Contains(id))
                    {
                        total.Merge(amounts);
                    }
                }

                return total;
            }

            var monthStart = new DateTime(now.Year, now.Month, 1);
            return new UsageSummary(Total([DayKey(now)]), Total(DayKeys(monthStart, now)));
        }
    }

    private StatisticsReport MakeReport(
        string title,
        string bucketTitle,
        TimelineGranularity granularity,
        DateTime start,
        DateTime end,
        Dictionary<string, Dictionary<string, TrafficAmounts>> adapterSource,
        Dictionary<string, Dictionary<string, TrafficAmounts>> appSource,
        Dictionary<string, Dictionary<string, TrafficAmounts>> nodeSource,
        IReadOnlyList<string> keys,
        IReadOnlyDictionary<string, string> customNames,
        ISet<string> hiddenApps,
        bool excludeTunnels,
        IReadOnlyDictionary<string, TrafficAmounts>? appTotalsOverride)
    {
        var tunnels = _archive.AdapterTunnels.ToHashSet(StringComparer.OrdinalIgnoreCase);
        bool Counts(string id) => !excludeTunnels || !tunnels.Contains(id);

        // The adapter list shows every adapter, tunnels included; the headline totals and
        // the chart leave tunnels out when that preference is on, so they agree with the
        // live totals in the popover.
        var adapterTotals = Aggregate(adapterSource, keys);
        var totals = adapterTotals.Where(p => Counts(p.Key)).ToList();
        var appTotals = appTotalsOverride ?? Aggregate(appSource, keys);

        return new StatisticsReport
        {
            Title = title,
            BucketTitle = bucketTitle,
            Granularity = granularity,
            TimelineStart = start,
            TimelineEnd = end,
            CoverageStart = EarliestCoverage(),
            LastAdapterSampleAt = _archive.LastAdapterSampleAt,
            LastAppSampleAt = _archive.LastAppSampleAt,
            TotalDownloadBytes = totals.Aggregate(0UL, (sum, p) => sum + p.Value.DownloadBytes),
            TotalUploadBytes = totals.Aggregate(0UL, (sum, p) => sum + p.Value.UploadBytes),
            Timeline = Timeline(granularity, adapterSource, keys, Counts),
            Adapters = TopAdapters(adapterTotals, customNames),
            TopDownloadApps = AppRows(appTotals, hiddenApps, a => a.DownloadBytes),
            TopUploadApps = AppRows(appTotals, hiddenApps, a => a.UploadBytes),
            Nodes = NodeRows(Aggregate(nodeSource, keys)),
        };
    }

    private static Dictionary<string, TrafficAmounts> Aggregate(
        Dictionary<string, Dictionary<string, TrafficAmounts>> source,
        IEnumerable<string> keys)
    {
        var result = new Dictionary<string, TrafficAmounts>(StringComparer.Ordinal);
        foreach (var key in keys)
        {
            if (!source.TryGetValue(key, out var bucket))
            {
                continue;
            }

            foreach (var (item, amounts) in bucket)
            {
                if (!result.TryGetValue(item, out var current))
                {
                    current = new TrafficAmounts();
                    result[item] = current;
                }

                current.Merge(amounts);
            }
        }

        return result;
    }

    private static IReadOnlyList<TimelinePoint> Timeline(
        TimelineGranularity granularity,
        Dictionary<string, Dictionary<string, TrafficAmounts>> source,
        IReadOnlyList<string> keys,
        Func<string, bool> counts)
    {
        TrafficAmounts Sum(Dictionary<string, TrafficAmounts> bucket)
        {
            var total = new TrafficAmounts();
            foreach (var (id, amounts) in bucket)
            {
                if (counts(id))
                {
                    total.Merge(amounts);
                }
            }

            return total;
        }

        if (granularity == TimelineGranularity.Month)
        {
            var months = new SortedDictionary<string, TrafficAmounts>(StringComparer.Ordinal);
            foreach (var key in keys)
            {
                if (ParseKey(key) is not { } date || !source.TryGetValue(key, out var bucket))
                {
                    continue;
                }

                var monthKey = date.ToString("yyyy-MM", CultureInfo.InvariantCulture);
                if (!months.TryGetValue(monthKey, out var combined))
                {
                    combined = new TrafficAmounts();
                    months[monthKey] = combined;
                }

                combined.Merge(Sum(bucket));
            }

            return
            [
                .. months.Select(p => new TimelinePoint(
                    p.Key,
                    DateTime.ParseExact(p.Key, "yyyy-MM", CultureInfo.InvariantCulture),
                    p.Value.DownloadBytes,
                    p.Value.UploadBytes)),
            ];
        }

        // Every bucket in the range gets a point, empty or not, so the chart's time axis is
        // continuous — a gap in the data is a gap on the chart, not a bar that jumped left.
        var points = new List<TimelinePoint>(keys.Count);
        foreach (var key in keys)
        {
            if (ParseKey(key) is not { } date)
            {
                continue;
            }

            var amounts = source.TryGetValue(key, out var bucket) ? Sum(bucket) : new TrafficAmounts();
            points.Add(new TimelinePoint(key, date, amounts.DownloadBytes, amounts.UploadBytes));
        }

        return points;
    }

    private IReadOnlyList<AdapterRow> TopAdapters(Dictionary<string, TrafficAmounts> totals, IReadOnlyDictionary<string, string> customNames)
    {
        var rows = totals
            .Select(p => new AdapterRow(p.Key, ResolveName(p.Key, customNames), p.Value.DownloadBytes, p.Value.UploadBytes))
            .OrderByDescending(r => r.TotalBytes)
            .ThenBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        if (rows.Count <= 5)
        {
            return rows;
        }

        var overflow = rows.Skip(5).ToList();
        var download = overflow.Aggregate(0UL, (s, r) => s + r.DownloadBytes);
        var upload = overflow.Aggregate(0UL, (s, r) => s + r.UploadBytes);

        var top = rows.Take(5).ToList();
        if (download > 0 || upload > 0)
        {
            top.Add(new AdapterRow("other", "Other", download, upload));
        }

        return top;
    }

    private static IReadOnlyList<AppRow> AppRows(
        IReadOnlyDictionary<string, TrafficAmounts> totals,
        ISet<string> hiddenApps,
        Func<TrafficAmounts, ulong> select)
        =>
        [
            .. totals
                .Where(p => !hiddenApps.Contains(p.Key) && select(p.Value) > 0)
                .Select(p => new AppRow(p.Key, select(p.Value)))
                .OrderByDescending(r => r.Bytes)
                .ThenBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase)
                .Take(10),
        ];

    /// <summary>
    /// Every node that moved anything, biggest first. Unlike apps this is not capped at ten:
    /// it exists to reconcile a quota, and a truncated list would not add up to the total.
    /// </summary>
    private static IReadOnlyList<NodeRow> NodeRows(Dictionary<string, TrafficAmounts> totals)
        =>
        [
            .. totals
                .Where(p => p.Value.TotalBytes > 0)
                .Select(p => new NodeRow(p.Key, p.Value.DownloadBytes, p.Value.UploadBytes))
                .OrderByDescending(r => r.TotalBytes)
                .ThenBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase),
        ];

    private string ResolveName(string id, IReadOnlyDictionary<string, string> customNames)
        => customNames.TryGetValue(id, out var custom) && !string.IsNullOrWhiteSpace(custom)
            ? custom
            : _archive.AdapterDisplayNames.TryGetValue(id, out var stored) ? stored : id;

    private DateTime? EarliestCoverage()
    {
        DateTime? earliest = null;
        foreach (var key in _archive.AdapterDaily.Keys.Concat(_archive.AppDaily.Keys))
        {
            if (ParseKey(key) is { } date && (earliest is null || date < earliest))
            {
                earliest = date;
            }
        }

        return earliest ?? _archive.CreatedAt.LocalDateTime;
    }

    private static void Accumulate(
        Dictionary<string, Dictionary<string, TrafficAmounts>> storage,
        string bucketKey,
        string itemKey,
        ulong download,
        ulong upload)
    {
        if (!storage.TryGetValue(bucketKey, out var bucket))
        {
            bucket = new Dictionary<string, TrafficAmounts>(StringComparer.Ordinal);
            storage[bucketKey] = bucket;
        }

        if (!bucket.TryGetValue(itemKey, out var current))
        {
            current = new TrafficAmounts();
            bucket[itemKey] = current;
        }

        current.Add(download, upload);
    }

    /// <summary>
    /// Drops buckets past their retention. Throttled to once a minute: records arrive every
    /// second and the buckets are minute-grained, so pruning on each one is wasted work —
    /// the same throttle the Mac added for its energy pass.
    /// </summary>
    private void Prune(DateTime now)
    {
        if (_lastPrune is { } last && now - last < TimeSpan.FromMinutes(1))
        {
            return;
        }

        _lastPrune = now;
        RemoveBefore(_archive.AdapterMinute, now.AddMinutes(-MinuteRetentionMinutes));
        RemoveBefore(_archive.AppMinute, now.AddMinutes(-MinuteRetentionMinutes));
        RemoveBefore(_archive.AdapterHourly, now.AddHours(-HourlyRetentionHours));
        RemoveBefore(_archive.AppHourly, now.AddHours(-HourlyRetentionHours));
        RemoveBefore(_archive.AdapterDaily, now.AddDays(-DailyRetentionDays));
        RemoveBefore(_archive.AppDaily, now.AddDays(-DailyRetentionDays));
        RemoveBefore(_archive.NodeMinute, now.AddMinutes(-MinuteRetentionMinutes));
        RemoveBefore(_archive.NodeHourly, now.AddHours(-HourlyRetentionHours));
        RemoveBefore(_archive.NodeDaily, now.AddDays(-DailyRetentionDays));
    }

    private static void RemoveBefore(Dictionary<string, Dictionary<string, TrafficAmounts>> storage, DateTime cutoff)
    {
        foreach (var key in storage.Keys.Where(k => ParseKey(k) is not { } date || date < cutoff).ToList())
        {
            storage.Remove(key);
        }
    }

    private void EnsureLoaded()
    {
        if (_loaded)
        {
            return;
        }

        _loaded = true;
        if (_path is null || !File.Exists(_path))
        {
            return;
        }

        try
        {
            var archive = JsonSerializer.Deserialize<StatisticsArchive>(File.ReadAllText(_path), Json);
            if (archive is null)
            {
                return;
            }

            // Same rule as macOS: app history recorded under an older attribution scheme is
            // dropped rather than mixed with new, because the two disagree about names.
            if (archive.AppTrafficSchemaVersion < StatisticsArchive.CurrentAppTrafficSchemaVersion)
            {
                archive.AppMinute.Clear();
                archive.AppHourly.Clear();
                archive.AppDaily.Clear();
                archive.LastAppSampleAt = null;
                archive.AppTrafficSchemaVersion = StatisticsArchive.CurrentAppTrafficSchemaVersion;
                _dirty = true;
            }

            _archive = archive;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            // A damaged history must not stop the app; start a fresh one. The bad file is
            // left in place until the next flush replaces it.
        }
    }

    // =============================== Bucket keys ===============================

    internal static string MinuteKey(DateTime date) => date.ToString("yyyy-MM-dd-HH-mm", CultureInfo.InvariantCulture);

    internal static string HourKey(DateTime date) => date.ToString("yyyy-MM-dd-HH", CultureInfo.InvariantCulture);

    internal static string DayKey(DateTime date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>Any of the three key shapes back to the start of its bucket.</summary>
    internal static DateTime? ParseKey(string key)
    {
        var parts = key.Split('-');
        if (parts.Length is < 3 or > 5 || !parts.All(p => int.TryParse(p, NumberStyles.None, CultureInfo.InvariantCulture, out _)))
        {
            return null;
        }

        var n = parts.Select(p => int.Parse(p, CultureInfo.InvariantCulture)).ToArray();
        try
        {
            return parts.Length switch
            {
                3 => new DateTime(n[0], n[1], n[2]),
                4 => new DateTime(n[0], n[1], n[2], n[3], 0, 0),
                _ => new DateTime(n[0], n[1], n[2], n[3], n[4], 0),
            };
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static List<string> MinuteKeysEndingAt(DateTime now, int count)
    {
        var end = new DateTime(now.Year, now.Month, now.Day, now.Hour, now.Minute, 0);
        return [.. Enumerable.Range(0, count).Select(i => MinuteKey(end.AddMinutes(-(count - 1 - i))))];
    }

    private static List<string> HourKeysEndingAt(DateTime now, int count)
    {
        var end = new DateTime(now.Year, now.Month, now.Day, now.Hour, 0, 0);
        return [.. Enumerable.Range(0, count).Select(i => HourKey(end.AddHours(-(count - 1 - i))))];
    }

    private static List<string> DayKeysEndingAt(DateTime now, int count)
    {
        var end = now.Date;
        return [.. Enumerable.Range(0, count).Select(i => DayKey(end.AddDays(-(count - 1 - i))))];
    }

    private static List<string> MinuteKeys(DateTime start, DateTime end)
    {
        var keys = new List<string>();
        for (var current = new DateTime(start.Year, start.Month, start.Day, start.Hour, start.Minute, 0); current <= end; current = current.AddMinutes(1))
        {
            keys.Add(MinuteKey(current));
        }

        return keys;
    }

    private static List<string> HourKeys(DateTime start, DateTime end)
    {
        var keys = new List<string>();
        for (var current = new DateTime(start.Year, start.Month, start.Day, start.Hour, 0, 0); current <= end; current = current.AddHours(1))
        {
            keys.Add(HourKey(current));
        }

        return keys;
    }

    private static List<string> DayKeys(DateTime start, DateTime end)
    {
        var keys = new List<string>();
        for (var current = start.Date; current <= end.Date; current = current.AddDays(1))
        {
            keys.Add(DayKey(current));
        }

        return keys;
    }

    private static DateTime Min(DateTime a, DateTime b) => a < b ? a : b;

    private static DateTime Max(DateTime a, DateTime b) => a > b ? a : b;
}
