// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

public class StatisticsStoreTests
{
    private static readonly DateTime Noon = new(2026, 10, 4, 12, 30, 0);
    private static readonly Dictionary<string, string> NoNames = [];
    private static readonly HashSet<string> NoHidden = [];

    private static StatisticsStore Empty() => new(new StatisticsArchive());

    [Fact]
    public void Deltas_LandInEveryGranularity()
    {
        var store = Empty();
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 1_000, 200)], Noon);

        var hour = store.Report(StatisticsRange.LastHour, Noon, NoNames, NoHidden, excludeTunnels: false);
        var day = store.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, excludeTunnels: false);
        var month = store.Report(StatisticsRange.Last30Days, Noon, NoNames, NoHidden, excludeTunnels: false);

        Assert.Equal(1_000UL, hour.TotalDownloadBytes);
        Assert.Equal(1_000UL, day.TotalDownloadBytes);
        Assert.Equal(200UL, month.TotalUploadBytes);
        Assert.Equal(TimelineGranularity.Minute, hour.Granularity);
    }

    /// <summary>
    /// The chart's time axis must be continuous: one point per bucket in the range, so a
    /// quiet hour is a gap on the chart rather than a bar that slid left into its place.
    /// </summary>
    [Fact]
    public void Timeline_HasAPointForEveryBucket()
    {
        var store = Empty();
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 5, 5)], Noon);

        Assert.Equal(60, store.Report(StatisticsRange.LastHour, Noon, NoNames, NoHidden, false).Timeline.Count);
        Assert.Equal(24, store.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, false).Timeline.Count);
        Assert.Equal(7, store.Report(StatisticsRange.Last7Days, Noon, NoNames, NoHidden, false).Timeline.Count);
    }

    [Fact]
    public void Tunnels_AreListed_ButLeftOutOfTotalsWhenAsked()
    {
        var store = Empty();
        store.RecordAdapterDeltas(
            [
                new AdapterDelta("{eth}", "Ethernet", false, 1_000, 0),
                new AdapterDelta("{vpn}", "WireGuard", true, 400, 0),
            ],
            Noon);

        var included = store.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, excludeTunnels: false);
        var excluded = store.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, excludeTunnels: true);

        Assert.Equal(1_400UL, included.TotalDownloadBytes);
        Assert.Equal(1_000UL, excluded.TotalDownloadBytes);

        // The adapter list keeps the tunnel either way, as on macOS.
        Assert.Equal(2, excluded.Adapters.Count);

        Assert.Equal(1_000UL, store.Usage(Noon, excludeTunnels: true).Today.DownloadBytes);
    }

    [Fact]
    public void Usage_SplitsTodayFromTheRestOfTheMonth()
    {
        var store = Empty();
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 100, 0)], Noon.AddDays(-2));
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 10, 0)], Noon);

        var usage = store.Usage(Noon, excludeTunnels: false);

        Assert.Equal(10UL, usage.Today.DownloadBytes);
        Assert.Equal(110UL, usage.Month.DownloadBytes);
    }

    [Fact]
    public void LastMonth_DoesNotCountTowardThisMonth()
    {
        var store = Empty();
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 500, 0)], new DateTime(2026, 9, 30, 23, 0, 0));
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 7, 0)], Noon);

        Assert.Equal(7UL, store.Usage(Noon, false).Month.DownloadBytes);
    }

    [Fact]
    public void MoreThanFiveAdapters_FoldIntoOther()
    {
        var store = Empty();
        var deltas = Enumerable.Range(1, 8).Select(i => new AdapterDelta($"{{a{i}}}", $"Adapter {i}", false, (ulong)(i * 100), 0));
        store.RecordAdapterDeltas(deltas, Noon);

        var adapters = store.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, false).Adapters;

        Assert.Equal(6, adapters.Count);
        Assert.Equal("other", adapters[^1].Id);
        Assert.Equal(100UL + 200 + 300, adapters[^1].DownloadBytes);
    }

    [Fact]
    public void CustomNames_WinOverRecordedNames()
    {
        var store = Empty();
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet 3", false, 1, 0)], Noon);

        var report = store.Report(StatisticsRange.Last24Hours, Noon, new Dictionary<string, string> { ["{eth}"] = "Desk" }, NoHidden, false);
        Assert.Equal("Desk", report.Adapters.Single().Name);
    }

    [Fact]
    public void AppOverride_ReplacesRecordedApps_AndHiddenAppsAreDropped()
    {
        var store = Empty();
        store.RecordAppDeltas([new AppDelta("Recorded", 9, 9)], Noon);

        var apps = new Dictionary<string, TrafficAmounts>
        {
            ["Edge"] = new() { DownloadBytes = 300, UploadBytes = 10 },
            ["Noisy"] = new() { DownloadBytes = 900, UploadBytes = 0 },
        };

        var report = store.Report(StatisticsRange.Last24Hours, Noon, NoNames, new HashSet<string> { "Noisy" }, false, apps);

        Assert.Equal(["Edge"], report.TopDownloadApps.Select(a => a.Name));
        Assert.DoesNotContain(report.TopDownloadApps, a => a.Name == "Recorded");
    }

    [Fact]
    public void MinuteBuckets_ArePrunedAfterThreeHours()
    {
        var store = Empty();
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 50, 0)], Noon.AddHours(-4));
        store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 1, 0)], Noon);

        // A custom three-hour window four hours back would read the minute buckets.
        var report = store.Report(Noon.AddHours(-4).AddMinutes(-1), Noon.AddHours(-4).AddMinutes(1), Noon, NoNames, NoHidden, false);

        // Minute data is gone; the hourly rollup still has it.
        Assert.Equal(TimelineGranularity.Hour, report.Granularity);
        Assert.Equal(50UL, report.TotalDownloadBytes);
    }

    [Fact]
    public void Archive_SurvivesASaveAndReload()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-stats-{Guid.NewGuid():N}.json");
        try
        {
            var store = new StatisticsStore(path);
            store.RecordAdapterDeltas([new AdapterDelta("{vpn}", "VPN", true, 123, 45)], Noon);
            store.Flush(force: true, Noon);

            var reloaded = new StatisticsStore(path);
            var report = reloaded.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, excludeTunnels: true);

            Assert.Equal(0UL, report.TotalDownloadBytes);
            Assert.Equal(123UL, reloaded.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, false).TotalDownloadBytes);
            Assert.Contains("\"adapterDaily\"", File.ReadAllText(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string TempFolder()
    {
        var folder = Path.Combine(Path.GetTempPath(), $"netfluss-stats-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);
        return folder;
    }

    [Fact]
    public void CorruptArchive_StartsFresh_RatherThanThrowing()
    {
        var folder = TempFolder();
        try
        {
            var path = Path.Combine(folder, "statistics.json");
            File.WriteAllText(path, "{ this is not json");
            var store = new StatisticsStore(path);
            Assert.False(store.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, false).HasAdapterData);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>
    /// macOS 2.7.2: an unreadable archive is kept aside, not saved over, and yesterday's copy
    /// takes its place — a damaged file must not become permanently lost history.
    /// </summary>
    [Fact]
    public void CorruptArchive_IsKeptAside_AndTheBackupRestored()
    {
        var folder = TempFolder();
        try
        {
            var path = Path.Combine(folder, "statistics.json");
            var store = new StatisticsStore(path);
            store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 500, 50)], Noon);
            store.Flush(force: true, Noon);

            // The second save takes the daily backup of what the first one wrote.
            store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 1, 1)], Noon);
            store.Flush(force: true, Noon);
            Assert.True(File.Exists(StatisticsStore.BackupPath(path)));

            File.WriteAllText(path, "{ damaged");
            var restored = new StatisticsStore(path);
            var report = restored.Report(StatisticsRange.Last24Hours, Noon, NoNames, NoHidden, false);

            Assert.Equal(500UL, report.TotalDownloadBytes);
            var aside = Assert.Single(Directory.GetFiles(folder, "statistics.unreadable-*.json"));
            Assert.Equal("{ damaged", File.ReadAllText(aside));

            // Restored history is written back under the original name.
            restored.Flush(force: true, Noon);
            Assert.Contains("\"adapterDaily\"", File.ReadAllText(path));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>A copy taken minutes ago would only ever hold the same damage, so it is refreshed daily.</summary>
    [Fact]
    public void Backup_IsRefreshedOncePerDay()
    {
        var folder = TempFolder();
        try
        {
            var path = Path.Combine(folder, "statistics.json");
            var store = new StatisticsStore(path);
            store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 100, 0)], Noon);
            store.Flush(force: true, Noon);
            store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 100, 0)], Noon);
            store.Flush(force: true, Noon);
            var first = File.ReadAllText(StatisticsStore.BackupPath(path));

            store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 100, 0)], Noon);
            store.Flush(force: true, Noon.AddHours(1));
            Assert.Equal(first, File.ReadAllText(StatisticsStore.BackupPath(path)));

            store.RecordAdapterDeltas([new AdapterDelta("{eth}", "Ethernet", false, 100, 0)], Noon);
            store.Flush(force: true, Noon.AddDays(1).AddMinutes(1));
            Assert.NotEqual(first, File.ReadAllText(StatisticsStore.BackupPath(path)));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Theory]
    [InlineData("2026-10-04", 2026, 10, 4, 0, 0)]
    [InlineData("2026-10-04-13", 2026, 10, 4, 13, 0)]
    [InlineData("2026-10-04-13-07", 2026, 10, 4, 13, 7)]
    public void Keys_ParseBackToTheirBucket(string key, int y, int mo, int d, int h, int mi)
        => Assert.Equal(new DateTime(y, mo, d, h, mi, 0), StatisticsStore.ParseKey(key));

    [Fact]
    public void DemoArchive_FillsEveryRange()
    {
        var store = new StatisticsStore(StatisticsDemoData.MakeArchive(Noon));

        foreach (var range in Enum.GetValues<StatisticsRange>())
        {
            var report = store.Report(range, Noon, NoNames, NoHidden, false);
            Assert.True(report.HasAdapterData, $"{range} has no adapter data");
            Assert.True(report.HasAppData, $"{range} has no app data");
        }
    }
}

public class ByteFormatterTests
{
    [Theory]
    [InlineData(999UL, "1 KB")]
    [InlineData(345_000UL, "345 KB")]
    [InlineData(1_240_000UL, "1.2 MB")]
    [InlineData(12_500_000_000UL, "12.5 GB")]
    public void Bytes_UseTheAdaptiveDecimalStyle(ulong bytes, string expected)
        => Assert.Equal(expected, RateFormatter.FormatBytes(bytes, System.Globalization.CultureInfo.InvariantCulture));
}
