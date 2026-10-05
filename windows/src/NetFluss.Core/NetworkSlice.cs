// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace NetFluss.Core;

/// <summary>
/// One flow's bytes over one sampling interval: the input the Network Slice aggregates.
/// On Windows these come straight from the Kernel-Network trace, which already reports
/// per-interval deltas — the netstat snapshot-and-diff step of the macOS sampler is not
/// needed.
/// </summary>
public sealed record SliceFlow(
    string Process,
    string Protocol,
    string LocalAddress,
    int LocalPort,
    string RemoteAddress,
    int RemotePort,
    long Received,
    long Sent);

/// <summary>A host, service or app row — the macOS <c>NetworkSliceEntry</c>.</summary>
public sealed record SliceEntry(
    string Id,
    string Label,
    string? Detail,
    bool IsPrivateHost,
    string? CountryCode,
    ulong Received,
    ulong Sent)
{
    public ulong Total => Received + Sent;
}

/// <summary>One connection accumulated over the session — the drill-down table's row.</summary>
public sealed record SliceConnection(
    string Id,
    string Host,
    string LocalAddress,
    int? LocalPort,
    int? RemotePort,
    string Protocol,
    string? ServiceKey,
    string Process,
    ulong Received,
    ulong Sent)
{
    public ulong Total => Received + Sent;
}

public enum SliceKind
{
    Host,
    Service,
    App,
}

/// <summary>
/// The Network Slice model — port of the macOS <c>NetworkSliceManager</c>'s aggregation:
/// session totals and last-interval ("live") figures per remote host, well-known service
/// and app, plus the per-connection table behind each drill-down. Name and country
/// lookups are fed in from outside, so this stays pure and testable.
/// </summary>
public sealed class NetworkSlice
{
    public const int MaximumVisibleEntries = 12;

    /// <summary>Connections kept for the drill-down before the lightest are let go.</summary>
    public const int MaximumConnections = 4000;

    private readonly Dictionary<string, (ulong Rx, ulong Tx)> _hostTotals = [];
    private readonly Dictionary<string, (ulong Rx, ulong Tx)> _serviceTotals = [];
    private readonly Dictionary<string, (ulong Rx, ulong Tx)> _programTotals = [];
    private readonly Dictionary<string, SliceConnection> _connections = [];
    private readonly HashSet<string> _privateHosts = [];
    private readonly Dictionary<string, string?> _hostnames = [];
    private readonly Dictionary<string, string?> _countries = [];

    private Dictionary<string, (ulong Rx, ulong Tx)> _lastHosts = [];
    private Dictionary<string, (ulong Rx, ulong Tx)> _lastServices = [];
    private Dictionary<string, (ulong Rx, ulong Tx)> _lastPrograms = [];

    public bool HasSample { get; private set; }

    /// <summary>Length of the last interval, for showing live figures as rates.</summary>
    public double LastIntervalSeconds { get; private set; } = 1;

    public ulong SessionReceived { get; private set; }

    public ulong SessionSent { get; private set; }

    public void Reset()
    {
        _hostTotals.Clear();
        _serviceTotals.Clear();
        _programTotals.Clear();
        _connections.Clear();
        _privateHosts.Clear();
        _lastHosts = [];
        _lastServices = [];
        _lastPrograms = [];
        HasSample = false;
        LastIntervalSeconds = 1;
        SessionReceived = SessionSent = 0;
    }

    /// <summary>Adds one interval of flows. Loopback never touches the network and is skipped.</summary>
    public void Ingest(IEnumerable<SliceFlow> flows, TimeSpan elapsed)
    {
        HasSample = true;
        LastIntervalSeconds = Math.Max(elapsed.TotalSeconds, 0.5);

        var hosts = new Dictionary<string, (ulong Rx, ulong Tx)>();
        var services = new Dictionary<string, (ulong Rx, ulong Tx)>();
        var programs = new Dictionary<string, (ulong Rx, ulong Tx)>();

        foreach (var flow in flows)
        {
            var rx = (ulong)Math.Max(0, flow.Received);
            var tx = (ulong)Math.Max(0, flow.Sent);
            if (rx == 0 && tx == 0)
            {
                continue;
            }

            var remote = NormalizeHost(flow.RemoteAddress);
            var local = NormalizeHost(flow.LocalAddress);
            if (IsLoopback(remote) || IsLoopback(local))
            {
                continue;
            }

            Add(programs, flow.Process, rx, tx);
            SessionReceived += rx;
            SessionSent += tx;

            if (remote is not null)
            {
                Add(hosts, remote, rx, tx);
                if (IsPrivateHost(remote))
                {
                    _privateHosts.Add(remote);
                }
            }

            int? localPort = flow.LocalPort > 0 ? flow.LocalPort : null;
            int? remotePort = flow.RemotePort > 0 ? flow.RemotePort : null;
            var service = ServiceKey(localPort, remotePort);
            if (service is not null)
            {
                Add(services, service, rx, tx);
            }

            var protocol = flow.Protocol.ToUpperInvariant();
            var id = string.Join('|', protocol, local, localPort, remote, remotePort, flow.Process);
            _connections[id] = _connections.TryGetValue(id, out var existing)
                ? existing with { Received = existing.Received + rx, Sent = existing.Sent + tx }
                : new SliceConnection(id, remote ?? "*", local ?? "*", localPort, remotePort, protocol, service, flow.Process, rx, tx);
        }

        // Every new socket is a new key — local ephemeral port included — so a window left
        // open for days kept a browser's thousands of connections an hour, and scanned them
        // all on every drill-down. Past the cap the lightest half goes; the drill-down lists
        // the heaviest first anyway.
        if (_connections.Count > MaximumConnections)
        {
            foreach (var light in _connections.Values.OrderBy(c => c.Total).Take(_connections.Count / 2).Select(c => c.Id).ToList())
            {
                _connections.Remove(light);
            }
        }

        Merge(_hostTotals, hosts);
        Merge(_serviceTotals, services);
        Merge(_programTotals, programs);
        _lastHosts = hosts;
        _lastServices = services;
        _lastPrograms = programs;
    }

    /// <summary>Top rows of one column, accumulated over the session or from the last interval.</summary>
    public IReadOnlyList<SliceEntry> Entries(SliceKind kind, bool live)
    {
        var source = (kind, live) switch
        {
            (SliceKind.Host, false) => _hostTotals,
            (SliceKind.Host, true) => _lastHosts,
            (SliceKind.Service, false) => _serviceTotals,
            (SliceKind.Service, true) => _lastServices,
            (SliceKind.App, false) => _programTotals,
            _ => _lastPrograms,
        };

        return [.. source
            .OrderByDescending(p => p.Value.Rx + p.Value.Tx)
            .ThenBy(p => p.Key, StringComparer.Ordinal)
            .Take(MaximumVisibleEntries)
            .Select(p => Entry(kind, p.Key, p.Value.Rx, p.Value.Tx))];
    }

    /// <summary>The entry for an id in either mode, for a drill-down that stays live while open.</summary>
    public SliceEntry? Find(SliceKind kind, string id)
    {
        var source = kind switch
        {
            SliceKind.Host => _hostTotals,
            SliceKind.Service => _serviceTotals,
            _ => _programTotals,
        };

        return source.TryGetValue(id, out var bytes) ? Entry(kind, id, bytes.Rx, bytes.Tx) : null;
    }

    /// <summary>The session's connections behind one entry, heaviest first.</summary>
    public IReadOnlyList<SliceConnection> Connections(SliceKind kind, string id)
        => [.. _connections.Values
            .Where(c => kind switch
            {
                SliceKind.Host => c.Host == id,
                SliceKind.Service => c.ServiceKey == id,
                _ => c.Process == id,
            })
            .OrderByDescending(c => c.Total)
            .ThenBy(c => c.Id, StringComparer.Ordinal)];

    /// <summary>Hosts on screen in either mode — what is worth a reverse or country lookup.</summary>
    public IEnumerable<string> VisibleHosts()
        => Entries(SliceKind.Host, live: false).Concat(Entries(SliceKind.Host, live: true)).Select(e => e.Id).Distinct();

    /// <summary>True when a lookup for this host has been recorded, even a failed one.</summary>
    public bool HasHostname(string host) => _hostnames.ContainsKey(host);

    public bool HasCountry(string host) => _countries.ContainsKey(host);

    public bool IsPrivate(string host) => _privateHosts.Contains(host);

    /// <summary>Records a reverse lookup's outcome; null caches the miss for the session.</summary>
    public void SetHostname(string host, string? name) => _hostnames[host] = name;

    public void SetCountry(string host, string? code) => _countries[host] = code;

    public string? Hostname(string host) => _hostnames.GetValueOrDefault(host);

    private SliceEntry Entry(SliceKind kind, string id, ulong rx, ulong tx)
    {
        if (kind == SliceKind.Service)
        {
            return new SliceEntry(id, ServiceDisplayName(id), null, false, null, rx, tx);
        }

        if (kind == SliceKind.App)
        {
            return new SliceEntry(id, id, null, false, null, rx, tx);
        }

        var name = _hostnames.GetValueOrDefault(id);
        return new SliceEntry(id, name ?? id, name is null ? null : id, _privateHosts.Contains(id), _countries.GetValueOrDefault(id), rx, tx);
    }

    private static void Add(Dictionary<string, (ulong Rx, ulong Tx)> into, string key, ulong rx, ulong tx)
    {
        var existing = into.GetValueOrDefault(key);
        into[key] = (existing.Rx + rx, existing.Tx + tx);
    }

    private static void Merge(Dictionary<string, (ulong Rx, ulong Tx)> into, Dictionary<string, (ulong Rx, ulong Tx)> from)
    {
        foreach (var (key, value) in from)
        {
            Add(into, key, value.Rx, value.Tx);
        }
    }

    // ===================================== Hosts =====================================

    /// <summary>Unspecified addresses mean "no remote end"; IPv6 scope ids are dropped.</summary>
    private static string? NormalizeHost(string? address)
    {
        if (string.IsNullOrEmpty(address) || address is "*" or "0.0.0.0" or "::")
        {
            return null;
        }

        var percent = address.IndexOf('%', StringComparison.Ordinal);
        var host = percent >= 0 ? address[..percent] : address;

        // An IPv4-mapped IPv6 address is the IPv4 host it carries.
        if (IPAddress.TryParse(host, out var parsed) && parsed.IsIPv4MappedToIPv6)
        {
            return parsed.MapToIPv4().ToString();
        }

        return host;
    }

    private static bool IsLoopback(string? host)
        => host is not null && (host.StartsWith("127.", StringComparison.Ordinal) || host == "::1");

    /// <summary>LAN, link-local, unique-local and multicast — shown with a house, never looked up.</summary>
    public static bool IsPrivateHost(string host)
    {
        if (host.Contains(':', StringComparison.Ordinal))
        {
            var lower = host.ToLowerInvariant();
            return lower.StartsWith("fe80", StringComparison.Ordinal) || lower.StartsWith("fd", StringComparison.Ordinal) ||
                   lower.StartsWith("fc", StringComparison.Ordinal) || lower.StartsWith("ff", StringComparison.Ordinal);
        }

        if (host.StartsWith("10.", StringComparison.Ordinal) || host.StartsWith("192.168.", StringComparison.Ordinal) ||
            host.StartsWith("169.254.", StringComparison.Ordinal))
        {
            return true;
        }

        if (host.StartsWith("172.", StringComparison.Ordinal))
        {
            var second = host[4..].Split('.')[0];
            if (int.TryParse(second, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value is >= 16 and <= 31)
            {
                return true;
            }
        }

        return host.StartsWith("224.", StringComparison.Ordinal) || host.StartsWith("239.", StringComparison.Ordinal) ||
               host.EndsWith(".255", StringComparison.Ordinal);
    }

    /// <summary>"ber01s21-in-f14.1e100.net" → "1e100.net"; ".local" names are kept whole.</summary>
    public static string SimplifiedDomain(string hostname)
    {
        var labels = hostname.TrimEnd('.').Split('.');
        if (labels.Length <= 2 || labels[^1] == "local")
        {
            return hostname.TrimEnd('.');
        }

        string[] secondLevel = ["co", "com", "net", "org", "ac", "gov", "edu"];
        var keep = labels.Length > 3 && secondLevel.Contains(labels[^2]) ? 3 : 2;
        return string.Join('.', labels[^keep..]);
    }

    /// <summary>A PTR lookup, simplified as on macOS; null when the address has no name.</summary>
    public static async Task<string?> ReverseLookupAsync(string address, CancellationToken cancellation = default)
    {
        if (!IPAddress.TryParse(address, out var parsed))
        {
            return null;
        }

        try
        {
            var entry = await Dns.GetHostEntryAsync(parsed.ToString(), cancellation).ConfigureAwait(false);
            var name = entry.HostName.TrimEnd('.');

            // Windows answers an unresolvable address with the address itself.
            return string.IsNullOrEmpty(name) || name == address || IPAddress.TryParse(name, out _) ? null : SimplifiedDomain(name);
        }
        catch (Exception e) when (e is SocketException or ArgumentException or OperationCanceledException)
        {
            return null;
        }
    }

    // ===================================== Countries =====================================

    /// <summary>
    /// A public address's country via https://api.country.is — the service the macOS Network
    /// Slice uses: keyless, HTTPS, asked once per host per session.
    /// </summary>
    public static async Task<string?> CountryAsync(HttpClient http, string address, CancellationToken cancellation = default)
    {
        // Only something that parses as an IP is allowed into the request path.
        if (!IPAddress.TryParse(address, out var parsed) || IsPrivateHost(address))
        {
            return null;
        }

        try
        {
            var json = await http.GetStringAsync($"https://api.country.is/{parsed}", cancellation).ConfigureAwait(false);
            return ParseCountryIs(json);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            return null;
        }
    }

    /// <summary><c>{"ip":"…","country":"DE"}</c> → "DE".</summary>
    public static string? ParseCountryIs(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.ValueKind == JsonValueKind.Object &&
               document.RootElement.TryGetProperty("country", out var country) &&
               country.ValueKind == JsonValueKind.String &&
               country.GetString() is { Length: 2 } code &&
               code.All(char.IsAsciiLetter)
            ? code.ToUpperInvariant()
            : null;
    }

    // ===================================== Services =====================================

    /// <summary>
    /// A well-known service name, "#port" for other low ports (shown as "Port N"), or
    /// "#other" for ephemeral-to-ephemeral flows — games, P2P and WebRTC would otherwise
    /// flood the column with one-off rows.
    /// </summary>
    public static string? ServiceKey(int? localPort, int? remotePort)
    {
        if (remotePort is { } remote && WellKnownPorts.TryGetValue(remote, out var remoteName))
        {
            return remoteName;
        }

        if (localPort is { } local && WellKnownPorts.TryGetValue(local, out var localName))
        {
            return localName;
        }

        var candidates = new[] { remotePort, localPort }.Where(p => p is > 0).Select(p => p!.Value).ToList();
        if (candidates.Count == 0)
        {
            return null;
        }

        var port = candidates.Min();
        return port >= 32768 ? "#other" : "#" + port.ToString(CultureInfo.InvariantCulture);
    }

    public static string ServiceDisplayName(string key)
    {
        if (key == "#other")
        {
            return Localization.L("Other");
        }

        return key.StartsWith('#') && int.TryParse(key.AsSpan(1), NumberStyles.None, CultureInfo.InvariantCulture, out var port)
            ? Localization.L("Port {0}", port)
            : key;
    }

    /// <summary>The macOS table, plus the Windows discovery protocols every PC chatters on.</summary>
    private static readonly Dictionary<int, string> WellKnownPorts = new()
    {
        [20] = "ftp-data", [21] = "ftp", [22] = "ssh", [23] = "telnet", [25] = "smtp",
        [53] = "domain", [67] = "dhcp", [68] = "dhcp", [80] = "http", [88] = "kerberos",
        [110] = "pop3", [123] = "ntp", [135] = "msrpc", [137] = "netbios-ns", [138] = "netbios-dgm", [139] = "netbios-ssn",
        [143] = "imap", [161] = "snmp", [194] = "irc", [389] = "ldap", [443] = "https",
        [445] = "smb", [465] = "smtps", [500] = "isakmp", [514] = "syslog", [546] = "dhcpv6", [547] = "dhcpv6",
        [548] = "afp", [587] = "submission", [636] = "ldaps", [853] = "dns-over-tls", [873] = "rsync",
        [993] = "imaps", [995] = "pop3s", [1194] = "openvpn", [1701] = "l2tp", [1723] = "pptp",
        [1900] = "ssdp", [3283] = "net-assistant", [3389] = "rdp", [3478] = "stun", [3689] = "daap",
        [3702] = "ws-discovery", [4500] = "ipsec-nat-t", [5060] = "sip", [5222] = "xmpp-client", [5223] = "apns",
        [5228] = "google-play", [5353] = "zeroconf", [5355] = "llmnr", [5900] = "vnc", [7000] = "airplay",
        [8080] = "http-alt", [8443] = "https-alt", [51820] = "wireguard", [62078] = "iphone-sync",
    };
}
