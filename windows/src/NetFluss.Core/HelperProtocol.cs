// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Text.Json;
using System.Text.Json.Serialization;

namespace NetFluss.Core;

/// <summary>
/// The contract between NetFluss and its helper service, the Windows counterpart of the
/// macOS <c>NetflussHelperProtocol</c>. Newline-delimited JSON over a duplex named pipe.
///
/// <para>JSON rather than a binary format because the volume is small — one message a second
/// while a consumer is open — and because a protocol a person can read in a pipe dump is a
/// protocol that gets debugged.</para>
/// </summary>
public static class HelperProtocol
{
    /// <summary>The pipe the service listens on. Machine-wide: the service runs as LocalSystem.</summary>
    public const string PipeName = "NetFluss.Helper";

    /// <summary>The Windows service name.</summary>
    public const string ServiceName = "NetFlussHelper";

    /// <summary>
    /// Bumped whenever a message changes shape. 2 added the VPN operations; 3 encrypted DNS
    /// (setDns with a transport, dnsStatus, capabilities in replies). Clients compare with
    /// "at least", so each step only adds.
    /// </summary>
    public const int Version = 3;

    /// <summary>A line longer than this is not a NetFluss message, and is dropped unread.</summary>
    public const int MaximumLineLength = 1 << 20;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string Serialize<T>(T message) => JsonSerializer.Serialize(message, Json);

    public static T? Deserialize<T>(string line)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(line, Json);
        }
        catch (JsonException)
        {
            return default;
        }
    }
}

/// <summary>Client → helper.</summary>
public sealed record HelperRequest
{
    /// <summary>"hello", "subscribe", "unsubscribe", "setDns", "dnsStatus", "restartAdapter", "vpnStart", "vpnStop", "vpnLog".</summary>
    public required string Op { get; init; }

    /// <summary>Echoed in the matching result, so a client can await one specific answer.</summary>
    public int Id { get; init; }

    public int Version { get; init; } = HelperProtocol.Version;

    /// <summary>Interface GUID for setDns and restartAdapter.</summary>
    public string? Adapter { get; init; }

    /// <summary>Resolvers for setDns; empty restores DHCP. For encrypted DNS, the addresses Windows connects to.</summary>
    public IReadOnlyList<string>? Servers { get; init; }

    /// <summary>
    /// setDns (protocol 3): "doh" or "dot" for encrypted DNS, null for plain. A string, not an
    /// enum, so a value this helper does not know is refused rather than read as another.
    /// </summary>
    public string? Transport { get; init; }

    /// <summary>setDns (protocol 3): the DoH URL template or the DoT host name.</summary>
    public string? Endpoint { get; init; }

    /// <summary>Whether a subscription wants per-flow detail (the Network Slice) as well.</summary>
    public bool Flows { get; init; }

    /// <summary>vpnStart: "openVpn" or "wireGuard".</summary>
    public string? Kind { get; init; }

    /// <summary>vpnStart: the WireGuard tunnel name (also its service and adapter name).</summary>
    public string? Tunnel { get; init; }

    /// <summary>
    /// vpnStart: the config and the files it references, by content. Never paths: the
    /// helper runs as LocalSystem and must not read files the caller could not read itself.
    /// </summary>
    public IReadOnlyList<HelperFile>? Files { get; init; }

    /// <summary>vpnStart: which of <see cref="Files"/> is the config to run.</summary>
    public string? Config { get; init; }

    /// <summary>vpnStop and vpnLog: the tunnel, as vpnStart returned it.</summary>
    public string? Handle { get; init; }
}

/// <summary>Helper → client.</summary>
public sealed record HelperMessage
{
    /// <summary>"hello", "traffic", "result".</summary>
    public required string Type { get; init; }

    public int Id { get; init; }

    public int Version { get; init; }

    /// <summary>The helper's build version, compared with the app's to offer an update.</summary>
    public string? HelperVersion { get; init; }

    /// <summary>Why traffic is unavailable inside the helper, when it is.</summary>
    public string? TraceStatus { get; init; }

    /// <summary>The trace's counters in one line ("Running, delivered 812, counted 640, consuming"), for diagnostics.</summary>
    public string? TraceDetail { get; init; }

    public bool Ok { get; init; }

    public string? Message { get; init; }

    public long ElapsedMs { get; init; }

    public IReadOnlyList<HelperProcess>? Processes { get; init; }

    public IReadOnlyList<HelperFlow>? Flows { get; init; }

    /// <summary>vpnStart: the running tunnel, for vpnStop and vpnLog.</summary>
    public string? Handle { get; init; }

    /// <summary>vpnStart (OpenVPN): the OpenVPN process, so the app can check who owns the port before trusting it.</summary>
    public int Pid { get; init; }

    /// <summary>vpnStart (OpenVPN): the loopback port of its management interface…</summary>
    public int Port { get; init; }

    /// <summary>…and the one-time password that interface asks for.</summary>
    public string? Secret { get; init; }

    /// <summary>hello, setDns and dnsStatus (protocol 3): which encrypted transports this PC can use.</summary>
    public EncryptedDnsCapabilities? Capabilities { get; init; }

    /// <summary>
    /// setDns and dnsStatus (protocol 3): the DoT entries NetFluss added to Windows'
    /// machine-wide encryption table — only its own, never ones the user or Windows made.
    /// </summary>
    public IReadOnlyList<HelperDotServer>? DotServers { get; init; }
}

/// <summary>One DoT entry NetFluss configured: the server address and the host name checked against its certificate.</summary>
public sealed record HelperDotServer(string Server, string Host);

public sealed record HelperProcess(int Pid, string Name, long Rx, long Tx);

public sealed record HelperFlow(int Pid, string Proto, string Local, int LocalPort, string Remote, int RemotePort, long Rx, long Tx);

/// <summary>One file of a VPN profile: its path relative to the config, and its bytes.</summary>
public sealed record HelperFile(string Name, byte[] Data);
