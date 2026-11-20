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
using System.Text.Json.Serialization;

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

    /// <summary>
    /// Plain presets: the resolvers, empty meaning "hand the interface back to DHCP", which is
    /// what System Default is. Encrypted presets: the addresses Windows connects to for the
    /// DoH or DoT server — never empty, since Windows does not look the server's name up.
    /// </summary>
    public required IReadOnlyList<string> Servers { get; init; }

    public bool IsBuiltIn { get; init; }

    /// <summary>
    /// Null for plain DNS on port 53. Nullable so presets saved by older versions load
    /// unchanged.
    /// </summary>
    public DnsTransport? Transport { get; init; }

    /// <summary>The DoH URL template or the DoT host name; unused for plain DNS.</summary>
    public string? Endpoint { get; init; }

    /// <summary>True for the preset that restores automatic (DHCP-supplied) DNS.</summary>
    public bool IsAutomatic => Servers.Count == 0;

    [JsonIgnore]
    public bool IsEncrypted => DnsTransports.IsDefined(Transport) && !string.IsNullOrEmpty(Endpoint);

    /// <summary>
    /// What makes the preset encrypted, or null. A DoH preset and a plain one with the same
    /// addresses are two different resolvers, so this is part of the preset's identity.
    /// </summary>
    [JsonIgnore]
    public DnsEncryption? Encryption => IsEncrypted ? new DnsEncryption(Transport!.Value, Endpoint!) : null;

    /// <summary>Plain and encrypted built-ins, in the macOS order.</summary>
    public static readonly IReadOnlyList<DnsPreset> BuiltIn = [.. PlainBuiltIns(), .. EncryptedBuiltIns()];

    /// <summary>The same five the macOS app ships, in the same order.</summary>
    public static IReadOnlyList<DnsPreset> PlainBuiltIn => [.. BuiltIn.Where(preset => !preset.IsEncrypted)];

    /// <summary>
    /// The encrypted built-ins, the same eleven as macOS. They start hidden in the popover
    /// (<see cref="AppSettings.HideNewEncryptedDnsBuiltIns"/>) so an update does not more than
    /// double the switcher; Preferences › DNS turns them on. OpenDNS has no DoT service.
    /// </summary>
    public static IReadOnlyList<DnsPreset> EncryptedBuiltIn => [.. BuiltIn.Where(preset => preset.IsEncrypted)];

    private static IEnumerable<DnsPreset> PlainBuiltIns() =>
    [
        new() { Id = "system", Name = "System Default", Servers = [], IsBuiltIn = true },
        new() { Id = "cloudflare", Name = "Cloudflare", Servers = ["1.1.1.1", "1.0.0.1"], IsBuiltIn = true },
        new() { Id = "google", Name = "Google", Servers = ["8.8.8.8", "8.8.4.4"], IsBuiltIn = true },
        new() { Id = "quad9", Name = "Quad9", Servers = ["9.9.9.9", "149.112.112.112"], IsBuiltIn = true },
        new() { Id = "opendns", Name = "OpenDNS", Servers = ["208.67.222.222", "208.67.220.220"], IsBuiltIn = true },
    ];

    private static IEnumerable<DnsPreset> EncryptedBuiltIns()
    {
        string[] cloudflare = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"];
        string[] google = ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"];
        string[] quad9 = ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"];
        string[] openDns = ["208.67.222.222", "208.67.220.220", "2620:119:35::35", "2620:119:53::53"];
        string[] mullvad = ["194.242.2.2", "2a07:e340::2"];
        string[] adGuard = ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"];

        DnsPreset Doh(string id, string name, string[] servers, string url)
            => new() { Id = id, Name = name, Servers = servers, IsBuiltIn = true, Transport = DnsTransport.Https, Endpoint = url };

        DnsPreset Dot(string id, string name, string[] servers, string host)
            => new() { Id = id, Name = name, Servers = servers, IsBuiltIn = true, Transport = DnsTransport.Tls, Endpoint = host };

        return
        [
            Doh("cloudflare-doh", "Cloudflare (DoH)", cloudflare, "https://cloudflare-dns.com/dns-query"),
            Dot("cloudflare-dot", "Cloudflare (DoT)", cloudflare, "one.one.one.one"),
            Doh("google-doh", "Google (DoH)", google, "https://dns.google/dns-query"),
            Dot("google-dot", "Google (DoT)", google, "dns.google"),
            Doh("quad9-doh", "Quad9 (DoH)", quad9, "https://dns.quad9.net/dns-query"),
            Dot("quad9-dot", "Quad9 (DoT)", quad9, "dns.quad9.net"),
            Doh("opendns-doh", "OpenDNS (DoH)", openDns, "https://doh.opendns.com/dns-query"),
            Doh("mullvad-doh", "Mullvad (DoH)", mullvad, "https://dns.mullvad.net/dns-query"),
            Dot("mullvad-dot", "Mullvad (DoT)", mullvad, "dns.mullvad.net"),
            Doh("adguard-doh", "AdGuard (DoH)", adGuard, "https://dns.adguard-dns.com/dns-query"),
            Dot("adguard-dot", "AdGuard (DoT)", adGuard, "dns.adguard-dns.com"),
        ];
    }

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

    /// <summary>
    /// True when the adapter is exactly this resolver: the same servers <em>and</em> the same
    /// encryption. Plain Cloudflare does not match an adapter on Cloudflare's addresses with
    /// DoH switched on, and the DoH preset does not match it with DoH off.
    /// </summary>
    public bool Matches(DnsAdapterState state)
        => !state.Mixed && Matches(state.Servers) && DnsEncryption.SameAs(Encryption, state.Encryption);

    /// <summary>The first preset that is exactly what the adapter has, if any.</summary>
    public static string? ActiveId(IEnumerable<DnsPreset> presets, DnsAdapterState state)
        => presets.FirstOrDefault(preset => preset.Matches(state))?.Id;
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
