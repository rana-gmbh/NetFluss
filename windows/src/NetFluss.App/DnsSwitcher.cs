// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// State behind the popover's DNS section: which adapter it acts on, which preset is active
/// there, and an apply in flight. The Preferences DNS tab shares <see cref="DnsController"/>
/// but keeps its own adapter choice, since it is where any adapter can be configured.
/// </summary>
internal sealed class DnsSwitcher
{
    private readonly SettingsStore _store;
    private readonly NetworkMonitorService _monitor;
    private readonly PrivilegedActions _privileged;

    internal DnsSwitcher(SettingsStore store, NetworkMonitorService monitor, PrivilegedActions privileged)
    {
        _store = store;
        _monitor = monitor;
        _privileged = privileged;
    }

    internal event EventHandler? Changed;

    /// <summary>Raised around an apply, so the popover can stay open through the UAC prompt.</summary>
    internal event EventHandler<bool>? ApplyingChanged;

    internal string? AdapterId { get; private set; }

    internal string? AdapterName { get; private set; }

    internal string? ActivePresetId { get; private set; }

    /// <summary>The adapter's static resolvers at the last read; null until the first one.</summary>
    internal IReadOnlyList<string>? StaticServers { get; private set; }

    internal string? ApplyingPresetId { get; private set; }

    internal string? Error { get; private set; }

    internal bool IsApplying => ApplyingPresetId is not null;

    /// <summary>
    /// Re-reads the adapter's static resolvers. The configured adapter if the user picked one
    /// and it still exists, otherwise the adapter carrying the default route — on a laptop
    /// with a dozen virtual interfaces, the one actually in use.
    /// </summary>
    internal void Refresh()
    {
        var chosen = _store.Settings.DnsAdapterId;
        var id = !string.IsNullOrEmpty(chosen) && DnsController.AdapterName(chosen) is not null
            ? chosen
            : _monitor.Addresses.PrimaryAdapterId;

        AdapterId = id;
        AdapterName = id is null ? null : DnsController.AdapterName(id);
        StaticServers = id is null ? null : DnsController.StaticServers(id);
        ActivePresetId = StaticServers is null
            ? null
            : DnsController.ActivePresetId(_store.Settings.AllDnsPresets(), StaticServers);

        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal async Task ApplyAsync(DnsPreset preset)
    {
        if (IsApplying || AdapterName is not { } adapter || AdapterId is not { } adapterId)
        {
            return;
        }

        Error = null;
        ApplyingPresetId = preset.Id;
        Changed?.Invoke(this, EventArgs.Empty);
        ApplyingChanged?.Invoke(this, true);

        try
        {
            var result = await _privileged.SetDnsAsync(adapterId, adapter, preset.Servers);
            if (!result.Succeeded)
            {
                Error = result.Message;
            }
        }
        finally
        {
            ApplyingPresetId = null;
            ApplyingChanged?.Invoke(this, false);

            // Read back rather than assume: the checkmark reflects what the adapter now
            // has, not what was asked for.
            Refresh();
        }
    }

    /// <summary>
    /// Applies a preset on automatic DNS's behalf: through the helper only, never a UAC prompt,
    /// and without holding the popover open. Returns whether the helper reported success.
    /// </summary>
    internal async Task<bool> ApplyAutomaticallyAsync(DnsPreset preset)
    {
        if (IsApplying || AdapterName is not { } adapter || AdapterId is not { } adapterId)
        {
            return false;
        }

        ApplyingPresetId = preset.Id;
        try
        {
            var result = await _privileged.SetDnsAsync(adapterId, adapter, preset.Servers, allowPrompt: false);
            return result.Succeeded;
        }
        finally
        {
            ApplyingPresetId = null;
            Refresh();
        }
    }
}
