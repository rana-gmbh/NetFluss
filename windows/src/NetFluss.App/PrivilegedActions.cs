// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// The actions that need administrator rights, routed the best available way: through the
/// helper service when it is installed — silently, as on macOS once its helper is approved —
/// and otherwise through one elevated, short-lived process with its own UAC prompt.
///
/// <para>This is the <c>IDnsApplier</c> seam the earlier DNS work left for the service; the
/// UI calls the same method either way and never learns which path ran.</para>
/// </summary>
internal sealed class PrivilegedActions(HelperClient helper)
{
    private static readonly TimeSpan HelperTimeout = TimeSpan.FromSeconds(20);

    private readonly DnsController _elevated = new();

    /// <summary>True when changes will apply without a UAC prompt.</summary>
    internal bool IsSilent => helper.IsConnected && helper.IsCurrentVersion;

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
