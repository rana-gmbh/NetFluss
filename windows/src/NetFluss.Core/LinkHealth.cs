// Copyright (C) 2026 Rana GmbH
//
// This file is part of NetFluss.
//
// NetFluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// NetFluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with NetFluss. If not, see <https://www.gnu.org/licenses/>.

namespace NetFluss.Core;

/// <summary>Which physical medium carries the default route. Picks the glyph.</summary>
public enum LinkMedium
{
    WiFi,
    Ethernet,
    Other,
}

/// <summary>Traffic-light state for the link indicator. Port of the macOS <c>LinkHealth</c>.</summary>
public enum LinkHealth
{
    /// <summary>Connected, addressed, and the internet answered.</summary>
    Online,

    /// <summary>Connected but going nowhere: no address, no gateway, a captive portal, or a dead upstream.</summary>
    Limited,

    /// <summary>No usable interface at all.</summary>
    Offline,
}

/// <summary>Result of one internet check.</summary>
public enum LinkProbeOutcome
{
    /// <summary>The internet is genuinely reachable.</summary>
    Online,

    /// <summary>Something answered, but not the internet — a captive portal.</summary>
    Portal,

    /// <summary>Nothing answered: upstream down, DNS dead, or traffic being dropped.</summary>
    Unreachable,
}

/// <summary>What the link indicator shows, and what the DNS rules and tooltip read.</summary>
public sealed record LinkStatus(LinkHealth Health, LinkMedium Medium, string InterfaceId, string? InterfaceName, string? Ssid, string? Bssid)
{
    public static readonly LinkStatus Offline = new(LinkHealth.Offline, LinkMedium.Other, string.Empty, null, null, null);

    // The macOS system colours, so the indicator defaults read the same on both platforms.
    public static readonly ThemeColor DefaultOnline = ThemeColor.FromHex("2EA043");
    public static readonly ThemeColor DefaultLimited = ThemeColor.FromHex("F7630C");
    public static readonly ThemeColor DefaultOffline = ThemeColor.FromHex("E81123");
}

/// <summary>
/// Derives the link indicator's state from things NetFluss already samples every second.
///
/// <para>Port of the macOS <c>LinkHealthTracker</c>'s decision table. Whether the interface
/// is up, whether it has a real address and a gateway, and which medium carries the default
/// route are all free. Only "addressed and routed, but is the internet actually there?" needs
/// a verdict from outside, and that arrives as <paramref name="verdict"/> — from Windows' own
/// connectivity check by default, or from a probe of the user's chosen address.</para>
/// </summary>
public static class LinkHealthEvaluator
{
    public static LinkStatus Evaluate(
        AdapterStatus? carrier,
        string? internalIp,
        string? gatewayIp,
        bool checkInternet,
        LinkProbeOutcome? verdict)
    {
        var medium = Medium(carrier);

        if (carrier is null || !carrier.IsUp)
        {
            return LinkStatus.Offline with { Medium = medium, InterfaceId = carrier?.Id ?? string.Empty, InterfaceName = carrier?.DisplayName };
        }

        // An unknown SSID is not proof of anything — Windows withholds it without Location
        // access — so liveness comes from the address and the route; the SSID only names it.
        var status = new LinkStatus(LinkHealth.Online, medium, carrier.Id, carrier.DisplayName, carrier.WifiSsid, carrier.Wifi?.Bssid);

        // A self-assigned address or no default route is definitively not online, and no
        // request could say anything the routing table has not already said.
        if (IsUnusable(internalIp, gatewayIp))
        {
            return status with { Health = LinkHealth.Limited };
        }

        // Without the internet check this is as far as can honestly be gone: green means
        // "the link is up", not "the internet answers".
        if (!checkInternet)
        {
            return status;
        }

        // Unknown shows as online: the indicator goes amber on evidence, never on ignorance.
        return verdict is null or LinkProbeOutcome.Online ? status : status with { Health = LinkHealth.Limited };
    }

    /// <summary>
    /// The physical interface behind the default route. With a VPN up the route goes through
    /// the tunnel, but this indicator is about the connection underneath — the VPN has its own
    /// mark — so tunnels are skipped for the busiest real link instead.
    /// </summary>
    public static AdapterStatus? Carrier(string? primaryAdapterId, IReadOnlyList<AdapterStatus> adapters)
    {
        if (primaryAdapterId is not null &&
            adapters.FirstOrDefault(a => string.Equals(a.Id, primaryAdapterId, StringComparison.OrdinalIgnoreCase)) is { IsTunnel: false } primary)
        {
            return primary;
        }

        return adapters
            .Where(a => !a.IsTunnel && !a.IsNonInternet && a.IsUp && a.Type is AdapterType.WiFi or AdapterType.Ethernet)
            .OrderByDescending(a => a.RxBytes + a.TxBytes)
            .FirstOrDefault();
    }

    public static LinkMedium Medium(AdapterStatus? adapter) => adapter?.Type switch
    {
        AdapterType.WiFi => LinkMedium.WiFi,
        AdapterType.Ethernet => LinkMedium.Ethernet,
        _ => LinkMedium.Other,
    };

    /// <summary>An address the machine assigned itself, or no way off the subnet.</summary>
    public static bool IsUnusable(string? internalIp, string? gatewayIp)
    {
        if (string.IsNullOrWhiteSpace(internalIp) || internalIp.StartsWith("169.254.", StringComparison.Ordinal))
        {
            return true;
        }

        var gateway = gatewayIp?.Trim();
        return string.IsNullOrEmpty(gateway) || gateway == "—";
    }

    /// <summary>
    /// Identifies "the same network" for the probe schedule. The BSSID is in it on purpose:
    /// roaming to another access point is exactly when a working connection quietly stops.
    /// </summary>
    public static string Fingerprint(AdapterStatus carrier, string? internalIp, string? gatewayIp)
        => string.Join('|', carrier.Id, carrier.WifiSsid ?? string.Empty, carrier.Wifi?.Bssid ?? string.Empty, gatewayIp ?? string.Empty, internalIp ?? string.Empty);
}

/// <summary>
/// The internet check against a user-chosen address, and its schedule.
///
/// <para>The default needs neither: Windows already runs its own connectivity test
/// (NCSI) and reports a verdict — including "captive portal" — that NetFluss reads for free.
/// This exists for the macOS "Check address" setting, for networks where that test is
/// blocked or misleading.</para>
/// </summary>
public sealed class LinkProbe
{
    /// <summary>Re-check while healthy: cheap insurance against a far-side failure, not a heartbeat.</summary>
    public static readonly TimeSpan HealthyInterval = TimeSpan.FromSeconds(60);

    /// <summary>Re-check while degraded: when someone is watching for recovery.</summary>
    public static readonly TimeSpan DegradedInterval = TimeSpan.FromSeconds(10);

    /// <summary>A single dropped request is not an outage; a portal answer is believed at once.</summary>
    public const int FailuresBeforeLimited = 2;

    private string? _fingerprint;
    private DateTime? _lastProbeAt;
    private int _consecutiveFailures;

    /// <summary>Last confirmed verdict; null until one is in.</summary>
    public LinkProbeOutcome? Verdict { get; private set; }

    public bool InFlight { get; private set; }

    /// <summary>
    /// Whether to probe now. Always on a new network, otherwise on a backoff that depends on
    /// the last verdict. A failure short of the threshold still counts as degraded for
    /// scheduling, or an outage would take a full healthy interval longer to show.
    /// </summary>
    public bool ShouldProbe(string fingerprint, DateTime now)
    {
        if (_fingerprint != fingerprint)
        {
            _fingerprint = fingerprint;
            // A new network says nothing about the old one's verdict.
            Verdict = null;
            _consecutiveFailures = 0;
            _lastProbeAt = null;
        }

        if (InFlight)
        {
            return false;
        }

        if (_lastProbeAt is not { } last)
        {
            return true;
        }

        var degraded = Verdict is not LinkProbeOutcome.Online || _consecutiveFailures > 0;
        return now - last >= (degraded ? DegradedInterval : HealthyInterval);
    }

    public void Started(DateTime now)
    {
        InFlight = true;
        _lastProbeAt = now;
    }

    /// <summary>Records a probe result. Returns whether the verdict changed.</summary>
    public bool Completed(LinkProbeOutcome outcome)
    {
        InFlight = false;
        var before = Verdict;

        switch (outcome)
        {
            case LinkProbeOutcome.Online:
            case LinkProbeOutcome.Portal:
                _consecutiveFailures = 0;
                Verdict = outcome;
                break;

            case LinkProbeOutcome.Unreachable:
                _consecutiveFailures++;
                if (_consecutiveFailures >= FailuresBeforeLimited)
                {
                    Verdict = LinkProbeOutcome.Unreachable;
                }

                break;
        }

        return before != Verdict;
    }

    public void Reset()
    {
        _fingerprint = null;
        _lastProbeAt = null;
        _consecutiveFailures = 0;
        Verdict = null;
        InFlight = false;
    }

    /// <summary>
    /// What one response means. An arbitrary address has no known body to look for — macOS
    /// can only check for "Success" because it only ever asks Apple — so the signal used is
    /// the one portals cannot hide: they answer by redirecting. A direct 2xx is the internet;
    /// a redirect or any other answer is something standing in its way.
    /// </summary>
    public static LinkProbeOutcome Classify(int? statusCode)
        => statusCode switch
        {
            null => LinkProbeOutcome.Unreachable,
            >= 200 and < 300 => LinkProbeOutcome.Online,
            _ => LinkProbeOutcome.Portal,
        };

    /// <summary>
    /// The address as stored: trimmed, and given a scheme if typed bare. Only http and https
    /// are kept — anything else is not something to make a request to — and http is the
    /// default because a portal intercepting https produces a TLS error indistinguishable
    /// from a dead link, which is the very distinction the check exists to make.
    /// </summary>
    public static string Normalize(string? value)
    {
        var text = value?.Trim() ?? string.Empty;
        if (text.Length == 0)
        {
            return string.Empty;
        }

        if (!text.Contains("://", StringComparison.Ordinal))
        {
            text = "http://" + text;
        }

        return Uri.TryCreate(text, UriKind.Absolute, out var uri) &&
               uri.Scheme is "http" or "https" &&
               !string.IsNullOrEmpty(uri.Host)
            ? uri.ToString()
            : string.Empty;
    }
}
