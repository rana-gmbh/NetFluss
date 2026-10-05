// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

[Collection(LocalizationCollection.Name)]
public sealed class NetworkSliceTests
{
    private static SliceFlow Flow(string process, string remote, int remotePort, long rx, long tx, string proto = "tcp", int localPort = 50000, string local = "192.168.1.10")
        => new(process, proto, local, localPort, remote, remotePort, rx, tx);

    private static readonly TimeSpan Second = TimeSpan.FromSeconds(1);

    [Fact]
    public void AggregatesHostsServicesAndApps()
    {
        var slice = new NetworkSlice();
        slice.Ingest(
        [
            Flow("chrome", "203.0.113.1", 443, 1000, 100),
            Flow("chrome", "203.0.113.2", 443, 500, 50, localPort: 50001),
            Flow("steam", "203.0.113.1", 27036, 300, 0, localPort: 50002),
        ], Second);

        var hosts = slice.Entries(SliceKind.Host, live: false);
        Assert.Equal(["203.0.113.1", "203.0.113.2"], hosts.Select(h => h.Id));
        Assert.Equal(1300UL, hosts[0].Received);

        var services = slice.Entries(SliceKind.Service, live: false);
        Assert.Equal("https", services[0].Id);
        Assert.Equal(1650UL, services[0].Total);
        Assert.Equal("Port 27036", services[1].Label);

        var apps = slice.Entries(SliceKind.App, live: false);
        Assert.Equal(["chrome", "steam"], apps.Select(a => a.Id));
        Assert.Equal(1800UL, slice.SessionReceived);
        Assert.Equal(150UL, slice.SessionSent);
    }

    [Fact]
    public void LiveShowsOnlyTheLastIntervalWhileTotalsAccumulate()
    {
        var slice = new NetworkSlice();
        slice.Ingest([Flow("a", "203.0.113.1", 443, 100, 0)], Second);
        slice.Ingest([Flow("b", "203.0.113.2", 443, 10, 0)], TimeSpan.FromSeconds(2));

        Assert.Equal(["203.0.113.2"], slice.Entries(SliceKind.Host, live: true).Select(h => h.Id));
        Assert.Equal(2, slice.Entries(SliceKind.Host, live: false).Count);
        Assert.Equal(2, slice.LastIntervalSeconds);
        Assert.Equal(110UL, slice.SessionReceived);
    }

    [Fact]
    public void LoopbackIsIgnoredAndMappedAddressesAreUnwrapped()
    {
        var slice = new NetworkSlice();
        slice.Ingest(
        [
            Flow("a", "127.0.0.1", 8080, 999, 999),
            Flow("a", "::1", 8080, 999, 999),
            Flow("b", "::ffff:203.0.113.5", 443, 10, 0),
        ], Second);

        Assert.Equal(["203.0.113.5"], slice.Entries(SliceKind.Host, live: false).Select(h => h.Id));
        Assert.Equal(10UL, slice.SessionReceived);
    }

    [Fact]
    public void ConnectionsAccumulateAndFilterByKind()
    {
        var slice = new NetworkSlice();
        slice.Ingest([Flow("chrome", "203.0.113.1", 443, 100, 10)], Second);
        slice.Ingest([Flow("chrome", "203.0.113.1", 443, 50, 5), Flow("chrome", "203.0.113.1", 443, 7, 0, localPort: 50001)], Second);

        var byHost = slice.Connections(SliceKind.Host, "203.0.113.1");
        Assert.Equal(2, byHost.Count);
        Assert.Equal(150UL, byHost[0].Received);
        Assert.Equal("TCP", byHost[0].Protocol);
        Assert.Equal(2, slice.Connections(SliceKind.Service, "https").Count);
        Assert.Equal(2, slice.Connections(SliceKind.App, "chrome").Count);
        Assert.Empty(slice.Connections(SliceKind.App, "steam"));
    }

    [Fact]
    public void HostnamesAndCountriesDecorateHostEntries()
    {
        var slice = new NetworkSlice();
        slice.Ingest([Flow("a", "203.0.113.1", 443, 1, 0), Flow("a", "192.168.1.1", 53, 1, 0, proto: "udp")], Second);
        slice.SetHostname("203.0.113.1", "example.net");
        slice.SetCountry("203.0.113.1", "DE");

        var entry = slice.Find(SliceKind.Host, "203.0.113.1")!;
        Assert.Equal("example.net", entry.Label);
        Assert.Equal("203.0.113.1", entry.Detail);
        Assert.Equal("DE", entry.CountryCode);
        Assert.True(slice.Find(SliceKind.Host, "192.168.1.1")!.IsPrivateHost);
        Assert.True(slice.HasHostname("203.0.113.1"));
        Assert.False(slice.HasCountry("192.168.1.1"));
    }

    [Fact]
    public void TopTwelveOnly()
    {
        var slice = new NetworkSlice();
        slice.Ingest(Enumerable.Range(1, 20).Select(i => Flow("a", $"203.0.113.{i}", 443, i, 0, localPort: 50000 + i)), Second);
        var hosts = slice.Entries(SliceKind.Host, live: false);
        Assert.Equal(NetworkSlice.MaximumVisibleEntries, hosts.Count);
        Assert.Equal("203.0.113.20", hosts[0].Id);
    }

    [Fact]
    public void ConnectionsStayBoundedAndKeepTheHeaviest()
    {
        var slice = new NetworkSlice();

        // A browser's day: one heavy download, then thousands of short-lived sockets.
        slice.Ingest([Flow("chrome", "203.0.113.1", 443, 1_000_000, 0, localPort: 40000)], Second);
        for (var batch = 0; batch < 10; batch++)
        {
            slice.Ingest(Enumerable.Range(0, 1000).Select(i => Flow("chrome", "203.0.113.2", 443, 1, 0, localPort: 1 + (batch * 1000) + i)), Second);
        }

        var kept = slice.Connections(SliceKind.App, "chrome");
        Assert.True(kept.Count <= NetworkSlice.MaximumConnections + 1000, $"{kept.Count} connections kept");
        Assert.Equal(1_000_000UL, kept[0].Received);
    }

    [Theory]
    [InlineData(50000, 443, "https")]
    [InlineData(5353, 5353, "zeroconf")]
    [InlineData(50000, 8000, "#8000")]
    [InlineData(50000, 40000, "#other")]
    [InlineData(null, null, null)]
    public void ServiceKeys(int? local, int? remote, string? expected)
        => Assert.Equal(expected, NetworkSlice.ServiceKey(local, remote));

    [Theory]
    [InlineData("10.0.0.1", true)]
    [InlineData("172.20.1.1", true)]
    [InlineData("172.32.1.1", false)]
    [InlineData("239.255.255.250", true)]
    [InlineData("fe80::1", true)]
    [InlineData("2001:db8::1", false)]
    [InlineData("8.8.8.8", false)]
    public void PrivateHosts(string host, bool expected) => Assert.Equal(expected, NetworkSlice.IsPrivateHost(host));

    [Theory]
    [InlineData("ber01s21-in-f14.1e100.net", "1e100.net")]
    [InlineData("a.b.example.co.uk", "example.co.uk")]
    [InlineData("printer.local", "printer.local")]
    [InlineData("nas.home.local", "nas.home.local")]
    [InlineData("example.com.", "example.com")]
    public void SimplifiesDomains(string input, string expected) => Assert.Equal(expected, NetworkSlice.SimplifiedDomain(input));

    [Fact]
    public void ParsesCountryIs()
    {
        Assert.Equal("DE", NetworkSlice.ParseCountryIs("""{"ip":"203.0.113.1","country":"de"}"""));
        Assert.Null(NetworkSlice.ParseCountryIs("""{"error":"x"}"""));
        Assert.Null(NetworkSlice.ParseCountryIs("""{"country":"D1"}"""));
    }

    [Fact]
    public void DemoProducesAVariedSlice()
    {
        var slice = new NetworkSlice();
        var demo = new NetworkSliceDemo();
        demo.Prime(slice);
        for (var i = 0; i < 10; i++)
        {
            slice.Ingest(demo.Next(Second), Second);
        }

        Assert.True(slice.Entries(SliceKind.Host, live: false).Count >= 8);
        Assert.Contains(slice.Entries(SliceKind.Host, live: false), e => e.CountryCode is not null);
        Assert.True(slice.Entries(SliceKind.App, live: false).Count >= 6);
    }
}
