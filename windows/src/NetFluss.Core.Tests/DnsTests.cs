// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>
/// DNS presets and, more importantly, the validation in front of them.
///
/// <para>Applying DNS requires administrator rights, so these values are handed to a process
/// running elevated. <see cref="DnsValidator"/> is therefore a security boundary rather than
/// a convenience, and most of what follows is about what it must refuse.</para>
/// </summary>
public class DnsTests
{
    [Fact]
    public void BuiltIns_MatchTheMacOsList()
    {
        Assert.Equal(
            ["system", "cloudflare", "google", "quad9", "opendns"],
            DnsPreset.PlainBuiltIn.Select(p => p.Id));

        Assert.Equal(["1.1.1.1", "1.0.0.1"], DnsPreset.BuiltIn.Single(p => p.Id == "cloudflare").Servers);
        Assert.All(DnsPreset.BuiltIn, preset => Assert.True(preset.IsBuiltIn));

        // Plain first, then the encrypted eleven, as Models.swift lists them.
        Assert.Equal(DnsPreset.PlainBuiltIn.Concat(DnsPreset.EncryptedBuiltIn).Select(p => p.Id), DnsPreset.BuiltIn.Select(p => p.Id));
    }

    [Fact]
    public void SystemDefault_IsTheAutomaticOne()
    {
        Assert.True(DnsPreset.BuiltIn.Single(p => p.Id == "system").IsAutomatic);
        Assert.False(DnsPreset.BuiltIn.Single(p => p.Id == "google").IsAutomatic);
    }

    /// <summary>
    /// Windows may report resolvers in a different order from the one they were set in, and
    /// a checkmark that flickers off for that reason is worse than none.
    /// </summary>
    [Fact]
    public void Matching_IgnoresServerOrder()
    {
        var cloudflare = DnsPreset.BuiltIn.Single(p => p.Id == "cloudflare");

        Assert.True(cloudflare.Matches(["1.0.0.1", "1.1.1.1"]));
        Assert.True(cloudflare.Matches(["1.1.1.1", "1.0.0.1"]));
        Assert.False(cloudflare.Matches(["1.1.1.1"]));
        Assert.False(cloudflare.Matches(["8.8.8.8", "8.8.4.4"]));
    }

    [Fact]
    public void Automatic_MatchesOnlyAnEmptyList()
    {
        var system = DnsPreset.BuiltIn.Single(p => p.Id == "system");

        Assert.True(system.Matches([]));
        Assert.False(system.Matches(["1.1.1.1"]));
    }

    [Theory]
    [InlineData("1.1.1.1")]
    [InlineData("8.8.4.4")]
    [InlineData("2606:4700:4700::1111")]
    public void Validator_AcceptsRealAddresses(string server)
        => Assert.True(DnsValidator.Validate([server]).IsValid);

    /// <summary>
    /// The cases that matter: anything that could break out of a quoted argument on the
    /// elevated command line the applier builds.
    /// </summary>
    [Theory]
    [InlineData("1.1.1.1 && calc.exe")]
    [InlineData("1.1.1.1\" & shutdown /r")]
    [InlineData("; rm -rf /")]
    [InlineData("$(whoami)")]
    [InlineData("%SYSTEMROOT%")]
    [InlineData("not-an-address")]
    [InlineData("")]
    [InlineData("   ")]
    public void Validator_RefusesAnythingThatIsNotAnAddress(string server)
        => Assert.False(DnsValidator.Validate([server]).IsValid);

    /// <summary>
    /// TryParse accepts forms whose canonical text differs — "1.1" parses as 1.0.0.1 — and
    /// only the canonical form should ever reach a command line.
    /// </summary>
    [Fact]
    public void Validator_RefusesNonCanonicalForms()
    {
        Assert.False(DnsValidator.Validate(["1.1"]).IsValid);
        Assert.False(DnsValidator.Validate(["010.001.001.001"]).IsValid);
    }

    [Fact]
    public void Validator_RefusesDuplicatesAndOverlongLists()
    {
        Assert.False(DnsValidator.Validate(["1.1.1.1", "1.1.1.1"]).IsValid);
        Assert.False(DnsValidator.Validate([.. Enumerable.Range(1, 20).Select(i => $"10.0.0.{i}")]).IsValid);
    }

    [Fact]
    public void Parse_SplitsOnTheUsualSeparators()
    {
        Assert.Equal(["1.1.1.1", "1.0.0.1"], DnsValidator.Parse("1.1.1.1, 1.0.0.1"));
        Assert.Equal(["1.1.1.1", "1.0.0.1"], DnsValidator.Parse(" 1.1.1.1   1.0.0.1 "));
        Assert.Empty(DnsValidator.Parse("   "));
    }

    [Fact]
    public void CustomPresets_AreAppendedAfterTheBuiltIns()
    {
        var settings = new AppSettings();
        Assert.True(settings.AddDnsPreset("Work", ["10.0.0.1"]).IsValid);

        var all = settings.AllDnsPresets();

        Assert.Equal(DnsPreset.BuiltIn.Count + 1, all.Count);
        Assert.Equal("Work", all[^1].Name);
        Assert.False(all[^1].IsBuiltIn);
    }

    [Fact]
    public void CustomPresets_RejectBadInput()
    {
        var settings = new AppSettings();

        Assert.False(settings.AddDnsPreset("", ["1.1.1.1"]).IsValid);
        Assert.False(settings.AddDnsPreset("Empty", []).IsValid);
        Assert.False(settings.AddDnsPreset("Bad", ["nope"]).IsValid);
        Assert.Empty(settings.CustomDnsPresets);
    }

    /// <summary>A duplicate name would make the list ambiguous to the user, not just to us.</summary>
    [Fact]
    public void CustomPresets_RejectNamesAlreadyInUse()
    {
        var settings = new AppSettings();
        settings.AddDnsPreset("Work", ["10.0.0.1"]);

        Assert.False(settings.AddDnsPreset("work", ["10.0.0.2"]).IsValid);
        Assert.False(settings.AddDnsPreset("Cloudflare", ["10.0.0.2"]).IsValid);
        Assert.Single(settings.CustomDnsPresets);
    }

    [Fact]
    public void CustomPresets_SurviveAReload()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-dns-{Guid.NewGuid():N}.json");

        try
        {
            var store = new SettingsStore(path);
            store.Batch(settings => settings.AddDnsPreset("Work", ["10.0.0.1", "10.0.0.2"]));

            var reloaded = new SettingsStore(path).Settings;
            var preset = Assert.Single(reloaded.CustomDnsPresets);

            Assert.Equal("Work", preset.Name);
            Assert.Equal(["10.0.0.1", "10.0.0.2"], preset.Servers);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void RemovingAPreset_LeavesTheBuiltInsAlone()
    {
        var settings = new AppSettings();
        settings.AddDnsPreset("Work", ["10.0.0.1"]);

        settings.RemoveDnsPreset(settings.CustomDnsPresets[0].Id);

        Assert.Empty(settings.CustomDnsPresets);
        Assert.Equal(DnsPreset.BuiltIn.Count, settings.AllDnsPresets().Count);
    }
}
