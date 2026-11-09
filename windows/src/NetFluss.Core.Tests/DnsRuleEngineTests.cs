// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>
/// Automatic DNS by Wi-Fi network — the macOS 2.7 <c>DNSRuleEngine</c>. Each guard in the
/// table is a situation where writing DNS would do harm, so each gets a test.
/// </summary>
public class DnsRuleEngineTests
{
    private static readonly Dictionary<string, IReadOnlyList<string>> Servers = new()
    {
        ["system"] = [],
        ["cloudflare"] = ["1.1.1.1", "1.0.0.1"],
        ["quad9"] = ["9.9.9.9", "149.112.112.112"],
        ["mine"] = ["1.0.0.1", "1.1.1.1"],
    };

    private static DnsRuleInput Input(
        string? ssid = "Home",
        string? bssid = null,
        IReadOnlyList<DnsRule>? rules = null,
        string? fallback = null,
        bool helper = true,
        bool vpnDns = false,
        LinkHealth? health = LinkHealth.Online,
        bool portalSignal = true,
        string? active = "system",
        IReadOnlyList<string>? current = null) => new()
    {
        Enabled = true,
        HelperEnabled = helper,
        Ssid = ssid,
        Bssid = bssid,
        LinkHealth = health,
        PortalSignalAvailable = portalSignal,
        VpnDnsActive = vpnDns,
        ActivePresetId = active,
        CurrentServers = current ?? [],
        PresetServers = Servers,
        Rules = rules ?? [new DnsRule { Ssid = "Home", PresetId = "cloudflare" }],
        FallbackPresetId = fallback,
    };

    [Fact]
    public void Disabled_IsOff()
        => Assert.Equal(DnsAutoSwitchState.Off, DnsRuleEngine.Decide(Input() with { Enabled = false }).State);

    /// <summary>A UAC prompt on every network change is worse than not switching at all.</summary>
    [Fact]
    public void WithoutTheHelper_NeverApplies()
    {
        var decision = DnsRuleEngine.Decide(Input(helper: false));
        Assert.Equal(DnsAutoSwitchState.NeedsHelper, decision.State);
        Assert.Null(decision.ApplyPresetId);
    }

    [Fact]
    public void VpnDns_TakesPrecedence()
        => Assert.Equal(DnsAutoSwitchState.SuspendedByVpn, DnsRuleEngine.Decide(Input(vpnDns: true)).State);

    [Fact]
    public void MatchingRule_Applies()
    {
        var decision = DnsRuleEngine.Decide(Input());
        Assert.Equal("cloudflare", decision.ApplyPresetId);
        Assert.Equal(DnsAutoSwitchState.Applied("Home", "cloudflare"), decision.State);
    }

    [Fact]
    public void AlreadyApplied_SpendsNoWrite()
    {
        var decision = DnsRuleEngine.Decide(Input(active: "cloudflare", current: ["1.1.1.1", "1.0.0.1"]));
        Assert.Null(decision.ApplyPresetId);
        Assert.Equal(DnsAutoSwitchState.Applied("Home", "cloudflare"), decision.State);
    }

    /// <summary>
    /// A custom profile with a built-in's servers reads back as the built-in; it must still
    /// count as applied, or it would be rewritten on every tick.
    /// </summary>
    [Fact]
    public void SameServersUnderAnotherId_CountAsApplied()
    {
        var rules = new[] { new DnsRule { Ssid = "Home", PresetId = "mine" } };
        var decision = DnsRuleEngine.Decide(Input(rules: rules, active: "cloudflare", current: ["1.1.1.1", "1.0.0.1"]));
        Assert.Null(decision.ApplyPresetId);
    }

    [Fact]
    public void NoRuleAndNoFallback_LeavesDnsAlone()
        => Assert.Equal(DnsAutoSwitchState.NoRule, DnsRuleEngine.Decide(Input(ssid: "Cafe")).State);

    [Fact]
    public void Fallback_CoversOtherNetworks()
        => Assert.Equal("quad9", DnsRuleEngine.Decide(Input(ssid: "Cafe", fallback: "quad9")).ApplyPresetId);

    /// <summary>The catch-all is what stops a public resolver following the user home on a cable.</summary>
    [Fact]
    public void Wired_UsesOnlyTheFallback()
    {
        Assert.Equal(DnsAutoSwitchState.NoRule, DnsRuleEngine.Decide(Input(ssid: null)).State);

        var decision = DnsRuleEngine.Decide(Input(ssid: null, fallback: "system", active: "cloudflare", current: ["1.1.1.1", "1.0.0.1"]));
        Assert.Equal("system", decision.ApplyPresetId);
        Assert.Equal(DnsAutoSwitchState.Applied(string.Empty, "system"), decision.State);
    }

    /// <summary>Applying a public resolver before the hotel login page is cleared breaks the login page.</summary>
    [Fact]
    public void CaptivePortal_Waits()
        => Assert.Equal(DnsAutoSwitchState.WaitingForPortal("Home"), DnsRuleEngine.Decide(Input(health: LinkHealth.Limited)).State);

    /// <summary>With the internet check off, "limited" only means odd addressing — not a portal to wait for.</summary>
    [Fact]
    public void WithoutAPortalSignal_DoesNotWait()
        => Assert.Equal("cloudflare", DnsRuleEngine.Decide(Input(health: LinkHealth.Limited, portalSignal: false)).ApplyPresetId);

    [Fact]
    public void LinkDown_WaitsForTheNetwork()
        => Assert.Equal(DnsAutoSwitchState.WaitingForNetwork("Home"), DnsRuleEngine.Decide(Input(health: LinkHealth.Offline)).State);

    [Fact]
    public void Match_PrefersThePinnedAccessPoint()
    {
        DnsRule[] rules =
        [
            new() { Ssid = "Home", PresetId = "cloudflare" },
            new() { Ssid = "Home", Bssid = "AA:BB:CC:DD:EE:FF", PresetId = "quad9" },
        ];

        Assert.Equal("quad9", DnsRuleEngine.Match("Home", "aa:bb:cc:dd:ee:ff", rules));
        Assert.Equal("cloudflare", DnsRuleEngine.Match("Home", "11:22:33:44:55:66", rules));
        Assert.Equal("cloudflare", DnsRuleEngine.Match("Home", null, rules));
    }

    /// <summary>A rule pinned to one access point does not fire on a look-alike network of the same name.</summary>
    [Fact]
    public void Match_PinnedRuleIgnoresOtherAccessPoints()
    {
        DnsRule[] rules = [new() { Ssid = "Home", Bssid = "AA:BB:CC:DD:EE:FF", PresetId = "quad9" }];

        Assert.Null(DnsRuleEngine.Match("Home", "11:22:33:44:55:66", rules));
        Assert.Null(DnsRuleEngine.Match("Home", null, rules));
    }

    [Fact]
    public void Match_SkipsDisabledRulesAndIsCaseSensitiveOnTheName()
    {
        DnsRule[] rules =
        [
            new() { Ssid = "Home", PresetId = "quad9", Enabled = false },
            new() { Ssid = "home", PresetId = "cloudflare" },
        ];

        Assert.Null(DnsRuleEngine.Match("Home", null, rules));
    }

    [Fact]
    public void Evaluate_WaitsForTheNetworkToSettle()
    {
        var engine = new DnsRuleEngine();
        var start = new DateTime(2026, 11, 9, 12, 0, 0, DateTimeKind.Utc);

        Assert.Null(engine.Evaluate(Input(), start));
        Assert.Null(engine.Evaluate(Input(), start.AddSeconds(1)));
        Assert.Equal("cloudflare", engine.Evaluate(Input(), start + DnsRuleEngine.SettleDelay));
        Assert.Equal(DnsAutoSwitchState.Applied("Home", "cloudflare"), engine.State);
    }

    /// <summary>Each failed write waits longer: 5, 10, 20 … seconds.</summary>
    [Fact]
    public void Evaluate_BacksOffAWriteThatDidNotTake()
    {
        var engine = new DnsRuleEngine();
        var t = new DateTime(2026, 11, 9, 12, 0, 0, DateTimeKind.Utc);
        engine.Evaluate(Input(), t);

        t += DnsRuleEngine.SettleDelay;
        Assert.Equal("cloudflare", engine.Evaluate(Input(), t));

        // The write failed: DNS still reads as System Default.
        Assert.Null(engine.Evaluate(Input(), t.AddSeconds(4)));
        Assert.Equal("cloudflare", engine.Evaluate(Input(), t.AddSeconds(5)));

        t = t.AddSeconds(5);
        Assert.Null(engine.Evaluate(Input(), t.AddSeconds(9)));
        Assert.Equal("cloudflare", engine.Evaluate(Input(), t.AddSeconds(10)));
    }

    [Fact]
    public void Evaluate_ANewNetworkStartsOver()
    {
        var engine = new DnsRuleEngine();
        var t = new DateTime(2026, 11, 9, 12, 0, 0, DateTimeKind.Utc);
        engine.Evaluate(Input(), t);
        Assert.Equal("cloudflare", engine.Evaluate(Input(), t.AddSeconds(2)));

        var rules = new[] { new DnsRule { Ssid = "Home", PresetId = "cloudflare" }, new DnsRule { Ssid = "Office", PresetId = "quad9" } };
        Assert.Null(engine.Evaluate(Input(ssid: "Office", rules: rules), t.AddSeconds(3)));
        Assert.Equal("quad9", engine.Evaluate(Input(ssid: "Office", rules: rules), t.AddSeconds(5)));
    }

    [Theory]
    [InlineData(1, 5)]
    [InlineData(2, 10)]
    [InlineData(3, 20)]
    [InlineData(6, 160)]
    [InlineData(7, 300)]
    [InlineData(30, 300)]
    public void RetryDelay_DoublesUpToFiveMinutes(int attempts, int seconds)
        => Assert.Equal(TimeSpan.FromSeconds(seconds), DnsRuleEngine.RetryDelay(attempts));

    [Fact]
    public void Reset_ReturnsToOff()
    {
        var engine = new DnsRuleEngine();
        var changes = 0;
        engine.StateChanged += (_, _) => changes++;

        engine.Evaluate(Input(helper: false), DateTime.UtcNow);
        Assert.Equal(DnsAutoSwitchState.NeedsHelper, engine.State);

        engine.Reset();
        Assert.Equal(DnsAutoSwitchState.Off, engine.State);
        Assert.Equal(2, changes);
    }
}

/// <summary>Renamed built-in profiles and the rule settings (macOS 2.7).</summary>
public class DnsProfileSettingsTests
{
    private static DnsPreset Cloudflare => DnsPreset.BuiltIn.First(preset => preset.Id == "cloudflare");

    [Fact]
    public void RenamedBuiltIn_ShowsTheUsersName()
    {
        var settings = new AppSettings();
        settings.RenameDnsPreset("cloudflare", "  Home  ");

        Assert.Equal("Home", settings.DnsPresetDisplayName(Cloudflare));
        Assert.Equal("1.1.1.1", settings.AllDnsPresets().First(preset => preset.Id == "cloudflare").Servers[0]);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("Cloudflare")]
    public void BlankOrOriginalName_ClearsTheRename(string name)
    {
        var settings = new AppSettings();
        settings.RenameDnsPreset("cloudflare", "Home");
        settings.RenameDnsPreset("cloudflare", name);

        Assert.Empty(settings.DnsPresetCustomNames);
        Assert.Equal("Cloudflare", settings.DnsPresetDisplayName(Cloudflare));
    }

    [Fact]
    public void CustomProfiles_CannotBeRenamedThisWay()
    {
        var settings = new AppSettings();
        settings.AddDnsPreset("Mine", ["9.9.9.9"]);
        var mine = settings.CustomDnsPresets[0];

        settings.RenameDnsPreset(mine.Id, "Other");

        Assert.Empty(settings.DnsPresetCustomNames);
        Assert.Equal("Mine", settings.DnsPresetDisplayName(mine));
    }

    [Fact]
    public void Rename_RaisesOneChange()
    {
        var settings = new AppSettings();
        var raised = new List<string?>();
        settings.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        settings.RenameDnsPreset("google", "Work");
        settings.RenameDnsPreset("google", "Work");

        Assert.Equal([nameof(AppSettings.DnsPresetCustomNames)], raised);
    }

    [Fact]
    public void Rules_RoundTrip()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-dnsrules-{Guid.NewGuid():N}.json");
        try
        {
            var store = new SettingsStore(path);
            store.Batch(settings =>
            {
                settings.DnsAutoSwitchEnabled = true;
                settings.SetDnsRules([new DnsRule { Ssid = "Home", Bssid = "AA:BB:CC:DD:EE:FF", PresetId = "quad9" }]);
                settings.DnsRuleFallbackPresetId = "system";
                settings.RenameDnsPreset("quad9", "Office");
            });

            var reloaded = new SettingsStore(path).Settings;
            Assert.True(reloaded.DnsAutoSwitchEnabled);
            var rule = Assert.Single(reloaded.DnsRules);
            Assert.Equal(("Home", "AA:BB:CC:DD:EE:FF", "quad9", true), (rule.Ssid, rule.Bssid, rule.PresetId, rule.Enabled));
            Assert.Equal("system", reloaded.DnsRuleFallbackPresetId);
            Assert.Equal("Office", reloaded.DnsPresetCustomNames["quad9"]);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
