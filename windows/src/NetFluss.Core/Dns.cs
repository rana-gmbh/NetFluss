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

using System.Net;
using System.Net.Sockets;

namespace NetFluss.Core;

/// <summary>
/// "On this network, use this resolver." Port of the macOS <c>DNSRule</c>.
///
/// <para><see cref="Bssid"/> pins the rule to one access point. An SSID on its own is a weak
/// key — anyone can name their network after your router, and the rule would then fire on
/// theirs — so the BSSID is offered as a tightening rather than a requirement.</para>
/// </summary>
public sealed record DnsRule
{
    public string Id { get; init; } = Guid.NewGuid().ToString();

    public required string Ssid { get; init; }

    /// <summary>Null or empty means "any access point with this name".</summary>
    public string? Bssid { get; init; }

    public required string PresetId { get; init; }

    public bool Enabled { get; init; } = true;
}

/// <summary>
/// A named set of DNS servers. Port of the macOS <c>DNSPreset</c>, including the built-in
/// list, so both platforms offer the same choices under the same names.
/// </summary>
public sealed record DnsPreset
{
    public required string Id { get; init; }

    public required string Name { get; init; }

    /// <summary>Empty means "hand the interface back to DHCP", which is what System Default is.</summary>
    public required IReadOnlyList<string> Servers { get; init; }

    public bool IsBuiltIn { get; init; }

    /// <summary>True for the preset that restores automatic (DHCP-supplied) DNS.</summary>
    public bool IsAutomatic => Servers.Count == 0;

    /// <summary>The same five the macOS app ships, in the same order.</summary>
    public static readonly IReadOnlyList<DnsPreset> BuiltIn =
    [
        new() { Id = "system", Name = "System Default", Servers = [], IsBuiltIn = true },
        new() { Id = "cloudflare", Name = "Cloudflare", Servers = ["1.1.1.1", "1.0.0.1"], IsBuiltIn = true },
        new() { Id = "google", Name = "Google", Servers = ["8.8.8.8", "8.8.4.4"], IsBuiltIn = true },
        new() { Id = "quad9", Name = "Quad9", Servers = ["9.9.9.9", "149.112.112.112"], IsBuiltIn = true },
        new() { Id = "opendns", Name = "OpenDNS", Servers = ["208.67.222.222", "208.67.220.220"], IsBuiltIn = true },
    ];

    /// <summary>
    /// True when <paramref name="active"/> is exactly this preset's server list.
    ///
    /// <para>Order-insensitive: Windows may hand back the resolvers in a different order from
    /// the one they were set in, and a checkmark that flickers off for that reason would be
    /// worse than no checkmark. Automatic matches only when there are no static servers.</para>
    /// </summary>
    public bool Matches(IReadOnlyList<string> active)
        => Servers.Count == active.Count
           && Servers.OrderBy(s => s, StringComparer.OrdinalIgnoreCase)
               .SequenceEqual(active.OrderBy(s => s, StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase);
}

/// <summary>Why a set of DNS servers was rejected, if it was.</summary>
public sealed record DnsValidation(bool IsValid, string? Error)
{
    public static readonly DnsValidation Ok = new(true, null);

    public static DnsValidation Fail(string error) => new(false, error);
}

/// <summary>
/// Validation for anything that will end up on an elevated command line.
///
/// <para><b>This is a security boundary, not a convenience.</b> Applying DNS requires
/// administrator rights, so the values here are handed to a process running elevated. Every
/// server is required to round-trip through <see cref="IPAddress"/> — not merely to look
/// address-shaped — so that nothing containing a quote, an ampersand or a space can reach a
/// command line in the first place.</para>
/// </summary>
public static class DnsValidator
{
    /// <summary>Windows accepts a long list; more than this is a mistake, not a configuration.</summary>
    public const int MaximumServers = 8;

    public static DnsValidation Validate(IReadOnlyList<string> servers)
    {
        if (servers.Count > MaximumServers)
        {
            return DnsValidation.Fail(Localization.L("At most {0} servers.", MaximumServers));
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var server in servers)
        {
            if (string.IsNullOrWhiteSpace(server))
            {
                return DnsValidation.Fail(Localization.L("Blank server address."));
            }

            if (!IPAddress.TryParse(server, out var address))
            {
                return DnsValidation.Fail(Localization.L("'{0}' is not an IP address.", server));
            }

            // Round-trip: TryParse accepts some forms whose canonical text differs from the
            // input, and only the canonical form is ever passed onward.
            if (!string.Equals(address.ToString(), server, StringComparison.OrdinalIgnoreCase))
            {
                return DnsValidation.Fail(Localization.L("Write '{0}' as '{1}'.", server, address));
            }

            if (address.AddressFamily is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6))
            {
                return DnsValidation.Fail(Localization.L("'{0}' is not IPv4 or IPv6.", server));
            }

            if (!seen.Add(server))
            {
                return DnsValidation.Fail(Localization.L("'{0}' is listed twice.", server));
            }
        }

        return DnsValidation.Ok;
    }

    /// <summary>Splits a user-typed list on commas, spaces and newlines.</summary>
    public static IReadOnlyList<string> Parse(string? text)
        => string.IsNullOrWhiteSpace(text)
            ? []
            : text.Split([',', ';', ' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
}
