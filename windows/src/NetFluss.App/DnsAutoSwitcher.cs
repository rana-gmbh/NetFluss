// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using NetFluss.Core.Vpn;

namespace NetFluss.App;

/// <summary>
/// Automatic DNS by Wi-Fi network (macOS 2.7): gathers what <see cref="DnsRuleEngine"/>
/// needs on every tick and applies its answer through the helper.
///
/// <para>Encrypted presets go through the same path; the engine holds a rule that names one
/// this PC or this helper cannot set, and on a captive portal it writes the same servers
/// without encryption until the portal lets the PC online.</para>
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

    /// <summary>
    /// The network (SSID, empty for wired) on which the user last picked a preset by hand.
    /// In memory only: a restart hands the network back to the rules, which is the less
    /// surprising way for a forgotten pick to end.
    /// </summary>
    private string? _manualOverrideNetwork;

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
        _dns.PickedByHand += (_, _) => RecordManualOverride();
    }

    /// <summary>
    /// Remembers a hand pick for the network it was made on: the rules leave that network
    /// alone until another one is joined. Preferences calls this too when it applies a preset
    /// to the adapter the rules act on.
    /// </summary>
    internal void RecordManualOverride()
    {
        if (!_store.Settings.DnsAutoSwitchEnabled)
        {
            return;
        }

        _manualOverrideNetwork = CurrentNetwork?.Ssid ?? string.Empty;
    }

    /// <summary>The stored hand pick, dropped for good once the PC is on a different network.</summary>
    private string? CurrentManualOverride()
    {
        var networkUp = _link.Status?.Health != LinkHealth.Offline && Target() is { IsUp: true };
        _manualOverrideNetwork = DnsRuleEngine.CurrentManualOverride(_manualOverrideNetwork, CurrentNetwork?.Ssid, networkUp);
        return _manualOverrideNetwork;
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
            _manualOverrideNetwork = null;
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
            PresetEncryption = presets
                .Where(preset => preset.Encryption is not null)
                .GroupBy(preset => preset.Id)
                .ToDictionary(group => group.Key, group => group.First().Encryption!),
            CurrentEncryption = _dns.State?.Encryption,
            CurrentEncryptionMixed = _dns.State?.Mixed ?? false,

            // Only what the helper can actually set: an older helper would write an encrypted
            // preset's addresses as plain DNS, which is worse than holding.
            Capabilities = _privileged.CanSetEncryptedDns ? _privileged.EncryptedCapabilities : EncryptedDnsCapabilities.None,
            Rules = settings.DnsRules,
            FallbackPresetId = string.IsNullOrEmpty(settings.DnsRuleFallbackPresetId) ? null : settings.DnsRuleFallbackPresetId,
            ManualOverrideNetwork = CurrentManualOverride(),
        };

        switch (_engine.Next(input, DateTime.UtcNow))
        {
            case { PauseEncryption: true }:
                _ = RunAsync(_dns.PauseEncryptionAutomaticallyAsync);
                break;

            case { PresetId: { } presetId } when presets.FirstOrDefault(preset => preset.Id == presetId) is { } target:
                _ = RunAsync(() => _dns.ApplyAutomaticallyAsync(target));
                break;
        }
    }

    private async Task RunAsync(Func<Task<bool>> write)
    {
        _applying = true;
        try
        {
            await write();
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
               && settings.AllDnsPresets().Any(preset => preset.Id == profile.Options.DnsPresetId && preset.Servers.Count > 0 && !preset.IsEncrypted);
    }
}
