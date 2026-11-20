// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Net;
using System.Net.Sockets;

namespace NetFluss.Core;

/// <summary>
/// How an encrypted preset talks to its resolver. Port of the macOS <c>DNSTransport</c>.
///
/// <para>Both go through Windows' own DNS client, never a local proxy: DoH per adapter through
/// <c>SetInterfaceDnsSettings</c>, DoT through the machine-wide encryption table that only
/// <c>netsh dnsclient</c> writes. DNS-over-QUIC is absent because Windows has no client for it.</para>
///
/// <para>No zero member on purpose: the settings file reads an unknown name as the enum's
/// default, and a transport a newer NetFluss added must not turn into DoH by accident. Such a
/// preset is left out of <see cref="AppSettings.AllDnsPresets"/> instead.</para>
/// </summary>
public enum DnsTransport
{
    /// <summary>DNS-over-HTTPS: the endpoint is the URL template.</summary>
    Https = 1,

    /// <summary>DNS-over-TLS: the endpoint is the server's host name, checked against its certificate.</summary>
    Tls = 2,
}

/// <summary>Names for a <see cref="DnsTransport"/>: the badge text and the helper's wire form.</summary>
public static class DnsTransports
{
    /// <summary>The helper protocol's names; strings, so a newer value never decodes as an older one.</summary>
    public const string HttpsWire = "doh";

    public const string TlsWire = "dot";

    /// <summary>Not localised: DoH and DoT are the names people search for (as on macOS).</summary>
    public static string ShortName(DnsTransport transport) => transport == DnsTransport.Tls ? "DoT" : "DoH";

    public static string ToWire(DnsTransport transport) => transport == DnsTransport.Tls ? TlsWire : HttpsWire;

    public static DnsTransport? FromWire(string? wire) => wire switch
    {
        HttpsWire => DnsTransport.Https,
        TlsWire => DnsTransport.Tls,
        _ => null,
    };

    public static bool IsDefined(DnsTransport? transport) => transport is DnsTransport.Https or DnsTransport.Tls;
}

/// <summary>
/// The encrypted half of a resolver: transport plus URL or host name. Two of these are the same
/// resolver when the transport matches and the endpoint matches without regard to case — Windows
/// hands a template back as it was stored, and host names are case-insensitive anyway.
/// </summary>
public sealed record DnsEncryption(DnsTransport Transport, string Endpoint)
{
    public static bool SameAs(DnsEncryption? a, DnsEncryption? b)
        => a is null || b is null
            ? a is null && b is null
            : a.Transport == b.Transport && string.Equals(a.Endpoint, b.Endpoint, StringComparison.OrdinalIgnoreCase);
}

/// <summary>Why a transport cannot be used on this PC, if it cannot.</summary>
public enum EncryptedDnsBlock
{
    None,

    /// <summary>Windows 10: no per-adapter DoH, so no encrypted preset at all.</summary>
    NeedsWindows11,

    /// <summary>DoT needs the netsh encryption table of Windows 11 24H2 (build 26100).</summary>
    NeedsWindows11Version24H2,

    /// <summary>The "Configure DNS over HTTPS name resolution" policy is set to prohibit.</summary>
    Policy,

    /// <summary>The build is new enough, but <c>netsh dnsclient show global</c> failed.</summary>
    NotOnThisPc,
}

/// <summary>
/// Which encrypted transports this PC can use. Computed by the helper — it is the one that has
/// to run them — and sent in its hello and DNS replies; the app computes the same from the
/// build and the policy for the badges it shows before a helper is there.
/// </summary>
public sealed record EncryptedDnsCapabilities
{
    /// <summary>Windows 11 21H2: the first release with DNS_INTERFACE_SETTINGS3 and per-server DoH.</summary>
    public const int DohMinimumBuild = 22000;

    /// <summary>Windows 11 24H2. Assumed, not documented: DoT reached client builds around it.</summary>
    public const int DotMinimumBuild = 26100;

    /// <summary>
    /// DoHPolicy under <c>HKLM\Software\Policies\Microsoft\Windows NT\DNSClient</c>: 1 is
    /// "Prohibit DoH" in the DnsClient administrative template (2 allow, 3 require). Only the
    /// prohibition stops NetFluss: the other two are what NetFluss wants anyway.
    /// </summary>
    public const int DohPolicyProhibit = 1;

    public static EncryptedDnsCapabilities None { get; } = new();

    public int Build { get; init; }

    public bool Doh { get; init; }

    public bool Dot { get; init; }

    public bool BlockedByPolicy { get; init; }

    /// <summary>The build would allow DoT, but the runtime check of netsh said no.</summary>
    public bool DotRuntimeMissing { get; init; }

    /// <param name="build">The Windows build number.</param>
    /// <param name="dohPolicy">The DoHPolicy value, or null when no policy is set.</param>
    /// <param name="dotRuntime">Whether <c>netsh dnsclient show global</c> succeeded.</param>
    public static EncryptedDnsCapabilities Evaluate(int build, int? dohPolicy, bool dotRuntime)
    {
        var blocked = dohPolicy == DohPolicyProhibit;
        var dotBuild = build >= DotMinimumBuild;
        return new EncryptedDnsCapabilities
        {
            Build = build,
            BlockedByPolicy = blocked,
            Doh = build >= DohMinimumBuild && !blocked,
            Dot = dotBuild && dotRuntime && !blocked,
            DotRuntimeMissing = dotBuild && !dotRuntime,
        };
    }

    public bool Supports(DnsTransport? transport) => transport switch
    {
        DnsTransport.Https => Doh,
        DnsTransport.Tls => Dot,
        _ => false,
    };

    /// <summary>The first reason that rules the transport out, most fundamental first.</summary>
    public EncryptedDnsBlock BlockFor(DnsTransport transport)
    {
        if (Build < DohMinimumBuild)
        {
            return EncryptedDnsBlock.NeedsWindows11;
        }

        if (transport == DnsTransport.Tls && Build < DotMinimumBuild)
        {
            return EncryptedDnsBlock.NeedsWindows11Version24H2;
        }

        if (BlockedByPolicy)
        {
            return EncryptedDnsBlock.Policy;
        }

        if (transport == DnsTransport.Tls && (DotRuntimeMissing || !Dot))
        {
            return EncryptedDnsBlock.NotOnThisPc;
        }

        return Supports(transport) ? EncryptedDnsBlock.None : EncryptedDnsBlock.NotOnThisPc;
    }
}

/// <summary>
/// Checks what goes into an encrypted preset. Port of the macOS <c>DNSEntryValidator</c>,
/// tightened for Windows.
///
/// <para><b>A security boundary, like <see cref="DnsValidator"/>.</b> The values end up in a
/// LocalSystem service: the DoH URL in <c>SetInterfaceDnsSettings</c>, the DoT host on a netsh
/// command line. So they are held to an allowlist rather than "whatever parses", and the helper
/// runs the same checks again on what it receives.</para>
///
/// <para>Unlike macOS, at least one server IP is required for both transports: Windows
/// connects to the IP and never looks the DoH or DoT host up itself.</para>
/// </summary>
public static class EncryptedDnsValidator
{
    public const int MaximumUrlLength = 512;

    public const int MaximumHostLength = 253;

    private const int MaximumLabelLength = 63;

    /// <summary>
    /// RFC 3986 unreserved and sub-delims, plus the separators a host and path need. Leaves out
    /// "%" (no escapes to decode differently later), "@" (user info), "?" and "#" (query,
    /// fragment), quotes, backslashes, braces and everything outside ASCII.
    /// </summary>
    private static readonly HashSet<char> UrlCharacters =
        [.. "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&()*+,;=:/[]"];

    /// <summary>A literal IPv4 or IPv6 address, in any form <see cref="IPAddress"/> accepts.</summary>
    public static bool IsIpLiteral(string value)
        => IPAddress.TryParse(value.Trim('[', ']'), out var address)
           && address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6;

    /// <summary>An <c>https://host[:port]/path</c> URL, trimmed, or null.</summary>
    public static string? NormalizeDohUrl(string? raw)
    {
        var trimmed = raw?.Trim();
        if (string.IsNullOrEmpty(trimmed)
            || trimmed.Length > MaximumUrlLength
            || !trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            || !trimmed.All(UrlCharacters.Contains))
        {
            return null;
        }

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            || !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || uri.UserInfo.Length > 0
            || uri.Query.Length > 0
            || uri.Fragment.Length > 0)
        {
            return null;
        }

        // The host as written, not as Uri understood it: Uri reads "https://1.1/" as 1.0.0.1,
        // and Windows, which parses the template itself, must see the same host NetFluss checked.
        var written = WrittenHost(trimmed);
        var hostValid = uri.HostNameType switch
        {
            UriHostNameType.Dns => IsValidHostName(written) && string.Equals(written, uri.Host, StringComparison.OrdinalIgnoreCase),
            UriHostNameType.IPv4 or UriHostNameType.IPv6 =>
                IPAddress.TryParse(written, out var address) && string.Equals(address.ToString(), written, StringComparison.OrdinalIgnoreCase),
            _ => false,
        };

        return hostValid ? trimmed : null;
    }

    /// <summary>The host between "https://" and the port or path, without IPv6 brackets.</summary>
    private static string WrittenHost(string url)
    {
        var rest = url["https://".Length..];
        var slash = rest.IndexOf('/');
        var authority = slash < 0 ? rest : rest[..slash];
        if (authority.StartsWith('['))
        {
            var close = authority.IndexOf(']');
            return close < 0 ? authority : authority[1..close];
        }

        var colon = authority.IndexOf(':');
        return colon < 0 ? authority : authority[..colon];
    }

    /// <summary>A DoT server name, trimmed, lower-cased and without a trailing dot, or null.</summary>
    public static string? NormalizeDotHost(string? raw)
    {
        var host = raw?.Trim().ToLowerInvariant();
        if (host is not null && host.EndsWith('.'))
        {
            host = host[..^1];
        }

        return host is not null && IsValidHostName(host) ? host : null;
    }

    /// <summary>
    /// At least two labels of letters, digits and hyphens, none starting or ending with a
    /// hyphen, at most 253 characters, and not an IP literal: the name is checked against the
    /// server's certificate, and a bare "router" cannot carry a public one.
    /// </summary>
    public static bool IsValidHostName(string host)
    {
        if (host.Length is 0 or > MaximumHostLength || IsIpLiteral(host))
        {
            return false;
        }

        var labels = host.Split('.');
        return labels.Length >= 2 && labels.All(label =>
            label.Length is > 0 and <= MaximumLabelLength
            && label[0] != '-' && label[^1] != '-'
            && label.All(c => c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '-'));
    }

    /// <summary>
    /// The whole preset: the endpoint must already be in its normalised form — the same
    /// round-trip rule <see cref="DnsValidator"/> applies to addresses, so what was checked is
    /// exactly what gets used — and there must be at least one valid server IP.
    /// </summary>
    public static DnsValidation Validate(DnsTransport? transport, string? endpoint, IReadOnlyList<string> servers)
        => Problem(transport, endpoint, servers) is { } problem
            ? DnsValidation.Fail(problem.Message ?? Localization.L(problem.Key))
            : DnsValidation.Ok;

    public static DnsValidation Validate(DnsPreset preset) => Validate(preset.Transport, preset.Endpoint, preset.Servers);

    /// <summary>The same check without building a message, for lists filtered on every tick.</summary>
    public static bool IsValid(DnsPreset preset) => Problem(preset.Transport, preset.Endpoint, preset.Servers) is null;

    /// <summary>What is wrong, as a key to look up — or, for the address rules, a finished message.</summary>
    private static (string Key, string? Message)? Problem(DnsTransport? transport, string? endpoint, IReadOnlyList<string> servers)
    {
        if (!DnsTransports.IsDefined(transport))
        {
            return ("Invalid servers.", null);
        }

        if (servers.Count == 0)
        {
            return ("Give the preset at least one server.", null);
        }

        // The address rules, messages included, are DnsValidator's: one place decides what an
        // acceptable server address is.
        if (DnsValidator.Validate(servers) is { IsValid: false } invalid)
        {
            return ("Invalid servers.", invalid.Error);
        }

        if (transport == DnsTransport.Https)
        {
            if (endpoint is null || NormalizeDohUrl(endpoint) != endpoint)
            {
                return ("Enter an https:// address, such as https://dns.example.com/dns-query.", null);
            }

            // Windows refuses a template whose host is an IP other than the server it belongs
            // to, and every server here shares one template.
            var host = WrittenHost(endpoint);
            if (IsIpLiteral(host)
                && (servers.Count != 1 || !IPAddress.Parse(host).Equals(IPAddress.Parse(servers[0]))))
            {
                return ("With an IP address in the URL, use that address as the only server.", null);
            }

            return null;
        }

        if (endpoint is null || NormalizeDotHost(endpoint) != endpoint)
        {
            return ("Enter the server's host name, such as dns.example.com.", null);
        }

        return null;
    }
}

/// <summary>One adapter server's DoH settings as Windows reports them.</summary>
public sealed record DohServerSetting(string Server, string? Template, ulong Flags)
{
    /// <summary>DNS_DOH_SERVER_SETTINGS_ENABLE_AUTO: the template comes from the system list.</summary>
    public const ulong FlagEnableAuto = 0x1;

    /// <summary>DNS_DOH_SERVER_SETTINGS_ENABLE: the template given here is used.</summary>
    public const ulong FlagEnable = 0x2;

    /// <summary>DNS_DOH_SERVER_SETTINGS_FALLBACK_TO_UDP: plain DNS is allowed when DoH fails.</summary>
    public const ulong FlagFallbackToUdp = 0x4;

    /// <summary>Any DoH at all on this server, encrypted-only or not.</summary>
    public bool IsEnabled => (Flags & (FlagEnable | FlagEnableAuto)) != 0;

    /// <summary>Windows' "Encrypted only": an explicit template, no fallback to plain DNS.</summary>
    public bool IsEncryptedOnly => (Flags & FlagEnable) != 0 && (Flags & FlagFallbackToUdp) == 0 && !string.IsNullOrEmpty(Template);
}

/// <summary>
/// What an adapter's resolver actually is: its static servers, and whether they are encrypted.
/// Read back from Windows rather than remembered, so the checkmark shows what is in effect.
/// </summary>
/// <param name="Servers">The static servers, IPv4 then IPv6; empty is DHCP.</param>
/// <param name="Encryption">The one encryption every server shares, or null for plain DNS.</param>
/// <param name="Mixed">
/// Some servers encrypted and others not, different endpoints, or DoH that may fall back to
/// plain DNS: none of NetFluss's presets, so nothing gets the checkmark.
/// </param>
public sealed record DnsAdapterState(IReadOnlyList<string> Servers, DnsEncryption? Encryption = null, bool Mixed = false)
{
    public static DnsAdapterState Plain(IReadOnlyList<string> servers) => new(servers);

    /// <summary>
    /// Combines the static servers with what Windows reports per server.
    /// </summary>
    /// <param name="servers">The adapter's static servers.</param>
    /// <param name="doh">The per-server DoH settings Windows reported.</param>
    /// <param name="dot">NetFluss's DoT entries, server IP → host name.</param>
    /// <param name="ipv4Known">Whether the IPv4 DoH settings could be read.</param>
    /// <param name="ipv6Known">
    /// Whether the IPv6 ones could. A family that could not be read is left out of the
    /// decision instead of counting as plain — otherwise a DoH preset's IPv6 half would turn
    /// every read into "mixed" and the checkmark would never show.
    /// </param>
    public static DnsAdapterState Compose(
        IReadOnlyList<string> servers,
        IReadOnlyList<DohServerSetting> doh,
        IReadOnlyDictionary<string, string> dot,
        bool ipv4Known = true,
        bool ipv6Known = true)
    {
        if (servers.Count == 0)
        {
            return Plain(servers);
        }

        var dohByServer = new Dictionary<string, DohServerSetting>(StringComparer.OrdinalIgnoreCase);
        foreach (var setting in doh)
        {
            dohByServer.TryAdd(Canonical(setting.Server), setting);
        }

        var dotByServer = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (server, host) in dot)
        {
            dotByServer.TryAdd(Canonical(server), host);
        }

        var known = servers
            .Select(Canonical)
            .Where(server => server.Contains(':') ? ipv6Known : ipv4Known)
            .ToList();

        // DoT entries are NetFluss's own records, readable whatever the family.
        var dotHosts = servers.Select(Canonical).Select(server => dotByServer.GetValueOrDefault(server)).ToList();
        var dohSettings = known.Select(server => dohByServer.GetValueOrDefault(server)).ToList();
        var anyDoh = dohSettings.Any(setting => setting is { IsEnabled: true });
        var anyDot = dotHosts.Any(host => host is not null);

        if (!anyDoh && !anyDot)
        {
            return Plain(servers);
        }

        if (anyDoh && !anyDot && known.Count > 0
            && dohSettings.All(setting => setting is { IsEncryptedOnly: true })
            && dohSettings.Select(setting => setting!.Template!).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1)
        {
            return new DnsAdapterState(servers, new DnsEncryption(DnsTransport.Https, dohSettings[0]!.Template!));
        }

        if (anyDot && !anyDoh
            && dotHosts.All(host => host is not null)
            && dotHosts.Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1)
        {
            return new DnsAdapterState(servers, new DnsEncryption(DnsTransport.Tls, dotHosts[0]!));
        }

        return new DnsAdapterState(servers, Mixed: true);
    }

    private static string Canonical(string server)
        => IPAddress.TryParse(server, out var address) ? address.ToString() : server;
}
