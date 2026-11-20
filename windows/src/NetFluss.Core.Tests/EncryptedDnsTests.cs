// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>
/// Encrypted DNS — the validation in front of it first, since its values reach a LocalSystem
/// service and, for DoT, a netsh command line; then the presets, the read-back state, the
/// settings file and the helper messages.
/// </summary>
public class EncryptedDnsValidatorTests
{
    [Theory]
    [InlineData("https://cloudflare-dns.com/dns-query")]
    [InlineData("https://dns.google/dns-query")]
    [InlineData("https://dns.example.com:8443/dns-query")]
    [InlineData("https://dns.example.com")]
    [InlineData("  https://dns.example.com/dns-query  ")]
    public void DohUrl_AcceptsRealTemplates(string url)
        => Assert.Equal(url.Trim(), EncryptedDnsValidator.NormalizeDohUrl(url));

    /// <summary>
    /// Everything that is not a host and a path, and everything that could mean something to
    /// a parser further down: credentials, queries, fragments, escapes, quotes, whitespace.
    /// </summary>
    [Theory]
    [InlineData("http://dns.example.com/dns-query")]
    [InlineData("ftp://dns.example.com/dns-query")]
    [InlineData("dns.example.com/dns-query")]
    [InlineData("https://user:secret@dns.example.com/dns-query")]
    [InlineData("https://user@dns.example.com/dns-query")]
    [InlineData("https://dns.example.com/dns-query?dns=AAABAAAB")]
    [InlineData("https://dns.example.com/dns-query#fragment")]
    [InlineData("https://dns.example.com/dns-query{?dns}")]
    [InlineData("https://dns.example.com/dns%20query")]
    [InlineData("https://dns.example.com/%2e%2e/")]
    [InlineData("https://dns.example.com/dns query")]
    [InlineData("https://dns.example.com/dns-query\" & shutdown /r")]
    [InlineData("https://dns.example.com/dns-query\"")]
    [InlineData("https://dns.example.com/a\\b")]
    [InlineData("https://dns.example.com/dns\n-query")]
    [InlineData("https://dns.example.com/\tquery")]
    [InlineData("https://dns.example.com/\u0000")]
    [InlineData("https://dnß.example.com/dns-query")]
    [InlineData("https://localhost/dns-query")]
    [InlineData("https://-dns.example.com/dns-query")]
    [InlineData("https://dns..example.com/dns-query")]
    [InlineData("https://1.1/dns-query")]
    [InlineData("https:///dns-query")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public void DohUrl_RefusesEverythingElse(string? url)
        => Assert.Null(EncryptedDnsValidator.NormalizeDohUrl(url));

    [Fact]
    public void DohUrl_HasALengthLimit()
    {
        var path = new string('a', EncryptedDnsValidator.MaximumUrlLength);
        Assert.Null(EncryptedDnsValidator.NormalizeDohUrl($"https://dns.example.com/{path}"));
    }

    [Theory]
    [InlineData("dns.google", "dns.google")]
    [InlineData("one.one.one.one", "one.one.one.one")]
    [InlineData("  DNS.Example.COM. ", "dns.example.com")]
    [InlineData("dns-1.example.com", "dns-1.example.com")]
    public void DotHost_IsNormalised(string raw, string expected)
        => Assert.Equal(expected, EncryptedDnsValidator.NormalizeDotHost(raw));

    /// <summary>The host is one netsh argument, "dothost=host:853": nothing but a host name may get there.</summary>
    [Theory]
    [InlineData("1.1.1.1")]
    [InlineData("2606:4700:4700::1111")]
    [InlineData("[2606:4700:4700::1111]")]
    [InlineData("dns")]
    [InlineData("dns.example.com:853")]
    [InlineData("dns.example.com\" & calc")]
    [InlineData("dns.example.com;calc")]
    [InlineData("dns.example.com dothost=evil.com")]
    [InlineData("dns.example.com/x")]
    [InlineData("%41.example.com")]
    [InlineData("-dns.example.com")]
    [InlineData("dns-.example.com")]
    [InlineData("dns..example.com")]
    [InlineData("user@dns.example.com")]
    [InlineData("dnß.example.com")]
    [InlineData("")]
    [InlineData(null)]
    public void DotHost_RefusesEverythingElse(string? host)
        => Assert.Null(EncryptedDnsValidator.NormalizeDotHost(host));

    [Fact]
    public void DotHost_HasLabelAndLengthLimits()
    {
        Assert.Null(EncryptedDnsValidator.NormalizeDotHost(new string('a', 64) + ".example.com"));
        Assert.NotNull(EncryptedDnsValidator.NormalizeDotHost(new string('a', 63) + ".example.com"));

        var longName = string.Join('.', Enumerable.Repeat(new string('a', 60), 5));
        Assert.True(longName.Length > EncryptedDnsValidator.MaximumHostLength);
        Assert.Null(EncryptedDnsValidator.NormalizeDotHost(longName));
    }

    /// <summary>Windows connects to the IP and never looks the DoH or DoT host up: no IP, nothing to dial.</summary>
    [Theory]
    [InlineData(DnsTransport.Https, "https://dns.example.com/dns-query")]
    [InlineData(DnsTransport.Tls, "dns.example.com")]
    public void Preset_NeedsAtLeastOneServer(DnsTransport transport, string endpoint)
    {
        Assert.False(EncryptedDnsValidator.Validate(transport, endpoint, []).IsValid);
        Assert.True(EncryptedDnsValidator.Validate(transport, endpoint, ["1.1.1.1"]).IsValid);
    }

    [Theory]
    [InlineData("1.1")]
    [InlineData("1.1.1.1 && calc.exe")]
    [InlineData("not-an-address")]
    public void Preset_ServersFollowTheDnsRules(string server)
        => Assert.False(EncryptedDnsValidator.Validate(DnsTransport.Tls, "dns.example.com", [server]).IsValid);

    /// <summary>The endpoint must already be in its checked form, like server addresses.</summary>
    [Fact]
    public void Preset_RefusesAnEndpointThatIsNotNormalised()
    {
        Assert.False(EncryptedDnsValidator.Validate(DnsTransport.Tls, "DNS.example.com", ["1.1.1.1"]).IsValid);
        Assert.False(EncryptedDnsValidator.Validate(DnsTransport.Https, " https://dns.example.com/dns-query", ["1.1.1.1"]).IsValid);
        Assert.False(EncryptedDnsValidator.Validate(DnsTransport.Https, null, ["1.1.1.1"]).IsValid);
        Assert.False(EncryptedDnsValidator.Validate((DnsTransport)0, "dns.example.com", ["1.1.1.1"]).IsValid);
    }

    /// <summary>Windows refuses a template whose host is an IP other than its server's.</summary>
    [Fact]
    public void IpInTheUrl_MustBeTheOnlyServer()
    {
        Assert.True(EncryptedDnsValidator.Validate(DnsTransport.Https, "https://1.1.1.1/dns-query", ["1.1.1.1"]).IsValid);
        Assert.True(EncryptedDnsValidator.Validate(DnsTransport.Https, "https://[2606:4700:4700::1111]/dns-query", ["2606:4700:4700::1111"]).IsValid);
        Assert.False(EncryptedDnsValidator.Validate(DnsTransport.Https, "https://1.1.1.1/dns-query", ["1.1.1.1", "1.0.0.1"]).IsValid);
        Assert.False(EncryptedDnsValidator.Validate(DnsTransport.Https, "https://1.1.1.1/dns-query", ["8.8.8.8"]).IsValid);
    }

    [Fact]
    public void EveryEncryptedBuiltIn_Validates()
        => Assert.All(DnsPreset.EncryptedBuiltIn, preset => Assert.True(EncryptedDnsValidator.Validate(preset).IsValid, preset.Id));
}

public class EncryptedDnsCapabilityTests
{
    [Fact]
    public void Windows10_HasNeither()
    {
        var capabilities = EncryptedDnsCapabilities.Evaluate(19045, null, dotRuntime: false);
        Assert.False(capabilities.Doh);
        Assert.False(capabilities.Dot);
        Assert.Equal(EncryptedDnsBlock.NeedsWindows11, capabilities.BlockFor(DnsTransport.Https));
        Assert.Equal(EncryptedDnsBlock.NeedsWindows11, capabilities.BlockFor(DnsTransport.Tls));
    }

    [Fact]
    public void Windows11BeforeVersion24H2_HasDohOnly()
    {
        var capabilities = EncryptedDnsCapabilities.Evaluate(22631, null, dotRuntime: true);
        Assert.True(capabilities.Doh);
        Assert.False(capabilities.Dot);
        Assert.Equal(EncryptedDnsBlock.None, capabilities.BlockFor(DnsTransport.Https));
        Assert.Equal(EncryptedDnsBlock.NeedsWindows11Version24H2, capabilities.BlockFor(DnsTransport.Tls));
    }

    [Fact]
    public void Version24H2_HasBoth_WhenNetshAgrees()
    {
        Assert.True(EncryptedDnsCapabilities.Evaluate(26100, null, dotRuntime: true).Supports(DnsTransport.Tls));

        var noNetsh = EncryptedDnsCapabilities.Evaluate(26100, null, dotRuntime: false);
        Assert.True(noNetsh.Doh);
        Assert.False(noNetsh.Dot);
        Assert.Equal(EncryptedDnsBlock.NotOnThisPc, noNetsh.BlockFor(DnsTransport.Tls));
    }

    /// <summary>"Prohibit DoH" stops both; "allow" and "require" are what NetFluss wants anyway.</summary>
    [Theory]
    [InlineData(1, false)]
    [InlineData(2, true)]
    [InlineData(3, true)]
    public void DohPolicy_OnlyProhibitBlocks(int policy, bool allowed)
    {
        var capabilities = EncryptedDnsCapabilities.Evaluate(26100, policy, dotRuntime: true);
        Assert.Equal(allowed, capabilities.Doh);
        Assert.Equal(allowed, capabilities.Dot);
        if (!allowed)
        {
            Assert.Equal(EncryptedDnsBlock.Policy, capabilities.BlockFor(DnsTransport.Https));
        }
    }

    [Fact]
    public void None_SupportsNothing()
    {
        Assert.False(EncryptedDnsCapabilities.None.Supports(DnsTransport.Https));
        Assert.False(EncryptedDnsCapabilities.None.Supports(DnsTransport.Tls));
        Assert.False(EncryptedDnsCapabilities.None.Supports(null));
    }
}

public class EncryptedDnsPresetTests
{
    private static DnsPreset Preset(string id) => DnsPreset.BuiltIn.Single(preset => preset.Id == id);

    [Fact]
    public void EncryptedBuiltIns_MatchTheMacOsList()
    {
        Assert.Equal(
            [
                "cloudflare-doh", "cloudflare-dot", "google-doh", "google-dot", "quad9-doh", "quad9-dot",
                "opendns-doh", "mullvad-doh", "mullvad-dot", "adguard-doh", "adguard-dot",
            ],
            DnsPreset.EncryptedBuiltIn.Select(preset => preset.Id));

        Assert.All(DnsPreset.EncryptedBuiltIn, preset => Assert.True(preset.IsBuiltIn && preset.IsEncrypted));
        Assert.DoesNotContain(DnsPreset.BuiltIn, preset => preset.Id == "opendns-dot");

        var cloudflare = Preset("cloudflare-doh");
        Assert.Equal(DnsTransport.Https, cloudflare.Transport);
        Assert.Equal("https://cloudflare-dns.com/dns-query", cloudflare.Endpoint);
        Assert.Equal(["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"], cloudflare.Servers);
        Assert.Equal(new DnsEncryption(DnsTransport.Tls, "dns.adguard-dns.com"), Preset("adguard-dot").Encryption);
        Assert.Equal(["194.242.2.2", "2a07:e340::2"], Preset("mullvad-dot").Servers);
    }

    /// <summary>The addresses are the same; the resolvers are not.</summary>
    [Fact]
    public void PlainAndEncrypted_WithTheSameAddresses_AreDifferent()
    {
        string[] servers = ["1.1.1.1", "1.0.0.1"];
        var plain = new DnsPreset { Id = "x", Name = "X", Servers = servers };
        var doh = plain with { Transport = DnsTransport.Https, Endpoint = "https://cloudflare-dns.com/dns-query" };
        var dot = plain with { Transport = DnsTransport.Tls, Endpoint = "one.one.one.one" };

        Assert.NotEqual(plain, doh);
        Assert.NotEqual(doh, dot);
        Assert.Null(plain.Encryption);

        var plainState = DnsAdapterState.Plain(servers);
        var dohState = new DnsAdapterState(servers, new DnsEncryption(DnsTransport.Https, "https://cloudflare-dns.com/dns-query"));

        Assert.True(plain.Matches(plainState));
        Assert.False(plain.Matches(dohState));
        Assert.True(doh.Matches(dohState));
        Assert.False(doh.Matches(plainState));
        Assert.False(dot.Matches(dohState));

        Assert.Equal("x", DnsPreset.ActiveId([doh, dot, plain], plainState));
    }

    [Fact]
    public void Matching_IgnoresEndpointCase_ButNotAMixedAdapter()
    {
        var doh = Preset("google-doh");
        var state = new DnsAdapterState(doh.Servers, new DnsEncryption(DnsTransport.Https, "HTTPS://DNS.GOOGLE/dns-query"));
        Assert.True(doh.Matches(state));
        Assert.False(doh.Matches(state with { Mixed = true }));
    }
}

/// <summary>What the adapter has, put together from Windows' per-server DoH and NetFluss's DoT entries.</summary>
public class DnsAdapterStateTests
{
    private const string Template = "https://cloudflare-dns.com/dns-query";
    private static readonly string[] Servers = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111"];
    private static readonly Dictionary<string, string> NoDot = [];

    private static DohServerSetting Doh(string server, ulong flags = DohServerSetting.FlagEnable, string? template = Template)
        => new(server, template, flags);

    [Fact]
    public void NothingEncrypted_IsPlain()
    {
        var state = DnsAdapterState.Compose(Servers, [Doh("1.1.1.1", flags: 0)], NoDot);
        Assert.Null(state.Encryption);
        Assert.False(state.Mixed);
        Assert.Equal(Servers, state.Servers);
    }

    [Fact]
    public void EveryServerEncryptedOnly_IsDoh()
    {
        var state = DnsAdapterState.Compose(Servers, [.. Servers.Select(server => Doh(server))], NoDot);
        Assert.Equal(new DnsEncryption(DnsTransport.Https, Template), state.Encryption);
        Assert.False(state.Mixed);
    }

    /// <summary>"Encrypted preferred, unencrypted allowed" is not what any NetFluss preset sets.</summary>
    [Fact]
    public void FallbackToPlain_IsMixed()
    {
        var state = DnsAdapterState.Compose(
            Servers,
            [.. Servers.Select(server => Doh(server, DohServerSetting.FlagEnable | DohServerSetting.FlagFallbackToUdp))],
            NoDot);
        Assert.True(state.Mixed);
        Assert.Null(state.Encryption);
    }

    [Fact]
    public void SomeServersEncrypted_IsMixed()
        => Assert.True(DnsAdapterState.Compose(Servers, [Doh("1.1.1.1")], NoDot).Mixed);

    [Fact]
    public void DifferentTemplates_AreMixed()
        => Assert.True(DnsAdapterState.Compose(
            ["1.1.1.1", "1.0.0.1"],
            [Doh("1.1.1.1"), Doh("1.0.0.1", template: "https://other.example/dns-query")],
            NoDot).Mixed);

    /// <summary>A family Windows would not report is left out, not counted as plain.</summary>
    [Fact]
    public void AnUnreadableFamily_DoesNotSpoilTheRest()
    {
        var state = DnsAdapterState.Compose(Servers, [Doh("1.1.1.1"), Doh("1.0.0.1")], NoDot, ipv4Known: true, ipv6Known: false);
        Assert.Equal(DnsTransport.Https, state.Encryption?.Transport);
    }

    [Fact]
    public void NetFlussDotOnEveryServer_IsDot()
    {
        var dot = Servers.ToDictionary(server => server, _ => "one.one.one.one");
        var state = DnsAdapterState.Compose(Servers, [], dot);
        Assert.Equal(new DnsEncryption(DnsTransport.Tls, "one.one.one.one"), state.Encryption);

        dot.Remove("1.0.0.1");
        Assert.True(DnsAdapterState.Compose(Servers, [], dot).Mixed);
    }

    [Fact]
    public void Dhcp_IsAlwaysPlain()
        => Assert.Null(DnsAdapterState.Compose([], [Doh("1.1.1.1")], NoDot).Encryption);
}

public class EncryptedDnsSettingsTests
{
    [Fact]
    public void EncryptedCustomPreset_IsNormalisedAndKept()
    {
        var settings = new AppSettings();
        var result = settings.AddDnsPreset("My DoT", ["9.9.9.9"], DnsTransport.Tls, "  DNS.Quad9.NET ");

        Assert.True(result.IsValid, result.Error);
        var preset = Assert.Single(settings.CustomDnsPresets);
        Assert.Equal("dns.quad9.net", preset.Endpoint);
        Assert.Equal(DnsTransport.Tls, preset.Transport);
        Assert.Contains(settings.AllDnsPresets(), p => p.Id == preset.Id);
    }

    [Fact]
    public void EncryptedCustomPreset_RejectsBadInput()
    {
        var settings = new AppSettings();

        Assert.False(settings.AddDnsPreset("No IP", [], DnsTransport.Https, "https://dns.example.com/dns-query").IsValid);
        Assert.False(settings.AddDnsPreset("Bad URL", ["1.1.1.1"], DnsTransport.Https, "https://dns.example.com/q?x=1").IsValid);
        Assert.False(settings.AddDnsPreset("Bad host", ["1.1.1.1"], DnsTransport.Tls, "1.1.1.1").IsValid);
        Assert.Empty(settings.CustomDnsPresets);
    }

    /// <summary>A hand-edited preset that no longer validates is not offered: nothing could apply it.</summary>
    [Fact]
    public void BrokenEncryptedCustomPreset_IsLeftOut()
    {
        var settings = new AppSettings
        {
            CustomDnsPresets =
            [
                new DnsPreset { Id = "custom-a", Name = "A", Servers = ["1.1.1.1"], Transport = DnsTransport.Tls, Endpoint = "evil\" & calc" },
                new DnsPreset { Id = "custom-b", Name = "B", Servers = ["1.1.1.1"], Transport = (DnsTransport)0, Endpoint = "dns.example.com" },
                new DnsPreset { Id = "custom-c", Name = "C", Servers = ["1.1.1.1"] },
            ],
        };

        Assert.Equal(["custom-c"], settings.AllDnsPresets().Where(p => !p.IsBuiltIn).Select(p => p.Id));
    }

    /// <summary>A settings file from before encrypted DNS loads unchanged: its presets are plain.</summary>
    [Fact]
    public void OldSettingsFile_LoadsUnchanged()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-old-dns-{Guid.NewGuid():N}.json");
        try
        {
            File.WriteAllText(path, """
                {
                  "CustomDnsPresets": [
                    { "Id": "custom-1", "Name": "Work", "Servers": [ "10.0.0.1" ], "IsBuiltIn": false, "IsAutomatic": false }
                  ],
                  "HiddenDnsPresets": [ "google" ],
                  "DnsPresetOrder": [ "quad9" ],
                  "DnsRules": [ { "Id": "r", "Ssid": "Home", "PresetId": "custom-1", "Enabled": true } ]
                }
                """);

            var settings = new SettingsStore(path).Settings;
            var preset = Assert.Single(settings.CustomDnsPresets);
            Assert.Equal(("custom-1", "Work"), (preset.Id, preset.Name));
            Assert.Null(preset.Transport);
            Assert.Null(preset.Endpoint);
            Assert.False(preset.IsEncrypted);
            Assert.Equal(["google"], settings.HiddenDnsPresets);
            Assert.Empty(settings.DnsSeenEncryptedBuiltIns);
            Assert.Equal("custom-1", Assert.Single(settings.DnsRules).PresetId);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void EncryptedCustomPreset_SurvivesAReload()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-dns-encrypted-{Guid.NewGuid():N}.json");
        try
        {
            var store = new SettingsStore(path);
            store.Batch(settings => settings.AddDnsPreset("Mine", ["94.140.14.14"], DnsTransport.Https, "https://dns.adguard-dns.com/dns-query"));

            var preset = Assert.Single(new SettingsStore(path).Settings.CustomDnsPresets);
            Assert.Equal(new DnsEncryption(DnsTransport.Https, "https://dns.adguard-dns.com/dns-query"), preset.Encryption);
            Assert.Contains("\"Https\"", File.ReadAllText(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    /// <summary>Hidden once each: a later "show" in Preferences sticks, and nothing new is hidden twice.</summary>
    [Fact]
    public void NewEncryptedBuiltIns_AreHiddenOnce()
    {
        var settings = new AppSettings();
        settings.SetDnsPresetHidden("google", true);
        Assert.True(settings.HasUnseenEncryptedDnsBuiltIns);

        settings.HideNewEncryptedDnsBuiltIns();

        Assert.False(settings.HasUnseenEncryptedDnsBuiltIns);
        Assert.All(DnsPreset.EncryptedBuiltIn, preset => Assert.Contains(preset.Id, settings.HiddenDnsPresets));
        Assert.Contains("google", settings.HiddenDnsPresets);
        Assert.Equal(DnsPreset.PlainBuiltIn.Count - 1, settings.VisibleDnsPresets().Count);

        settings.SetDnsPresetHidden("quad9-dot", false);
        var raised = new List<string?>();
        settings.PropertyChanged += (_, e) => raised.Add(e.PropertyName);
        settings.HideNewEncryptedDnsBuiltIns();

        Assert.Empty(raised);
        Assert.DoesNotContain("quad9-dot", settings.HiddenDnsPresets);
        Assert.Equal(DnsPreset.EncryptedBuiltIn.Count, settings.DnsSeenEncryptedBuiltIns.Count);
    }

    [Fact]
    public void SeenBuiltIns_SurviveAReload()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-dns-seen-{Guid.NewGuid():N}.json");
        try
        {
            var store = new SettingsStore(path);
            store.Batch(settings => settings.HideNewEncryptedDnsBuiltIns());

            var reloaded = new SettingsStore(path).Settings;
            Assert.False(reloaded.HasUnseenEncryptedDnsBuiltIns);
            Assert.Contains("cloudflare-doh", reloaded.HiddenDnsPresets);
        }
        finally
        {
            File.Delete(path);
        }
    }
}

/// <summary>The rule engine's encrypted-DNS states (macOS 2.7 <c>DNSRuleEngine</c>, Windows edition).</summary>
public class EncryptedDnsRuleTests
{
    private const string Url = "https://cloudflare-dns.com/dns-query";
    private static readonly DnsEncryption CloudflareDoh = new(DnsTransport.Https, Url);
    private static readonly string[] Cloudflare = ["1.1.1.1", "1.0.0.1"];

    private static readonly Dictionary<string, IReadOnlyList<string>> Servers = new()
    {
        ["system"] = [],
        ["cloudflare"] = Cloudflare,
        ["cloudflare-doh"] = Cloudflare,
        ["google-dot"] = ["8.8.8.8"],
    };

    private static readonly Dictionary<string, DnsEncryption> Encryption = new()
    {
        ["cloudflare-doh"] = CloudflareDoh,
        ["google-dot"] = new DnsEncryption(DnsTransport.Tls, "dns.google"),
    };

    private static DnsRuleInput Input(
        string target = "cloudflare-doh",
        string? ssid = "Home",
        string? active = "system",
        IReadOnlyList<string>? current = null,
        DnsEncryption? currentEncryption = null,
        EncryptedDnsCapabilities? capabilities = null,
        LinkHealth? health = LinkHealth.Online,
        string? manual = null) => new()
    {
        Enabled = true,
        HelperEnabled = true,
        Ssid = ssid,
        LinkHealth = health,
        PortalSignalAvailable = true,
        ActivePresetId = active,
        CurrentServers = current ?? [],
        CurrentEncryption = currentEncryption,
        PresetServers = Servers,
        PresetEncryption = Encryption,
        Capabilities = capabilities ?? EncryptedDnsCapabilities.Evaluate(26100, null, dotRuntime: true),
        Rules = [new DnsRule { Ssid = "Home", PresetId = target }],
        FallbackPresetId = target,
        ManualOverrideNetwork = manual,
    };

    [Fact]
    public void EncryptedTarget_Applies()
        => Assert.Equal("cloudflare-doh", DnsRuleEngine.Decide(Input()).ApplyPresetId);

    /// <summary>Held, not downgraded: plain DNS would quietly undo what the rule is for.</summary>
    [Fact]
    public void UnavailableTransport_Holds()
    {
        var windows10 = DnsRuleEngine.Decide(Input(capabilities: EncryptedDnsCapabilities.Evaluate(19045, null, false)));
        Assert.Null(windows10.ApplyPresetId);
        Assert.Equal(DnsAutoSwitchState.EncryptedDnsUnavailable("cloudflare-doh"), windows10.State);

        var noDot = DnsRuleEngine.Decide(Input(target: "google-dot", capabilities: EncryptedDnsCapabilities.Evaluate(22631, null, true)));
        Assert.Equal(DnsAutoSwitchKind.EncryptedDnsUnavailable, noDot.State.Kind);

        // A helper that cannot set encrypted DNS at all.
        Assert.Equal(DnsAutoSwitchKind.EncryptedDnsUnavailable, DnsRuleEngine.Decide(Input(capabilities: EncryptedDnsCapabilities.None)).State.Kind);
    }

    /// <summary>"Applied" compares servers and encryption, not servers alone.</summary>
    [Fact]
    public void Applied_ComparesEncryptionToo()
    {
        var encryptedLive = Input(active: null, current: Cloudflare, currentEncryption: CloudflareDoh);
        Assert.Equal(DnsAutoSwitchState.Applied("Home", "cloudflare-doh"), DnsRuleEngine.Decide(encryptedLive).State);
        Assert.Null(DnsRuleEngine.Decide(encryptedLive).ApplyPresetId);

        // Same servers in plain text: the DoH rule still has work to do…
        Assert.Equal("cloudflare-doh", DnsRuleEngine.Decide(Input(active: null, current: Cloudflare)).ApplyPresetId);

        // …and so does a plain rule while the same servers are encrypted.
        Assert.Equal("cloudflare", DnsRuleEngine.Decide(Input(target: "cloudflare", active: null, current: Cloudflare, currentEncryption: CloudflareDoh)).ApplyPresetId);

        // An adapter encrypted in a way no preset describes is never "applied".
        var mixed = Input(target: "cloudflare", active: null, current: Cloudflare) with { CurrentEncryptionMixed = true };
        Assert.Equal("cloudflare", DnsRuleEngine.Decide(mixed).ApplyPresetId);
    }

    /// <summary>An encrypted resolver cannot reach a captive portal: the same servers go plain meanwhile.</summary>
    [Fact]
    public void CaptivePortal_PausesEncryption()
    {
        var paused = DnsRuleEngine.Decide(Input(health: LinkHealth.Limited, active: "cloudflare-doh", current: Cloudflare, currentEncryption: CloudflareDoh));
        Assert.True(paused.PauseEncryption);
        Assert.Null(paused.ApplyPresetId);
        Assert.Equal(DnsAutoSwitchState.WaitingForPortal("Home"), paused.State);

        var plain = DnsRuleEngine.Decide(Input(health: LinkHealth.Limited));
        Assert.False(plain.PauseEncryption);
        Assert.Equal(DnsAutoSwitchState.WaitingForPortal("Home"), plain.State);
    }

    [Fact]
    public void Next_DebouncesThePause()
    {
        var engine = new DnsRuleEngine();
        var t = new DateTime(2026, 11, 20, 12, 0, 0, DateTimeKind.Utc);
        var input = Input(health: LinkHealth.Limited, active: "cloudflare-doh", current: Cloudflare, currentEncryption: CloudflareDoh);

        Assert.Null(engine.Next(input, t));
        Assert.Equal(new DnsRuleAction(null, PauseEncryption: true), engine.Next(input, t + DnsRuleEngine.SettleDelay));
        Assert.Null(engine.Next(input, t + DnsRuleEngine.SettleDelay + TimeSpan.FromSeconds(1)));

        // The pause is not a preset, so the preset-only view reads it as nothing to apply —
        // though it was decided, and published as the state.
        var presetsOnly = new DnsRuleEngine();
        presetsOnly.Evaluate(input, t);
        Assert.Null(presetsOnly.Evaluate(input, t + DnsRuleEngine.SettleDelay));
        Assert.Equal(DnsAutoSwitchState.WaitingForPortal("Home"), presetsOnly.State);
    }

    [Fact]
    public void Next_AppliesTheEncryptedPreset()
    {
        var engine = new DnsRuleEngine();
        var t = new DateTime(2026, 11, 20, 12, 0, 0, DateTimeKind.Utc);
        engine.Next(Input(), t);
        Assert.Equal(new DnsRuleAction("cloudflare-doh"), engine.Next(Input(), t + DnsRuleEngine.SettleDelay));
    }

    /// <summary>A hand pick holds on the network it was made on, wired included.</summary>
    [Fact]
    public void ManualOverride_HoldsOnThatNetwork()
    {
        Assert.Equal(DnsAutoSwitchState.ManualOverride("Home"), DnsRuleEngine.Decide(Input(manual: "Home")).State);
        Assert.Null(DnsRuleEngine.Decide(Input(manual: "Home")).ApplyPresetId);
        Assert.Equal(DnsAutoSwitchState.ManualOverride(string.Empty), DnsRuleEngine.Decide(Input(ssid: null, manual: string.Empty)).State);

        // Another network: the rules apply again.
        Assert.Equal("cloudflare-doh", DnsRuleEngine.Decide(Input(ssid: "Office", manual: "Home")).ApplyPresetId);
    }

    /// <summary>The VPN hold stays first: it is about whose resolvers are in charge, not about this network.</summary>
    [Fact]
    public void VpnHold_StillComesFirst()
        => Assert.Equal(DnsAutoSwitchState.SuspendedByVpn, DnsRuleEngine.Decide(Input(manual: "Home") with { VpnDnsActive = true }).State);

    [Theory]
    [InlineData("Home", "Home", true, "Home")]
    [InlineData("Home", "Office", true, null)]
    [InlineData("Home", null, true, null)]
    [InlineData("", null, true, "")]
    [InlineData("", "Cafe", true, null)]
    // A Wi-Fi drop or re-association reads as no network for a moment; it must not clear the pick.
    [InlineData("Home", null, false, "Home")]
    [InlineData("Home", "Office", false, "Home")]
    [InlineData(null, "Home", true, null)]
    public void ManualOverride_ClearsOnlyOnAnotherNetworkThatIsUp(string? stored, string? ssid, bool up, string? expected)
        => Assert.Equal(expected, DnsRuleEngine.CurrentManualOverride(stored, ssid, up));
}

public class EncryptedDnsHelperProtocolTests
{
    [Fact]
    public void Version_IsAtLeastThree()
        => Assert.True(HelperProtocol.Version >= 3);

    [Fact]
    public void EncryptedSetDns_RoundTrips()
    {
        var line = HelperProtocol.Serialize(new HelperRequest
        {
            Op = "setDns",
            Id = 4,
            Adapter = "{x}",
            Servers = ["8.8.8.8", "8.8.4.4"],
            Transport = DnsTransports.ToWire(DnsTransport.Tls),
            Endpoint = "dns.google",
        });

        Assert.Contains("\"transport\":\"dot\"", line);
        Assert.Contains("\"endpoint\":\"dns.google\"", line);

        var back = HelperProtocol.Deserialize<HelperRequest>(line)!;
        Assert.Equal(DnsTransport.Tls, DnsTransports.FromWire(back.Transport));
        Assert.Equal("dns.google", back.Endpoint);
        Assert.Equal(["8.8.8.8", "8.8.4.4"], back.Servers);
    }

    /// <summary>A plain request leaves the new fields out, so it reads the same to an older helper.</summary>
    [Fact]
    public void PlainSetDns_CarriesNoTransport()
    {
        var line = HelperProtocol.Serialize(new HelperRequest { Op = "setDns", Adapter = "{x}", Servers = ["1.1.1.1"] });
        Assert.DoesNotContain("transport", line);
        Assert.DoesNotContain("endpoint", line);
        Assert.Null(HelperProtocol.Deserialize<HelperRequest>(line)!.Transport);
    }

    [Fact]
    public void Reply_RoundTripsCapabilitiesAndDotServers()
    {
        var capabilities = EncryptedDnsCapabilities.Evaluate(26100, null, dotRuntime: true);
        var line = HelperProtocol.Serialize(new HelperMessage
        {
            Type = "result",
            Id = 9,
            Ok = true,
            Capabilities = capabilities,
            DotServers = [new HelperDotServer("1.1.1.1", "one.one.one.one")],
        });

        var back = HelperProtocol.Deserialize<HelperMessage>(line)!;
        Assert.Equal(capabilities, back.Capabilities);
        var server = Assert.Single(back.DotServers!);
        Assert.Equal(("1.1.1.1", "one.one.one.one"), (server.Server, server.Host));
    }

    /// <summary>A protocol-2 helper's hello has none of it, and reads as "not supported".</summary>
    [Fact]
    public void OlderHello_ReadsWithoutCapabilities()
    {
        var hello = HelperProtocol.Deserialize<HelperMessage>("""{"type":"hello","version":2,"helperVersion":"2.7.2"}""")!;
        Assert.Null(hello.Capabilities);
        Assert.Null(hello.DotServers);
    }

    [Theory]
    [InlineData("doq")]
    [InlineData("DoH")]
    [InlineData("")]
    [InlineData(null)]
    public void UnknownTransport_IsRefused(string? wire)
        => Assert.Null(DnsTransports.FromWire(wire));
}
