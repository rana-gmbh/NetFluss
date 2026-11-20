// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.App;

/// <summary>
/// The actions that need administrator rights, routed the best available way: through the
/// helper service when it is installed — silently, as on macOS once its helper is approved —
/// and otherwise through one elevated, short-lived process with its own UAC prompt.
///
/// <para>This is the <c>IDnsApplier</c> seam the earlier DNS work left for the service; the
/// UI calls the same method either way and never learns which path ran.</para>
///
/// <para><b>Encrypted DNS has no elevated fallback.</b> DoT is written by netsh into a
/// machine-wide table, and both it and DoH have to be taken back exactly; only the helper
/// keeps the record that makes that possible. Without it an encrypted preset is refused with
/// a result that says the helper is needed, and nothing is changed.</para>
/// </summary>
internal sealed class PrivilegedActions(HelperClient helper)
{
    private static readonly TimeSpan HelperTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(5);

    private static EncryptedDnsCapabilities? _assumed;

    private readonly DnsController _elevated = new();
    private EncryptedDnsCapabilities? _replied;

    /// <summary>True when changes will apply without a UAC prompt.</summary>
    internal bool IsSilent => helper.IsConnected && helper.IsCurrentVersion;

    /// <summary>Whether an encrypted preset can be applied right now.</summary>
    internal bool CanSetEncryptedDns => IsSilent && helper.SupportsEncryptedDns;

    /// <summary>
    /// What this PC can do with encrypted DNS: the helper's word when it speaks protocol 3 —
    /// it ran the netsh check behind DoT — and otherwise what the build and policy suggest,
    /// which is enough to grey out what can never work here.
    /// </summary>
    internal EncryptedDnsCapabilities EncryptedCapabilities
        => helper.SupportsEncryptedDns ? _replied ?? helper.HelloCapabilities ?? Assumed : Assumed;

    private static EncryptedDnsCapabilities Assumed => _assumed ??= EncryptedDnsPlatform.Assumed();

    /// <summary>NetFluss's DoT entries as the helper last reported them, server → host.</summary>
    internal IReadOnlyDictionary<string, string> DotServers { get; private set; } = new Dictionary<string, string>();

    /// <summary>Raised when the capabilities or the DoT entries the helper reports changed.</summary>
    internal event EventHandler? EncryptedStatusChanged;

    /// <summary>
    /// Applies a preset, plain or encrypted. Plain presets take <see cref="SetDnsAsync(string, string, IReadOnlyList{string}, bool)"/>
    /// unchanged, elevation fallback included; encrypted ones go to the helper or nowhere.
    /// </summary>
    internal async Task<DnsApplyResult> SetDnsAsync(string adapterId, string adapterName, DnsPreset preset, bool allowPrompt = true)
    {
        if (preset.Transport is null)
        {
            return await SetDnsAsync(adapterId, adapterName, preset.Servers, allowPrompt);
        }

        // Checked here and again in the helper: these values reach a LocalSystem service.
        var validation = EncryptedDnsValidator.Validate(preset);
        if (!validation.IsValid || preset.Encryption is not { } encryption)
        {
            return DnsApplyResult.Fail(validation.Error ?? Localization.L("Invalid servers."));
        }

        if (!CanSetEncryptedDns)
        {
            return DnsApplyResult.Fail(helper.IsConnected && !helper.IsCurrentVersion
                ? Localization.L("The NetFluss helper is out of date. Update it to use encrypted DNS.")
                : Localization.L("Encrypted DNS needs the NetFluss helper. Installing it asks for approval once.")) with { NeedsHelper = true };
        }

        if (EncryptedCapabilities.BlockFor(encryption.Transport) is not EncryptedDnsBlock.None and var block)
        {
            return DnsApplyResult.Fail(EncryptedDnsText.Block(block));
        }

        var reply = await helper.RequestAsync(
            new HelperRequest
            {
                Op = "setDns",
                Adapter = adapterId,
                Servers = preset.Servers,
                Transport = DnsTransports.ToWire(encryption.Transport),
                Endpoint = encryption.Endpoint,
            },
            HelperTimeout);
        Absorb(reply);

        if (reply is { Ok: true })
        {
            return DnsApplyResult.Ok(Localization.L("{0} now uses {1}.", adapterName, $"{DnsTransports.ShortName(encryption.Transport)} {encryption.Endpoint}"));
        }

        return DnsApplyResult.Fail(Localization.L("Encrypted DNS couldn't be set: {0}", reply?.Message ?? Localization.L("The helper could not change DNS.")));
    }

    /// <summary>Asks the helper what it has set up; quietly does nothing without one.</summary>
    internal async Task RefreshEncryptedStatusAsync()
    {
        if (!helper.SupportsEncryptedDns)
        {
            return;
        }

        Absorb(await helper.RequestAsync(new HelperRequest { Op = "dnsStatus" }, StatusTimeout));
    }

    /// <summary>Keeps what a DNS reply says about encrypted DNS: every one carries it from protocol 3 on.</summary>
    private void Absorb(HelperMessage? reply)
    {
        if (reply is null)
        {
            return;
        }

        var changed = false;
        if (reply.Capabilities is { } capabilities && capabilities != _replied)
        {
            _replied = capabilities;
            changed = true;
        }

        if (reply.DotServers is { } servers)
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var server in servers)
            {
                map.TryAdd(server.Server, server.Host);
            }

            if (map.Count != DotServers.Count
                || map.Any(pair => !DotServers.TryGetValue(pair.Key, out var host) || !string.Equals(host, pair.Value, StringComparison.OrdinalIgnoreCase)))
            {
                DotServers = map;
                changed = true;
            }
        }

        if (changed)
        {
            EncryptedStatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <param name="allowPrompt">
    /// False for changes nobody asked for at that moment — automatic DNS on a network change —
    /// which must fail rather than put a UAC prompt in front of the user.
    /// </param>
    internal async Task<DnsApplyResult> SetDnsAsync(string adapterId, string adapterName, IReadOnlyList<string> servers, bool allowPrompt = true)
    {
        var validation = DnsValidator.Validate(servers);
        if (!validation.IsValid)
        {
            return DnsApplyResult.Fail(validation.Error ?? "Invalid servers.");
        }

        if (IsSilent)
        {
            var reply = await helper.RequestAsync(
                new HelperRequest { Op = "setDns", Adapter = adapterId, Servers = servers },
                HelperTimeout);
            Absorb(reply);

            if (reply is { Ok: true })
            {
                return DnsApplyResult.Ok(servers.Count == 0
                    ? Localization.L("{0} is back on automatic DNS.", adapterName)
                    : Localization.L("{0} now uses {1}.", adapterName, string.Join(", ", servers)));
            }

            if (reply is not null)
            {
                return DnsApplyResult.Fail(reply.Message ?? Localization.L("The helper could not change DNS."));
            }

            // No answer at all: the helper went away mid-request. Fall through to elevation
            // rather than report a failure the user can do nothing about.
        }

        if (!allowPrompt)
        {
            return DnsApplyResult.Fail(Localization.L("The helper could not change DNS."));
        }

        return await _elevated.ApplyAsync(adapterName, servers);
    }

    internal async Task<string?> RestartAdapterAsync(AdapterStatus adapter)
    {
        if (adapter.Type != AdapterType.WiFi && IsSilent)
        {
            var reply = await helper.RequestAsync(
                new HelperRequest { Op = "restartAdapter", Adapter = adapter.Id },
                HelperTimeout);

            if (reply is not null)
            {
                return reply.Ok ? null : reply.Message;
            }
        }

        return await AdapterReconnector.ReconnectAsync(adapter);
    }
}
