// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.IO.Pipes;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.Service;

/// <summary>
/// The helper's whole job: serve the pipe, run the trace while someone is subscribed, and
/// carry out the two privileged commands.
///
/// <para><b>Who may connect.</b> The pipe admits LocalSystem, Administrators and
/// <em>interactive</em> users — people signed in at the machine. That excludes network
/// logons and other services. It is the same trust the macOS helper extends: once an
/// administrator has installed it, the person at the keyboard can change DNS without being
/// asked again, which is the point of installing it.</para>
///
/// <para><b>What they may ask.</b> Nothing is free-form. DNS servers must round-trip through
/// <see cref="DnsValidator"/>, and adapters are named by interface GUID and resolved here
/// against the interfaces Windows reports — a client never supplies a string that reaches a
/// command line.</para>
/// </summary>
internal sealed class HelperServer : IDisposable
{
    private const int MaxClients = 8;
    private const int MaxFlowsPerMessage = 400;

    private static readonly string Version =
        BuildVersion.Of(Assembly.GetExecutingAssembly());

    private readonly string _pipeName;
    private readonly CancellationTokenSource _stop = new();
    private readonly object _gate = new();
    private readonly List<Client> _clients = [];
    private readonly ProcessNames _names = new();
    private readonly VpnTunnels _vpn = new();

    /// <summary>When each adapter was last restarted, for the cooldown between restarts.</summary>
    private readonly Dictionary<string, long> _restarts = new(StringComparer.OrdinalIgnoreCase);

    private const long AdapterRestartCooldownMs = 15_000;
    private KernelNetworkTrace? _trace;
    private Timer? _sampler;
    private string _traceStatus = "Idle";

    /// <summary>The last trace's diagnostics, kept after it stops.</summary>
    private string? _traceDetail;

    private long _lastRestart;

    // Progress of the running trace's consumer: events delivered, and when that last grew.
    private long _lastDelivered;
    private long _lastDelivery;

    internal HelperServer(string pipeName) => _pipeName = pipeName;

    /// <summary>Diagnostic output; the console host prints it, the service discards it.</summary>
    internal Action<string>? Log
    {
        get => _log;
        set
        {
            _log = value;
            _vpn.Log = value;
        }
    }

    private Action<string>? _log;

    internal void Start() => _ = Task.Run(AcceptLoopAsync);

    private async Task AcceptLoopAsync()
    {
        var first = true;

        while (!_stop.IsCancellationRequested)
        {
            NamedPipeServerStream server;
            try
            {
                server = NamedPipeServerStreamAcl.Create(
                    _pipeName,
                    PipeDirection.InOut,
                    MaxClients,
                    PipeTransmissionMode.Byte,
                    // FirstPipeInstance on the first one: if another process already owns the
                    // name, this fails loudly rather than letting clients be served by an
                    // impostor that squatted on it.
                    PipeOptions.Asynchronous | (first ? PipeOptions.FirstPipeInstance : PipeOptions.None),
                    4096,
                    4096,
                    Security());
                first = false;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Log?.Invoke($"cannot create pipe instance: {e.Message}");
                await Task.Delay(1000);
                continue;
            }

            try
            {
                await server.WaitForConnectionAsync(_stop.Token);
            }
            catch (OperationCanceledException)
            {
                await server.DisposeAsync();
                return;
            }
            catch (Exception e)
            {
                // A client that connects and leaves before the call completes (ERROR_NO_DATA),
                // or any other fault, must cost this one instance — not the loop. Faulting
                // here would leave a service that reports Running and never answers again.
                Log?.Invoke($"pipe connection failed: {e.Message}");
                await server.DisposeAsync();
                await Task.Delay(250);
                continue;
            }

            var client = new Client(server);
            lock (_gate)
            {
                _clients.Add(client);
            }

            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private static PipeSecurity Security()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));

        // Read and write only — deliberately not CreateNewInstance, which would let a user
        // open their own server end under this name and impersonate the helper.
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.InteractiveSid, null),
            PipeAccessRights.ReadWrite,
            AccessControlType.Allow));

        // In console mode the server is an ordinary user, who needs to be able to open the
        // next instance of their own pipe. As the service this is LocalSystem, already above.
        using var identity = WindowsIdentity.GetCurrent();
        if (identity.User is { } user && !user.IsWellKnown(WellKnownSidType.LocalSystemSid))
        {
            security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
        }

        return security;
    }

    private async Task ServeAsync(Client client)
    {
        Log?.Invoke("client connected");
        try
        {
            using var reader = new StreamReader(client.Pipe, Encoding.UTF8);
            while (!_stop.IsCancellationRequested)
            {
                var line = await reader.ReadLineAsync(_stop.Token);
                if (line is null)
                {
                    break;
                }

                if (line.Length > HelperProtocol.MaximumLineLength)
                {
                    continue;
                }

                var request = HelperProtocol.Deserialize<HelperRequest>(line);
                if (request is null)
                {
                    continue;
                }

                await HandleAsync(client, request);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException)
        {
        }
        finally
        {
            Remove(client);
            Log?.Invoke("client disconnected");
        }
    }

    private async Task HandleAsync(Client client, HelperRequest request)
    {
        switch (request.Op)
        {
            case "hello":
                await client.SendAsync(new HelperMessage
                {
                    Type = "hello",
                    Version = HelperProtocol.Version,
                    HelperVersion = Version,
                    TraceStatus = _traceStatus,
                    TraceDetail = _trace?.Diagnostics ?? _traceDetail,
                });
                break;

            case "subscribe":
                client.Subscribed = true;
                client.WantsFlows = request.Flows;
                UpdateTrace();
                break;

            case "unsubscribe":
                client.Subscribed = false;
                client.WantsFlows = false;
                UpdateTrace();
                break;

            case "setDns":
                await client.SendAsync(SetDns(request) with { Id = request.Id });
                break;

            case "restartAdapter":
                await client.SendAsync(await RestartAdapterAsync(request) with { Id = request.Id });
                break;

            case "vpnStart":
                await client.SendAsync(await _vpn.StartAsync(request) with { Id = request.Id });
                break;

            case "vpnStop":
                await client.SendAsync(await _vpn.StopAsync(request.Handle) with { Id = request.Id });
                break;

            case "vpnLog":
                await client.SendAsync(await _vpn.ReadLogAsync(request.Handle) with { Id = request.Id });
                break;
        }
    }

    /// <summary>Starts the trace for the first subscriber and stops it after the last.</summary>
    private void UpdateTrace()
    {
        lock (_gate)
        {
            var wanted = _clients.Any(c => c.Subscribed);

            if (wanted && _trace is null)
            {
                var trace = new KernelNetworkTrace();
                var status = trace.Start();
                _traceStatus = status.ToString();
                Log?.Invoke($"trace start: {status} (error {trace.LastError})");

                if (status == TraceStatus.Running)
                {
                    _trace = trace;
                    _lastDelivered = 0;
                    _lastDelivery = System.Diagnostics.Stopwatch.GetTimestamp();
                    _sampler = new Timer(_ => Sample(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
                }
                else
                {
                    _traceDetail = trace.Diagnostics;
                    trace.Dispose();

                    // Say so, rather than leave subscribers waiting on traffic that will
                    // never come — the app shows this instead of "Gathering data…" forever.
                    var failure = new HelperMessage { Type = "status", TraceStatus = _traceStatus, Message = $"error {trace.LastError}" };
                    foreach (var client in _clients.Where(c => c.Subscribed))
                    {
                        _ = client.SendAsync(failure);
                    }
                }
            }
            else if (!wanted && _trace is not null)
            {
                _sampler?.Dispose();
                _sampler = null;
                _traceDetail = _trace.Diagnostics;
                _trace.Dispose();
                _trace = null;
                _traceStatus = "Idle";
                Log?.Invoke("trace stopped");
            }
        }
    }

    /// <summary>
    /// The consumer of a running trace stopped on its own — its session was stopped from
    /// outside, or ProcessTrace failed — or stalled: nothing delivered while the session
    /// fills up. Start over rather than stream empty samples forever, though not more often
    /// than <paramref name="interval"/>, so a session something keeps breaking cannot spin.
    /// </summary>
    private bool RestartTrace(KernelNetworkTrace dead, string reason, TimeSpan interval)
    {
        lock (_gate)
        {
            if (_trace != dead ||
                System.Diagnostics.Stopwatch.GetElapsedTime(_lastRestart) < interval)
            {
                return false;
            }

            _lastRestart = System.Diagnostics.Stopwatch.GetTimestamp();
            _traceDetail = dead.Diagnostics;
            Log?.Invoke($"trace {reason}: {_traceDetail}; restarting");
            _sampler?.Dispose();
            _sampler = null;
            dead.Dispose();
            _trace = null;
        }

        UpdateTrace();
        return true;
    }

    private void Sample()
    {
        KernelNetworkTrace? trace;
        List<Client> subscribers;
        lock (_gate)
        {
            trace = _trace;
            subscribers = _clients.Where(c => c.Subscribed).ToList();
        }

        if (trace is null || subscribers.Count == 0)
        {
            return;
        }

        var delivered = trace.DeliveredCount;
        if (delivered != _lastDelivered)
        {
            _lastDelivered = delivered;
            _lastDelivery = System.Diagnostics.Stopwatch.GetTimestamp();
        }

        if (trace.ConsumerExited && RestartTrace(trace, "consumer exited", TimeSpan.FromSeconds(10)))
        {
            return;
        }

        // Any TCP or UDP traffic raises events, so 20 s without one almost always means the
        // consumer is not reading. On a truly idle machine the restart is harmless.
        if (System.Diagnostics.Stopwatch.GetElapsedTime(_lastDelivery) > TimeSpan.FromSeconds(20) &&
            RestartTrace(trace, "stalled", TimeSpan.FromSeconds(60)))
        {
            return;
        }

        var snapshot = trace.TakeSnapshot();

        var processes = snapshot.ByProcess
            .Select(p => new HelperProcess(p.Key, _names.Resolve(p.Key), p.Value.Received, p.Value.Sent))
            .ToList();

        List<HelperFlow>? flows = null;
        if (subscribers.Any(c => c.WantsFlows))
        {
            flows = snapshot.ByFlow
                .OrderByDescending(f => f.Value.Received + f.Value.Sent)
                .Take(MaxFlowsPerMessage)
                .Select(f => new HelperFlow(
                    f.Key.ProcessId,
                    f.Key.Protocol == TraceProtocol.Udp ? "udp" : "tcp",
                    f.Key.LocalAddress.ToString(),
                    f.Key.LocalPort,
                    f.Key.RemoteAddress.ToString(),
                    f.Key.RemotePort,
                    f.Value.Received,
                    f.Value.Sent))
                .ToList();

            // Flow owners need names too, even ones with no per-process entry this tick.
            foreach (var pid in flows.Select(f => f.Pid).Distinct())
            {
                if (processes.All(p => p.Pid != pid))
                {
                    processes.Add(new HelperProcess(pid, _names.Resolve(pid), 0, 0));
                }
            }
        }

        var elapsed = (long)snapshot.Elapsed.TotalMilliseconds;
        var withFlows = new HelperMessage { Type = "traffic", ElapsedMs = elapsed, Processes = processes, Flows = flows };
        var withoutFlows = withFlows with { Flows = null };

        foreach (var client in subscribers)
        {
            _ = client.SendAsync(client.WantsFlows ? withFlows : withoutFlows);
        }
    }

    private HelperMessage SetDns(HelperRequest request)
    {
        var servers = request.Servers ?? [];
        var validation = DnsValidator.Validate(servers);
        if (!validation.IsValid)
        {
            return Result(false, validation.Error);
        }

        if (!TryResolveAdapter(request.Adapter, out var guid, out _))
        {
            return Result(false, "No such adapter.");
        }

        var status = InterfaceDns.Set(guid, servers);
        Log?.Invoke($"setDns {guid} [{string.Join(", ", servers)}] -> {status}");
        return status == 0 ? Result(true, null) : Result(false, $"Windows error {status}.");
    }

    private async Task<HelperMessage> RestartAdapterAsync(HelperRequest request)
    {
        if (!TryResolveAdapter(request.Adapter, out _, out var name))
        {
            return Result(false, "No such adapter.");
        }

        // The name came from Windows, not from the client, but it still reaches a command
        // line — so it must not be able to close its own quotes.
        if (name.Contains('"') || name.Contains('%'))
        {
            return Result(false, "That adapter's name cannot be used from a script.");
        }

        // Any signed-in user may ask for this, and each request takes the adapter offline for
        // a moment; without a pause between them, a script could keep a PC off the network.
        lock (_restarts)
        {
            var now = Environment.TickCount64;
            if (_restarts.TryGetValue(name, out var last) && now - last < AdapterRestartCooldownMs)
            {
                return Result(false, "That adapter was restarted a moment ago.");
            }

            _restarts[name] = now;
        }

        foreach (var state in new[] { "disabled", "enabled" })
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "netsh.exe"),
                Arguments = $"interface set interface name=\"{name}\" admin={state}",
                CreateNoWindow = true,
                UseShellExecute = false,
            });

            if (process is null)
            {
                return Result(false, "Could not run netsh.");
            }

            await process.WaitForExitAsync();
            if (state == "disabled")
            {
                await Task.Delay(1500);
            }
        }

        return Result(true, null);
    }

    private static bool TryResolveAdapter(string? id, out Guid guid, out string name)
    {
        name = string.Empty;
        if (!Guid.TryParse(id, out guid))
        {
            return false;
        }

        var wanted = guid;
        var nic = NetworkInterface.GetAllNetworkInterfaces()
            .FirstOrDefault(n => Guid.TryParse(n.Id, out var nicId) && nicId == wanted);

        if (nic is null)
        {
            return false;
        }

        name = nic.Name;
        return true;
    }

    private static HelperMessage Result(bool ok, string? message) => new() { Type = "result", Ok = ok, Message = message };

    private void Remove(Client client)
    {
        lock (_gate)
        {
            _clients.Remove(client);
        }

        client.Dispose();
        UpdateTrace();
    }

    public void Dispose()
    {
        _stop.Cancel();
        _vpn.Dispose();

        List<Client> clients;
        lock (_gate)
        {
            clients = [.. _clients];
            _clients.Clear();
        }

        foreach (var client in clients)
        {
            client.Dispose();
        }

        UpdateTrace();
    }

    private sealed class Client(NamedPipeServerStream pipe) : IDisposable
    {
        private readonly SemaphoreSlim _write = new(1, 1);
        private readonly StreamWriter _writer = new(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };

        internal NamedPipeServerStream Pipe { get; } = pipe;

        internal volatile bool Subscribed;
        internal volatile bool WantsFlows;

        internal async Task SendAsync(HelperMessage message)
        {
            // A client that stopped reading must not stall the sampler for everyone else;
            // anything still queued after a second is dropped with the client.
            if (!await _write.WaitAsync(TimeSpan.FromSeconds(1)))
            {
                return;
            }

            try
            {
                await _writer.WriteLineAsync(HelperProtocol.Serialize(message));
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException)
            {
            }
            finally
            {
                _write.Release();
            }
        }

        public void Dispose()
        {
            try
            {
                Pipe.Dispose();
            }
            catch (IOException)
            {
            }
        }
    }
}
