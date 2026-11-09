// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>
/// The link indicator's decision table and the internet check's schedule — ports of the
/// macOS 2.7 <c>LinkHealthTracker</c>. The indicator only goes amber on evidence, never on
/// ignorance, and that rule is most of what is pinned here.
/// </summary>
public class LinkHealthTests
{
    private static AdapterStatus Adapter(string id, AdapterType type = AdapterType.WiFi, bool up = true, bool tunnel = false, ulong bytes = 0) => new()
    {
        Id = id,
        DisplayName = id,
        Description = id,
        Type = type,
        IsTunnel = tunnel,
        IsNonInternet = false,
        IsUp = up,
        RxBytes = bytes,
        TxBytes = 0,
        WifiSsid = type == AdapterType.WiFi ? "Home" : null,
    };

    [Fact]
    public void NoCarrier_IsOffline()
        => Assert.Equal(LinkHealth.Offline, LinkHealthEvaluator.Evaluate(null, "192.168.1.2", "192.168.1.1", true, null).Health);

    [Fact]
    public void CarrierDown_IsOffline()
        => Assert.Equal(LinkHealth.Offline, LinkHealthEvaluator.Evaluate(Adapter("a", up: false), "192.168.1.2", "192.168.1.1", true, null).Health);

    /// <summary>No request could say anything a self-assigned address has not already said.</summary>
    [Theory]
    [InlineData("169.254.10.20", "192.168.1.1")]
    [InlineData("192.168.1.2", "")]
    [InlineData("192.168.1.2", null)]
    [InlineData(null, "192.168.1.1")]
    public void UnusableAddressing_IsLimited(string? ip, string? gateway)
        => Assert.Equal(LinkHealth.Limited, LinkHealthEvaluator.Evaluate(Adapter("a"), ip, gateway, true, LinkProbeOutcome.Online).Health);

    [Fact]
    public void UnknownVerdict_ShowsOnline()
        => Assert.Equal(LinkHealth.Online, LinkHealthEvaluator.Evaluate(Adapter("a"), "192.168.1.2", "192.168.1.1", true, null).Health);

    [Theory]
    [InlineData(LinkProbeOutcome.Portal)]
    [InlineData(LinkProbeOutcome.Unreachable)]
    public void BadVerdict_IsLimited(LinkProbeOutcome verdict)
        => Assert.Equal(LinkHealth.Limited, LinkHealthEvaluator.Evaluate(Adapter("a"), "192.168.1.2", "192.168.1.1", true, verdict).Health);

    /// <summary>With the check off, green means "the link is up" and nothing more.</summary>
    [Fact]
    public void CheckOff_IgnoresTheVerdict()
        => Assert.Equal(LinkHealth.Online, LinkHealthEvaluator.Evaluate(Adapter("a"), "192.168.1.2", "192.168.1.1", false, LinkProbeOutcome.Portal).Health);

    [Fact]
    public void Medium_FollowsTheCarrier()
    {
        Assert.Equal(LinkMedium.WiFi, LinkHealthEvaluator.Evaluate(Adapter("a"), "10.0.0.2", "10.0.0.1", false, null).Medium);
        Assert.Equal(LinkMedium.Ethernet, LinkHealthEvaluator.Evaluate(Adapter("a", AdapterType.Ethernet), "10.0.0.2", "10.0.0.1", false, null).Medium);
    }

    /// <summary>
    /// With a VPN up the route goes through the tunnel, but the indicator is about the link
    /// underneath — the VPN has its own mark.
    /// </summary>
    [Fact]
    public void Carrier_SkipsTunnels()
    {
        AdapterStatus[] adapters =
        [
            Adapter("vpn", AdapterType.Other, tunnel: true, bytes: 900),
            Adapter("wifi", AdapterType.WiFi, bytes: 500),
            Adapter("eth", AdapterType.Ethernet, bytes: 100),
        ];

        Assert.Equal("wifi", LinkHealthEvaluator.Carrier("vpn", adapters)!.Id);
        Assert.Equal("eth", LinkHealthEvaluator.Carrier("eth", adapters)!.Id);
        Assert.Equal("wifi", LinkHealthEvaluator.Carrier(null, adapters)!.Id);
    }

    [Theory]
    [InlineData(200, LinkProbeOutcome.Online)]
    [InlineData(204, LinkProbeOutcome.Online)]
    [InlineData(302, LinkProbeOutcome.Portal)]
    [InlineData(511, LinkProbeOutcome.Portal)]
    [InlineData(null, LinkProbeOutcome.Unreachable)]
    public void Classify_TreatsARedirectAsAPortal(int? status, LinkProbeOutcome expected)
        => Assert.Equal(expected, LinkProbe.Classify(status));

    [Theory]
    [InlineData("", "")]
    [InlineData("   ", "")]
    [InlineData("example.com", "http://example.com/")]
    [InlineData("https://example.com/check", "https://example.com/check")]
    [InlineData("ftp://example.com", "")]
    [InlineData("file:///C:/Windows/win.ini", "")]
    [InlineData("javascript:alert(1)", "")]
    public void Normalize_KeepsOnlyHttpAddresses(string input, string expected)
        => Assert.Equal(expected, LinkProbe.Normalize(input));

    [Fact]
    public void Probe_RunsAtOnceOnANewNetwork()
    {
        var probe = new LinkProbe();
        var now = DateTime.UtcNow;

        Assert.True(probe.ShouldProbe("net-a", now));
        probe.Started(now);
        Assert.False(probe.ShouldProbe("net-a", now));
        probe.Completed(LinkProbeOutcome.Online);

        // A different network is probed at once, and forgets the old verdict.
        Assert.True(probe.ShouldProbe("net-b", now.AddSeconds(1)));
        Assert.Null(probe.Verdict);
    }

    [Fact]
    public void Probe_BacksOffMoreWhenHealthy()
    {
        var probe = new LinkProbe();
        var now = DateTime.UtcNow;

        probe.ShouldProbe("net", now);
        probe.Started(now);
        probe.Completed(LinkProbeOutcome.Online);

        Assert.False(probe.ShouldProbe("net", now + LinkProbe.DegradedInterval));
        Assert.True(probe.ShouldProbe("net", now + LinkProbe.HealthyInterval));
    }

    /// <summary>A single dropped request is not an outage.</summary>
    [Fact]
    public void Probe_NeedsTwoFailuresForUnreachable()
    {
        var probe = new LinkProbe();
        var now = DateTime.UtcNow;
        probe.ShouldProbe("net", now);
        probe.Started(now);
        probe.Completed(LinkProbeOutcome.Online);

        probe.Started(now);
        probe.Completed(LinkProbeOutcome.Unreachable);
        Assert.Equal(LinkProbeOutcome.Online, probe.Verdict);

        // …but the first failure already shortens the schedule, so the second comes quickly.
        Assert.True(probe.ShouldProbe("net", now + LinkProbe.DegradedInterval));

        probe.Started(now);
        probe.Completed(LinkProbeOutcome.Unreachable);
        Assert.Equal(LinkProbeOutcome.Unreachable, probe.Verdict);
    }

    /// <summary>A portal answer is unambiguous, so it is believed at once.</summary>
    [Fact]
    public void Probe_BelievesAPortalImmediately()
    {
        var probe = new LinkProbe();
        probe.ShouldProbe("net", DateTime.UtcNow);
        probe.Started(DateTime.UtcNow);

        Assert.True(probe.Completed(LinkProbeOutcome.Portal));
        Assert.Equal(LinkProbeOutcome.Portal, probe.Verdict);
    }
}

/// <summary>The 2.7 meter settings: each sanitises what it is given, as the settings file can be hand-edited.</summary>
public class MeterAccessorySettingsTests
{
    [Theory]
    [InlineData("dot", "dot")]
    [InlineData("shield", "shield")]
    [InlineData("globe", "globe")]
    [InlineData("bars", "bars")]
    [InlineData("sparkles", "off")]
    public void VpnIndicator_AcceptsTheFourStyles(string set, string expected)
        => Assert.Equal(expected, new AppSettings { VpnIndicator = set }.VpnIndicator);

    [Theory]
    [InlineData(4, 10)]
    [InlineData(14, 14)]
    [InlineData(15.4, 15)]
    [InlineData(40, 18)]
    [InlineData(double.NaN, 14)]
    public void VpnIndicatorSize_IsClampedTo10Through18(double set, double expected)
        => Assert.Equal(expected, new AppSettings { VpnIndicatorSize = set }.VpnIndicatorSize);

    [Theory]
    [InlineData("left", "left")]
    [InlineData("right", "right")]
    [InlineData("center", "center")]
    [InlineData("justify", "center")]
    public void RateAlignment_DefaultsToCentred(string set, string expected)
        => Assert.Equal(expected, new AppSettings { RateAlignment = set }.RateAlignment);

    [Fact]
    public void Defaults_MatchMacOs()
    {
        var settings = new AppSettings();

        Assert.Equal("center", settings.RateAlignment);
        Assert.Equal(14, settings.VpnIndicatorSize);
        Assert.False(settings.LinkIndicator);
        Assert.True(settings.LinkCheckInternet);
        Assert.Equal(string.Empty, settings.LinkProbeUrl);
        Assert.False(settings.ShowResolver);
        Assert.False(settings.CountryFlagOnlyWithVpn);
        Assert.Equal("green", settings.LinkColorOnline);
        Assert.Equal("orange", settings.LinkColorLimited);
        Assert.Equal("red", settings.LinkColorOffline);
    }

    [Fact]
    public void LinkColors_ResolveToTheirStateDefaults()
    {
        var settings = new AppSettings();

        Assert.Equal(AccentPalette.Resolve("green", string.Empty, LinkStatus.DefaultOnline), settings.ResolveLinkColor(LinkHealth.Online));
        Assert.Equal(AccentPalette.Resolve("red", string.Empty, LinkStatus.DefaultOffline), settings.ResolveLinkColor(LinkHealth.Offline));

        settings.LinkColorLimited = "custom";
        settings.LinkColorLimitedHex = "123456";
        Assert.Equal(ThemeColor.FromHex("123456"), settings.ResolveLinkColor(LinkHealth.Limited));
    }

    [Fact]
    public void SettingsRoundTrip()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-meter-{Guid.NewGuid():N}.json");
        try
        {
            var store = new SettingsStore(path);
            store.Batch(settings =>
            {
                settings.RateAlignment = "right";
                settings.VpnIndicator = "bars";
                settings.VpnIndicatorSize = 16;
                settings.LinkIndicator = true;
                settings.LinkProbeUrl = "example.com";
                settings.ShowResolver = true;
                settings.CountryFlagOnlyWithVpn = true;
            });

            var reloaded = new SettingsStore(path).Settings;
            Assert.Equal("right", reloaded.RateAlignment);
            Assert.Equal("bars", reloaded.VpnIndicator);
            Assert.Equal(16, reloaded.VpnIndicatorSize);
            Assert.True(reloaded.LinkIndicator);
            Assert.Equal("http://example.com/", reloaded.LinkProbeUrl);
            Assert.True(reloaded.ShowResolver);
            Assert.True(reloaded.CountryFlagOnlyWithVpn);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
