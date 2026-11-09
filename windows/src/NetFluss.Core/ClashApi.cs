// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace NetFluss.Core;

/// <summary>One live connection as the Clash API reports it (macOS issue #61).</summary>
public sealed record ClashConnection(string Id, string Node, ulong UploadBytes, ulong DownloadBytes, string Host, string Network, string ProcessPath);

/// <summary>
/// A <c>GET /connections</c> snapshot. The totals are process-wide monotonic counters; the
/// per-connection counters only cover connections still open, so the two disagree by whatever
/// closed since the last poll — <see cref="ClashNodeAccumulator"/> accounts for that remainder
/// instead of losing it.
/// </summary>
public sealed record ClashSnapshot(ulong UploadTotal, ulong DownloadTotal, IReadOnlyList<ClashConnection> Connections);

public enum ClashFailure
{
    InvalidUrl,

    /// <summary>401/403 — wrong or missing secret.</summary>
    AuthFailed,

    HttpStatus,

    /// <summary>Nothing listening at the address.</summary>
    Refused,

    TimedOut,

    RequestFailed,

    ParseError,
}

public sealed class ClashApiException(ClashFailure failure, int? status = null) : Exception(failure.ToString())
{
    public ClashFailure Failure { get; } = failure;

    public int? Status { get; } = status;

    /// <summary>What went wrong, in words the Preferences page and the Statistics window can show.</summary>
    public string Describe() => Failure switch
    {
        ClashFailure.InvalidUrl => Localization.L("The controller address is not valid."),
        ClashFailure.AuthFailed => Localization.L("The controller rejected the secret."),
        ClashFailure.HttpStatus => Localization.L("The controller answered with HTTP {0}.", Status ?? 0),
        ClashFailure.Refused => Localization.L("No proxy controller is listening at that address."),
        ClashFailure.TimedOut => Localization.L("The controller did not answer in time."),
        ClashFailure.ParseError => Localization.L("The controller's answer was not in the expected format."),
        _ => Localization.L("Could not reach the proxy controller."),
    };
}

/// <summary>
/// Reads the Clash API that sing-box, mihomo, Clash Verge and others expose — port of the
/// macOS 2.7 <c>ClashAPIMonitor</c>. Talks to the controller the user points it at, normally
/// a loopback port; nothing here leaves the machine unless the user enters a remote address.
/// </summary>
public static class ClashApi
{
    /// <summary>The port every Clash-compatible client defaults to for <c>external-controller</c>.</summary>
    public const int DefaultPort = 9090;

    public static readonly string DefaultHost = $"127.0.0.1:{DefaultPort}";

    /// <summary>Key used when a connection carries no usable chain.</summary>
    public const string UnknownNodeKey = "—";

    /// <summary>The address the sampler actually talks to: the user's, or the default.</summary>
    public static string EffectiveHost(string? host) => string.IsNullOrWhiteSpace(host) ? DefaultHost : host.Trim();

    /// <summary>
    /// Accepts "127.0.0.1:9090", "127.0.0.1", "http://host:9090" and "http://host:9090/"
    /// alike; the port defaults to 9090. Anything that is not http(s) is refused.
    /// </summary>
    public static Uri ConnectionsUrl(string host)
    {
        var trimmed = host.Trim();
        if (trimmed.Length == 0)
        {
            throw new ClashApiException(ClashFailure.InvalidUrl);
        }

        var hasScheme = trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                        || trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        if (!hasScheme && trimmed.Contains("://", StringComparison.Ordinal))
        {
            throw new ClashApiException(ClashFailure.InvalidUrl);
        }

        if (!Uri.TryCreate(hasScheme ? trimmed : "http://" + trimmed, UriKind.Absolute, out var parsed)
            || string.IsNullOrEmpty(parsed.Host)
            || parsed.Scheme is not ("http" or "https"))
        {
            throw new ClashApiException(ClashFailure.InvalidUrl);
        }

        // Uri reports the scheme's default port when none was written; only an explicit one
        // is kept, otherwise the Clash default applies.
        var explicitPort = !parsed.IsDefaultPort || HasExplicitPort(trimmed, parsed);
        var builder = new UriBuilder(parsed)
        {
            Port = explicitPort ? parsed.Port : DefaultPort,
            Path = "/connections",
            Query = string.Empty,
            Fragment = string.Empty,
            UserName = string.Empty,
            Password = string.Empty,
        };
        return builder.Uri;
    }

    private static bool HasExplicitPort(string text, Uri parsed)
    {
        var authority = text.Contains("://", StringComparison.Ordinal) ? text[(text.IndexOf("://", StringComparison.Ordinal) + 3)..] : text;
        var end = authority.IndexOfAny(['/', '?', '#']);
        if (end >= 0)
        {
            authority = authority[..end];
        }

        return authority.EndsWith($":{parsed.Port}", StringComparison.Ordinal);
    }

    /// <summary>Fetches a snapshot. <paramref name="secret"/> may be empty — sing-box only asks for one when configured.</summary>
    public static async Task<ClashSnapshot> FetchAsync(HttpClient client, string host, string secret, CancellationToken cancellation = default)
    {
        var url = ConnectionsUrl(host);
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("NetFluss/1.0");
        if (!string.IsNullOrEmpty(secret))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
        }

        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, cancellation).ConfigureAwait(false);
        }
        catch (TaskCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new ClashApiException(ClashFailure.TimedOut);
        }
        catch (HttpRequestException e) when (e.HttpRequestError == HttpRequestError.ConnectionError)
        {
            throw new ClashApiException(ClashFailure.Refused);
        }
        catch (HttpRequestException)
        {
            throw new ClashApiException(ClashFailure.RequestFailed);
        }

        using (response)
        {
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                throw new ClashApiException(ClashFailure.AuthFailed);
            }

            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw new ClashApiException(ClashFailure.HttpStatus, (int)response.StatusCode);
            }

            var body = await response.Content.ReadAsByteArrayAsync(cancellation).ConfigureAwait(false);
            return Parse(body);
        }
    }

    public static ClashSnapshot Parse(ReadOnlySpan<byte> json)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json.ToArray());
        }
        catch (JsonException)
        {
            throw new ClashApiException(ClashFailure.ParseError);
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new ClashApiException(ClashFailure.ParseError);
            }

            var hasUpload = root.TryGetProperty("uploadTotal", out var uploadElement);
            var hasDownload = root.TryGetProperty("downloadTotal", out var downloadElement);
            var uploadTotal = hasUpload ? Unsigned(uploadElement) : 0;
            var downloadTotal = hasDownload ? Unsigned(downloadElement) : 0;

            // An idle proxy has no open connections, so a missing list is only an error
            // when the totals are missing too.
            if (!root.TryGetProperty("connections", out var list) || list.ValueKind != JsonValueKind.Array)
            {
                if (!hasUpload && !hasDownload)
                {
                    throw new ClashApiException(ClashFailure.ParseError);
                }

                return new ClashSnapshot(uploadTotal, downloadTotal, []);
            }

            var connections = new List<ClashConnection>(list.GetArrayLength());
            foreach (var raw in list.EnumerateArray())
            {
                if (raw.ValueKind != JsonValueKind.Object
                    || !raw.TryGetProperty("id", out var idElement)
                    || idElement.ValueKind != JsonValueKind.String
                    || idElement.GetString() is not { Length: > 0 } id)
                {
                    continue;
                }

                var metadata = raw.TryGetProperty("metadata", out var meta) && meta.ValueKind == JsonValueKind.Object ? meta : default;
                connections.Add(new ClashConnection(
                    id,
                    Node(raw.TryGetProperty("chains", out var chains) ? chains : default),
                    raw.TryGetProperty("upload", out var up) ? Unsigned(up) : 0,
                    raw.TryGetProperty("download", out var down) ? Unsigned(down) : 0,
                    Text(metadata, "host"),
                    Text(metadata, "network"),
                    Text(metadata, "processPath")));
            }

            return new ClashSnapshot(uploadTotal, downloadTotal, connections);
        }
    }

    /// <summary>
    /// sing-box builds the chain entry-first and then reverses it, so element 0 is the outbound
    /// that actually egresses and the last is the selector that picked it. Grouping by the last
    /// would bucket everything under one selector — exactly not what per-node accounting is for.
    /// </summary>
    public static string Node(JsonElement chains)
    {
        if (chains.ValueKind != JsonValueKind.Array)
        {
            return UnknownNodeKey;
        }

        foreach (var entry in chains.EnumerateArray())
        {
            if (entry.ValueKind == JsonValueKind.String && entry.GetString() is { Length: > 0 } node)
            {
                return node;
            }
        }

        return UnknownNodeKey;
    }

    private static string Text(JsonElement owner, string name)
        => owner.ValueKind == JsonValueKind.Object && owner.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;

    private static ulong Unsigned(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Number when value.TryGetUInt64(out var number) => number,
        JsonValueKind.Number when value.TryGetDouble(out var real) && real > 0 => real >= ulong.MaxValue ? ulong.MaxValue : (ulong)real,
        JsonValueKind.String when ulong.TryParse(value.GetString(), out var parsed) => parsed,
        _ => 0,
    };
}

/// <summary>One proxy node's traffic in one sampling interval.</summary>
public readonly record struct NodeDelta(string Name, ulong DownloadBytes, ulong UploadBytes);

/// <summary>
/// Turns successive <c>/connections</c> snapshots into per-node byte deltas — port of the
/// macOS <c>ClashNodeAccumulator</c>.
///
/// <para>Connections carry cumulative counters and vanish the moment they close, so a
/// snapshot diff alone silently loses whatever a short-lived connection moved between two
/// polls — which matters when the figure tracks a paid quota. The process-wide totals are
/// monotonic, so whatever the per-connection deltas do not explain is booked to
/// <see cref="UnattributedKey"/> rather than dropped.</para>
/// </summary>
public sealed class ClashNodeAccumulator
{
    /// <summary>
    /// Bucket for traffic the per-connection diff cannot attribute: connections that opened
    /// and closed inside one interval, plus the DNS connections sing-box leaves out of the list
    /// but still counts in the totals.
    /// </summary>
    public const string UnattributedKey = "Unattributed";

    private Dictionary<string, (string Node, ulong Upload, ulong Download)> _previous = [];
    private ulong? _previousUploadTotal;
    private ulong? _previousDownloadTotal;

    /// <summary>
    /// Drops all carried state — when the feature is switched off, the address changes or a
    /// poll fails — so a gap is never billed to a node as one enormous delta.
    /// </summary>
    public void Reset()
    {
        _previous = [];
        _previousUploadTotal = null;
        _previousDownloadTotal = null;
    }

    /// <summary>
    /// Per-node bytes since the previous snapshot. The first snapshot after a reset only sets
    /// the baseline: its counters describe traffic from before NetFluss was looking.
    /// </summary>
    public IReadOnlyList<NodeDelta> Consume(ClashSnapshot snapshot)
    {
        var current = new Dictionary<string, (string Node, ulong Upload, ulong Download)>(snapshot.Connections.Count);
        var uploadByNode = new Dictionary<string, ulong>(StringComparer.Ordinal);
        var downloadByNode = new Dictionary<string, ulong>(StringComparer.Ordinal);
        var isBaseline = _previousUploadTotal is null && _previousDownloadTotal is null;

        // The client restarting resets its counters; a counter that went backwards is a fresh
        // baseline, not an underflow.
        var restarted = (_previousUploadTotal ?? 0) > snapshot.UploadTotal || (_previousDownloadTotal ?? 0) > snapshot.DownloadTotal;

        foreach (var connection in snapshot.Connections)
        {
            current[connection.Id] = (connection.Node, connection.UploadBytes, connection.DownloadBytes);
            if (isBaseline || restarted)
            {
                continue;
            }

            // A connection seen before contributes its growth; a new one everything it moved,
            // since it opened after the previous snapshot.
            var seen = _previous.TryGetValue(connection.Id, out var before) ? before : default;
            var upload = connection.UploadBytes - Math.Min(seen.Upload, connection.UploadBytes);
            var download = connection.DownloadBytes - Math.Min(seen.Download, connection.DownloadBytes);
            if (upload > 0)
            {
                uploadByNode[connection.Node] = uploadByNode.GetValueOrDefault(connection.Node) + upload;
            }

            if (download > 0)
            {
                downloadByNode[connection.Node] = downloadByNode.GetValueOrDefault(connection.Node) + download;
            }
        }

        var deltas = new List<NodeDelta>();
        if (!isBaseline && !restarted && _previousUploadTotal is { } previousUpload && _previousDownloadTotal is { } previousDownload)
        {
            var accountedUpload = uploadByNode.Values.Aggregate(0UL, (sum, value) => sum + value);
            var accountedDownload = downloadByNode.Values.Aggregate(0UL, (sum, value) => sum + value);
            var totalUpload = snapshot.UploadTotal - Math.Min(previousUpload, snapshot.UploadTotal);
            var totalDownload = snapshot.DownloadTotal - Math.Min(previousDownload, snapshot.DownloadTotal);
            var missingUpload = totalUpload > accountedUpload ? totalUpload - accountedUpload : 0;
            var missingDownload = totalDownload > accountedDownload ? totalDownload - accountedDownload : 0;
            if (missingUpload > 0 || missingDownload > 0)
            {
                deltas.Add(new NodeDelta(UnattributedKey, missingDownload, missingUpload));
            }
        }

        foreach (var node in uploadByNode.Keys.Union(downloadByNode.Keys).Order(StringComparer.Ordinal))
        {
            deltas.Add(new NodeDelta(node, downloadByNode.GetValueOrDefault(node), uploadByNode.GetValueOrDefault(node)));
        }

        _previous = current;
        _previousUploadTotal = snapshot.UploadTotal;
        _previousDownloadTotal = snapshot.DownloadTotal;
        return deltas;
    }
}
