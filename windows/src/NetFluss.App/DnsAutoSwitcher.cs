// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using NetFluss.Core.Vpn;

namespace NetFluss.App;

/// <summary>
/// Automatic DNS by Wi-Fi network (macOS 2.7): gathers what <see cref="DnsRuleEngine"/>
/// needs on every tick and applies its answer through the helper.
///
/// <para>Rules act on the adapter the DNS switcher acts on — the one carrying the internet
/// connection unless the user picked another — so the popover's checkmark, the resolver
/// label and the rules always agree about which adapter is meant. The network name comes
/// from that same adapter: on a cable there is no SSID and only the catch-all applies.</para>
/// </summary>
internal sealed class DnsAutoSwitcher
{
    private readonly SettingsStore _store;
    private readonly NetworkMonitorService _monitor;
    private readonly DnsSwitcher _dns;
    private readonly LinkHealthService _link;
    private readonly PrivilegedActions _privileged;
    private readonly Func<VpnStatus> _vpnStatus;
    private readonly Func<IReadOnlyList<VpnProfile>> _vpnProfiles;
    private readonly DnsRuleEngine _engine = new();
    private bool _applying;

    internal DnsAutoSwitcher(
        SettingsStore store,
        NetworkMonitorService monitor,
        DnsSwitcher dns,
        LinkHealthService link,
        PrivilegedActions privileged,
        Func<VpnStatus> vpnStatus,
        Func<IReadOnlyList<VpnProfile>> vpnProfiles)
    {
        _store = store;
        _monitor = monitor;
        _dns = dns;
        _link = link;
        _privileged = privileged;
        _vpnStatus = vpnStatus;
        _vpnProfiles = vpnProfiles;
        _engine.StateChanged += (_, _) => Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Raised when <see cref="State"/> changes, for Preferences to explain itself.</summary>
    internal event EventHandler? Changed;

    internal DnsAutoSwitchState State => _engine.State;

    /// <summary>
    /// The Wi-Fi network the rules see right now — for "Add current network". Null on a cable
    /// or with no association.
    /// </summary>
    internal (string Ssid, string? Bssid)? CurrentNetwork
        => Target() is { Type: AdapterType.WiFi, IsUp: true, WifiSsid: { Length: > 0 } ssid } adapter
            ? (ssid, adapter.Wifi?.Bssid)
            : null;

    /// <summary>Runs the table once. Called on every monitor tick; cheap when nothing changes.</summary>
    internal void Evaluate()
    {
        var settings = _store.Settings;
        if (!settings.DnsAutoSwitchEnabled)
        {
            if (_engine.State != DnsAutoSwitchState.Off)
            {
                _engine.Reset();
            }

            return;
        }

        if (_applying || _dns.IsApplying)
        {
            return;
        }

        var network = CurrentNetwork;
        var presets = settings.AllDnsPresets();
        var input = new DnsRuleInput
        {
            Enabled = true,
            HelperEnabled = _privileged.IsSilent,
            Ssid = network?.Ssid,
            Bssid = network?.Bssid,
            LinkHealth = _link.Status?.Health,

            // Without the internet check there is no portal verdict to wait for.
            PortalSignalAvailable = settings.LinkCheckInternet,
            VpnDnsActive = IsVpnDnsActive(settings),
            ActivePresetId = _dns.ActivePresetId,
            CurrentServers = _dns.StaticServers,
            PresetServers = presets
                .GroupBy(preset => preset.Id)
                .ToDictionary(group => group.Key, group => group.First().Servers),
            Rules = settings.DnsRules,
            FallbackPresetId = string.IsNullOrEmpty(settings.DnsRuleFallbackPresetId) ? null : settings.DnsRuleFallbackPresetId,
        };

        if (_engine.Evaluate(input, DateTime.UtcNow) is not { } presetId
            || presets.FirstOrDefault(preset => preset.Id == presetId) is not { } target)
        {
            return;
        }

        _ = ApplyAsync(target);
    }

    private async Task ApplyAsync(DnsPreset preset)
    {
        _applying = true;
        try
        {
            await _dns.ApplyAutomaticallyAsync(preset);
        }
        catch (Exception e)
        {
            // A failed write is retried by the engine on its backoff; it must not take the
            // tick down with it.
            CrashLog.Write("automatic dns", e);
        }
        finally
        {
            _applying = false;
        }
    }

    /// <summary>The adapter the switcher acts on, as the monitor last saw it.</summary>
    private AdapterStatus? Target()
        => _dns.AdapterId is { } id
            ? _monitor.AllAdapters.FirstOrDefault(adapter => SameInterface(adapter.Id, id))
            : null;

    private static bool SameInterface(string a, string b)
        => Guid.TryParse(a, out var left) && Guid.TryParse(b, out var right)
            ? left == right
            : string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// <summary>A connected VPN whose profile sets its own resolvers.</summary>
    private bool IsVpnDnsActive(AppSettings settings)
    {
        var status = _vpnStatus();
        if (status.State != VpnState.Connected || status.ProfileId is not { } profileId)
        {
            return false;
        }

        return _vpnProfiles().FirstOrDefault(profile => profile.Id == profileId) is { Options.UseProfileDns: true } profile
               && settings.AllDnsPresets().Any(preset => preset.Id == profile.Options.DnsPresetId && preset.Servers.Count > 0);
    }
}
