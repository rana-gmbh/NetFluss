// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Net;
using System.Text;
using NetFluss.Core;
using Xunit;

namespace NetFluss.Core.Tests;

/// <summary>
/// Per-proxy-node statistics from the Clash API — ports of the macOS 2.7 ClashAPIMonitor and
/// ClashNodeAccumulator tests. The accumulator is the part a quota depends on, so it gets the
/// most attention: nothing may be lost, and nothing may be billed twice.
/// </summary>
public class ClashApiTests
{
    [Theory]
    [InlineData("127.0.0.1:9090", "http://127.0.0.1:9090/connections")]
    [InlineData("127.0.0.1", "http://127.0.0.1:9090/connections")]
    [InlineData("http://127.0.0.1:9097/", "http://127.0.0.1:9097/connections")]
    [InlineData("http://router.lan:80", "http://router.lan/connections")]
    [InlineData("https://clash.example.com", "https://clash.example.com:9090/connections")]
    [InlineData("  localhost:1234  ", "http://localhost:1234/connections")]
    [InlineData("[::1]:9090", "http://[::1]:9090/connections")]
    [InlineData("http://user:pw@127.0.0.1:9090/ui?x=1#y", "http://127.0.0.1:9090/connections")]
    public void ConnectionsUrl_AcceptsTheUsualSpellings(string host, string expected)
        => Assert.Equal(expected, ClashApi.ConnectionsUrl(host).ToString());

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("ftp://127.0.0.1:9090")]
    [InlineData("file:///C:/x")]
    public void ConnectionsUrl_RefusesTheRest(string host)
        => Assert.Equal(ClashFailure.InvalidUrl, Assert.Throws<ClashApiException>(() => ClashApi.ConnectionsUrl(host)).Failure);

    [Fact]
    public void EffectiveHost_DefaultsToLoopback9090()
    {
        Assert.Equal("127.0.0.1:9090", ClashApi.EffectiveHost(null));
        Assert.Equal("127.0.0.1:9090", ClashApi.EffectiveHost("  "));
        Assert.Equal("10.0.0.1:9097", ClashApi.EffectiveHost(" 10.0.0.1:9097 "));
    }

    private const string Sample = """
        {
          "downloadTotal": 5000,
          "uploadTotal": "700",
          "connections": [
            { "id": "a", "upload": 100, "download": 1000, "chains": ["HK-01", "Auto", "Proxy"],
              "metadata": { "host": "example.com", "network": "tcp", "processPath": "C:\\app.exe" } },
            { "id": "b", "upload": 50, "download": 400, "chains": ["", "JP-02"] },
            { "id": "c", "upload": 1, "download": 2 },
            { "upload": 9, "download": 9, "chains": ["ignored"] }
          ]
        }
        """;

    [Fact]
    public void Parse_ReadsTotalsAndConnections()
    {
        var snapshot = ClashApi.Parse(Encoding.UTF8.GetBytes(Sample));

        Assert.Equal(5000UL, snapshot.DownloadTotal);
        Assert.Equal(700UL, snapshot.UploadTotal);
        Assert.Equal(3, snapshot.Connections.Count);
        Assert.Equal(new ClashConnection("a", "HK-01", 100, 1000, "example.com", "tcp", @"C:\app.exe"), snapshot.Connections[0]);
    }

    /// <summary>Element 0 of the chain is the outbound that egresses; the last is only the selector.</summary>
    [Fact]
    public void Parse_UsesTheFirstNonEmptyChainEntry()
    {
        var snapshot = ClashApi.Parse(Encoding.UTF8.GetBytes(Sample));

        Assert.Equal("JP-02", snapshot.Connections[1].Node);
        Assert.Equal(ClashApi.UnknownNodeKey, snapshot.Connections[2].Node);
    }

    [Fact]
    public void Parse_AcceptsAnIdleProxy()
    {
        var snapshot = ClashApi.Parse("""{ "downloadTotal": 1, "uploadTotal": 2, "connections": null }"""u8);
        Assert.Empty(snapshot.Connections);
        Assert.Equal(2UL, snapshot.UploadTotal);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{}")]
    public void Parse_RejectsWhatIsNotASnapshot(string json)
        => Assert.Equal(ClashFailure.ParseError, Assert.Throws<ClashApiException>(() => ClashApi.Parse(Encoding.UTF8.GetBytes(json))).Failure);

    private sealed class Stub(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public HttpRequestMessage? Last { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Last = request;
            return Task.FromResult(answer(request));
        }
    }

    [Fact]
    public async Task Fetch_SendsTheSecretAsABearerToken()
    {
        var stub = new Stub(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Sample) });
        using var client = new HttpClient(stub);

        var snapshot = await ClashApi.FetchAsync(client, "127.0.0.1:9090", "s3cret");

        Assert.Equal(3, snapshot.Connections.Count);
        Assert.Equal("Bearer", stub.Last!.Headers.Authorization!.Scheme);
        Assert.Equal("s3cret", stub.Last.Headers.Authorization.Parameter);
        Assert.Equal("http://127.0.0.1:9090/connections", stub.Last.RequestUri!.ToString());
    }

    [Fact]
    public async Task Fetch_WithoutASecretSendsNoAuthorization()
    {
        var stub = new Stub(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Sample) });
        using var client = new HttpClient(stub);

        await ClashApi.FetchAsync(client, "127.0.0.1", string.Empty);

        Assert.Null(stub.Last!.Headers.Authorization);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, ClashFailure.AuthFailed)]
    [InlineData(HttpStatusCode.Forbidden, ClashFailure.AuthFailed)]
    [InlineData(HttpStatusCode.NotFound, ClashFailure.HttpStatus)]
    public async Task Fetch_ClassifiesRefusals(HttpStatusCode status, ClashFailure expected)
    {
        using var client = new HttpClient(new Stub(_ => new HttpResponseMessage(status)));

        var error = await Assert.ThrowsAsync<ClashApiException>(() => ClashApi.FetchAsync(client, "127.0.0.1", string.Empty));

        Assert.Equal(expected, error.Failure);
        Assert.False(string.IsNullOrWhiteSpace(error.Describe()));
    }

    [Fact]
    public async Task Fetch_NothingListening_IsRefused()
    {
        using var client = new HttpClient(new Stub(_ => throw new HttpRequestException(HttpRequestError.ConnectionError, "refused")));

        var error = await Assert.ThrowsAsync<ClashApiException>(() => ClashApi.FetchAsync(client, "127.0.0.1", string.Empty));

        Assert.Equal(ClashFailure.Refused, error.Failure);
    }

    /// <summary>The real socket path: a closed loopback port reads as "nothing listening", not a generic failure.</summary>
    [Fact]
    public async Task Fetch_ClosedLoopbackPort_IsRefused()
    {
        var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();

        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(5) };
        var error = await Assert.ThrowsAsync<ClashApiException>(() => ClashApi.FetchAsync(client, $"127.0.0.1:{port}", string.Empty));

        Assert.Equal(ClashFailure.Refused, error.Failure);
    }
}

public class ClashNodeAccumulatorTests
{
    private static ClashConnection Connection(string id, string node, ulong up, ulong down)
        => new(id, node, up, down, string.Empty, "tcp", string.Empty);

    private static ClashSnapshot Snapshot(ulong upTotal, ulong downTotal, params ClashConnection[] connections)
        => new(upTotal, downTotal, connections);

    /// <summary>Counters that predate NetFluss looking are not traffic it saw.</summary>
    [Fact]
    public void FirstSnapshot_IsOnlyABaseline()
    {
        var accumulator = new ClashNodeAccumulator();
        Assert.Empty(accumulator.Consume(Snapshot(100, 1000, Connection("a", "HK", 100, 1000))));
    }

    [Fact]
    public void GrowthIsBookedToTheNode()
    {
        var accumulator = new ClashNodeAccumulator();
        accumulator.Consume(Snapshot(100, 1000, Connection("a", "HK", 100, 1000)));

        var deltas = accumulator.Consume(Snapshot(150, 1600, Connection("a", "HK", 150, 1600)));

        Assert.Equal([new NodeDelta("HK", 600, 50)], deltas);
    }

    /// <summary>A connection that opened since the last poll brings everything it moved.</summary>
    [Fact]
    public void NewConnection_CountsInFull()
    {
        var accumulator = new ClashNodeAccumulator();
        accumulator.Consume(Snapshot(0, 0));

        var deltas = accumulator.Consume(Snapshot(10, 200, Connection("b", "JP", 10, 200)));

        Assert.Equal([new NodeDelta("JP", 200, 10)], deltas);
    }

    /// <summary>
    /// A connection that opened and closed between two polls never appears in a list; the
    /// totals still moved, and that remainder is kept as Unattributed rather than lost.
    /// </summary>
    [Fact]
    public void WhatTheConnectionsDoNotExplain_IsUnattributed()
    {
        var accumulator = new ClashNodeAccumulator();
        accumulator.Consume(Snapshot(100, 1000, Connection("a", "HK", 100, 1000)));

        var deltas = accumulator.Consume(Snapshot(400, 5000, Connection("a", "HK", 150, 1600)));

        Assert.Contains(new NodeDelta("HK", 600, 50), deltas);
        Assert.Contains(new NodeDelta(ClashNodeAccumulator.UnattributedKey, 3400, 250), deltas);
        Assert.Equal(4000UL, deltas.Aggregate(0UL, (sum, d) => sum + d.DownloadBytes));
        Assert.Equal(300UL, deltas.Aggregate(0UL, (sum, d) => sum + d.UploadBytes));
    }

    [Fact]
    public void NodesAreSummedAcrossConnections()
    {
        var accumulator = new ClashNodeAccumulator();
        accumulator.Consume(Snapshot(0, 0));

        var deltas = accumulator.Consume(Snapshot(30, 300,
            Connection("a", "HK", 10, 100),
            Connection("b", "HK", 20, 200)));

        Assert.Equal([new NodeDelta("HK", 300, 30)], deltas);
    }

    /// <summary>The client restarting resets its counters; that is a new baseline, not an underflow.</summary>
    [Fact]
    public void CountersGoingBackwards_Rebaseline()
    {
        var accumulator = new ClashNodeAccumulator();
        accumulator.Consume(Snapshot(100, 1000, Connection("a", "HK", 100, 1000)));

        Assert.Empty(accumulator.Consume(Snapshot(5, 50, Connection("z", "HK", 5, 50))));
        Assert.Equal([new NodeDelta("HK", 50, 5)], accumulator.Consume(Snapshot(10, 100, Connection("z", "HK", 10, 100))));
    }

    [Fact]
    public void Reset_ForgetsTheBaseline()
    {
        var accumulator = new ClashNodeAccumulator();
        accumulator.Consume(Snapshot(100, 1000, Connection("a", "HK", 100, 1000)));
        accumulator.Reset();

        Assert.Empty(accumulator.Consume(Snapshot(900, 9000, Connection("a", "HK", 900, 9000))));
    }
}

public class NodeStatisticsStoreTests
{
    [Fact]
    public void NodesAppearInTheReport_BiggestFirst_Uncapped()
    {
        var store = new StatisticsStore(new StatisticsArchive());
        var now = new DateTime(2026, 11, 9, 12, 30, 0);
        var deltas = Enumerable.Range(1, 12).Select(i => new NodeDelta($"node-{i:00}", (ulong)i * 100, (ulong)i)).ToList();

        store.RecordNodeDeltas(deltas, now);
        var report = store.Report(StatisticsRange.LastHour, now, new Dictionary<string, string>(), new HashSet<string>(), excludeTunnels: false);

        Assert.Equal(12, report.Nodes.Count);
        Assert.Equal("node-12", report.Nodes[0].Name);
        Assert.Equal(1212UL, report.Nodes[0].TotalBytes);
    }

    [Fact]
    public void NodeHistory_RoundTripsAndLoadsFromOlderArchives()
    {
        var path = Path.Combine(Path.GetTempPath(), $"netfluss-nodes-{Guid.NewGuid():N}.json");
        try
        {
            // An archive written before 2.7 has no node fields at all.
            File.WriteAllText(path, """{"createdAt":"2026-01-01T00:00:00+00:00","adapterDaily":{}}""");
            var store = new StatisticsStore(path);
            var now = DateTime.Now;
            store.RecordNodeDeltas([new NodeDelta("HK", 500, 50)], now);
            store.Flush(force: true, now);

            var reloaded = new StatisticsStore(path).Report(StatisticsRange.Last7Days, now, new Dictionary<string, string>(), new HashSet<string>(), false);
            Assert.Equal([new NodeRow("HK", 500, 50)], reloaded.Nodes);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
