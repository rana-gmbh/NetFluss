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
    /// <summary>How often NetFluss's DoT entries are asked for again; they change only through NetFluss.</summary>
    private static readonly TimeSpan EncryptedStatusInterval = TimeSpan.FromSeconds(15);

    private readonly SettingsStore _store;
    private readonly NetworkMonitorService _monitor;
    private readonly PrivilegedActions _privileged;
    private DateTime _lastEncryptedStatus = DateTime.MinValue;

    internal DnsSwitcher(SettingsStore store, NetworkMonitorService monitor, PrivilegedActions privileged)
    {
        _store = store;
        _monitor = monitor;
        _privileged = privileged;

        // A changed DoT table or capability changes which preset is active: read again.
        _privileged.EncryptedStatusChanged += (_, _) => Refresh(askHelper: false);
    }

    internal event EventHandler? Changed;

    /// <summary>Raised around an apply, so the popover can stay open through the UAC prompt.</summary>
    internal event EventHandler<bool>? ApplyingChanged;

    /// <summary>Raised when the user picks a preset by hand, for automatic DNS to stand back on this network.</summary>
    internal event EventHandler? PickedByHand;

    internal string? AdapterId { get; private set; }

    internal string? AdapterName { get; private set; }

    internal string? ActivePresetId { get; private set; }

    /// <summary>The adapter's static resolvers at the last read; null until the first one.</summary>
    internal IReadOnlyList<string>? StaticServers { get; private set; }

    /// <summary>The adapter's resolver, encryption included, at the last read; null until the first one.</summary>
    internal DnsAdapterState? State { get; private set; }

    internal string? ApplyingPresetId { get; private set; }

    internal string? Error { get; private set; }

    /// <summary>The last pick failed only because it needs the helper; the popover offers to install it.</summary>
    internal bool ErrorNeedsHelper { get; private set; }

    internal bool IsApplying => ApplyingPresetId is not null;

    /// <summary>
    /// Re-reads the adapter's static resolvers. The configured adapter if the user picked one
    /// and it still exists, otherwise the adapter carrying the default route — on a laptop
    /// with a dozen virtual interfaces, the one actually in use.
    /// </summary>
    internal void Refresh() => Refresh(askHelper: true);

    private void Refresh(bool askHelper)
    {
        var chosen = _store.Settings.DnsAdapterId;
        var id = !string.IsNullOrEmpty(chosen) && DnsController.AdapterName(chosen) is not null
            ? chosen
            : _monitor.Addresses.PrimaryAdapterId;

        AdapterId = id;
        AdapterName = id is null ? null : DnsController.AdapterName(id);
        StaticServers = id is null ? null : DnsController.StaticServers(id);
        State = id is null || StaticServers is null ? null : DnsController.ReadState(id, StaticServers, _privileged.DotServers);
        ActivePresetId = State is null
            ? null
            : DnsController.ActivePresetId(_store.Settings.AllDnsPresets(), State);

        Changed?.Invoke(this, EventArgs.Empty);

        // The DoT entries live in the helper's record, so they are asked for rather than read;
        // an answer that changes anything comes back through EncryptedStatusChanged.
        if (askHelper && DateTime.UtcNow - _lastEncryptedStatus >= EncryptedStatusInterval)
        {
            _lastEncryptedStatus = DateTime.UtcNow;
            _ = _privileged.RefreshEncryptedStatusAsync();
        }
    }

    internal async Task ApplyAsync(DnsPreset preset)
    {
        if (IsApplying || AdapterName is not { } adapter || AdapterId is not { } adapterId)
        {
            return;
        }

        Error = null;
        ErrorNeedsHelper = false;
        ApplyingPresetId = preset.Id;
        PickedByHand?.Invoke(this, EventArgs.Empty);
        Changed?.Invoke(this, EventArgs.Empty);
        ApplyingChanged?.Invoke(this, true);

        try
        {
            var result = await _privileged.SetDnsAsync(adapterId, adapter, preset);
            if (!result.Succeeded)
            {
                Error = result.Message;
                ErrorNeedsHelper = result.NeedsHelper;
            }
        }
        finally
        {
            ApplyingPresetId = null;
            ApplyingChanged?.Invoke(this, false);

            // Read back rather than assume: the checkmark reflects what the adapter now
            // has, not what was asked for.
            Refresh(askHelper: false);
        }
    }

    /// <summary>Clears an error the user has dealt with — the helper was just installed, say.</summary>
    internal void ClearError()
    {
        Error = null;
        ErrorNeedsHelper = false;
        Changed?.Invoke(this, EventArgs.Empty);
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
            var result = await _privileged.SetDnsAsync(adapterId, adapter, preset, allowPrompt: false);
            return result.Succeeded;
        }
        finally
        {
            ApplyingPresetId = null;
            Refresh(askHelper: false);
        }
    }

    /// <summary>
    /// The captive-portal pause: the adapter's current servers written again without
    /// encryption, so the portal's login page can be reached. Helper only, like any automatic
    /// write; the rule applies the encrypted preset again once the portal is cleared.
    /// </summary>
    internal async Task<bool> PauseEncryptionAutomaticallyAsync()
    {
        if (IsApplying || AdapterName is not { } adapter || AdapterId is not { } adapterId || StaticServers is not { } servers)
        {
            return false;
        }

        ApplyingPresetId = string.Empty;
        try
        {
            var result = await _privileged.SetDnsAsync(adapterId, adapter, servers, allowPrompt: false);
            return result.Succeeded;
        }
        finally
        {
            ApplyingPresetId = null;
            Refresh(askHelper: false);
        }
    }
}
