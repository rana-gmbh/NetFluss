// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Reflection;
using System.Text;
using System.Windows.Threading;
using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.App;

/// <summary>
/// The app's end of the helper pipe. Connects lazily, reconnects on its own, and marshals
/// every event onto the UI thread so consumers never see a pool thread.
///
/// <para>Absence is a normal state, not an error: most installs will run without the helper
/// for a long time, and every feature that does not need it must keep working. Nothing here
/// throws for a missing helper; <see cref="IsConnected"/> simply stays false.</para>
/// </summary>
internal sealed class HelperClient : IDisposable
{
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(5);

    private readonly Dispatcher _dispatcher;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<HelperMessage>> _pending = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly CancellationTokenSource _stop = new();
    private NamedPipeClientStream? _pipe;
    private StreamWriter? _writer;
    private int _nextId;
    private bool _connecting;
    private bool _subscribed;
    private bool _wantFlows;

    internal HelperClient(Dispatcher dispatcher) => _dispatcher = dispatcher;

    internal event EventHandler? ConnectionChanged;

    internal event EventHandler<TrafficSample>? TrafficReceived;

    internal bool IsConnected { get; private set; }

    internal string? HelperVersion { get; private set; }

    /// <summary>The trace status inside the helper, e.g. "Running" or "Failed".</summary>
    internal string? HelperTraceStatus { get; private set; }

    /// <summary>The build this app expects the helper to be. A mismatch offers an update.</summary>
    internal static string AppVersion { get; } =
        BuildVersion.Of(Assembly.GetExecutingAssembly());

    internal bool IsCurrentVersion => HelperVersion == AppVersion;

    /// <summary>
    /// The helper comes from a newer NetFluss than this one: an older copy of the app run after
    /// an update, or a development build beside a released helper. "Out of date" would be
    /// the wrong way round, and "Update helper" would downgrade it.
    /// </summary>
    internal bool IsNewerThanApp => HelperVersion is { } version && UpdateLookup.IsNewer(version, AppVersion);

    /// <summary>The protocol the helper speaks; 2 added the VPN operations.</summary>
    internal int HelperProtocolVersion { get; private set; }

    /// <summary>
    /// Whether the helper can run VPN tunnels. Checked separately from the build: an older
    /// helper still serves traffic perfectly well, and must not switch Top Apps off.
    /// </summary>
    internal bool SupportsVpn => IsConnected && HelperProtocolVersion >= 2;

    /// <summary>Starts connecting in the background if not already connected or trying.</summary>
    internal void EnsureConnecting()
    {
        if (IsConnected || _connecting)
        {
            return;
        }

        _connecting = true;
        _ = Task.Run(ConnectLoopAsync);
    }

    /// <summary>One connection attempt, awaited — for "is the helper there?" questions.</summary>
    internal async Task<bool> ProbeAsync(TimeSpan timeout)
    {
        EnsureConnecting();
        var deadline = DateTime.UtcNow + timeout;
        while (!IsConnected && DateTime.UtcNow < deadline)
        {
            await Task.Delay(100);
        }

        return IsConnected;
    }

    internal void Subscribe(bool flows = false)
    {
        _subscribed = true;
        _wantFlows |= flows;
        _ = SendAsync(new HelperRequest { Op = "subscribe", Flows = _wantFlows });
    }

    /// <summary>Asks for per-flow detail on top of per-process totals (the Network Slice).</summary>
    internal void SetWantsFlows(bool flows)
    {
        if (_wantFlows == flows)
        {
            return;
        }

        _wantFlows = flows;
        if (_subscribed)
        {
            _ = SendAsync(new HelperRequest { Op = "subscribe", Flows = flows });
        }
    }

    internal void Unsubscribe()
    {
        _subscribed = false;
        _ = SendAsync(new HelperRequest { Op = "unsubscribe" });
    }

    /// <summary>Asks the helper to set DNS, returning its verdict, or null when it is not there.</summary>
    internal async Task<HelperMessage?> RequestAsync(HelperRequest request, TimeSpan timeout)
    {
        if (!IsConnected)
        {
            return null;
        }

        var id = Interlocked.Increment(ref _nextId);
        var completion = new TaskCompletionSource<HelperMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = completion;

        try
        {
            if (!await SendAsync(request with { Id = id }))
            {
                return null;
            }

            var finished = await Task.WhenAny(completion.Task, Task.Delay(timeout));
            return finished == completion.Task && completion.Task.IsCompletedSuccessfully ? completion.Task.Result : null;
        }
        finally
        {
            _pending.TryRemove(id, out _);
        }
    }

    private async Task ConnectLoopAsync()
    {
        try
        {
            while (!_stop.IsCancellationRequested && !IsConnected)
            {
                try
                {
                    if (await TryConnectAsync())
                    {
                        return;
                    }
                }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    // A helper stopped or updated mid-handshake, or one that never answers:
                    // drop what was opened and try again, rather than end the loop and with
                    // it every later attempt (_connecting would stay set for good).
                    Disconnect();
                }

                await Task.Delay(RetryInterval, _stop.Token);
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            _connecting = false;
        }
    }

    /// <summary>
    /// Development only: a helper run with "NetFluss.Service console" is no service, so the
    /// identity check below would refuse it.
    /// </summary>
    private static bool ConsoleHelperAllowed => Environment.GetEnvironmentVariable("NETFLUSS_ALLOW_CONSOLE_HELPER") == "1";

    private async Task<bool> TryConnectAsync()
    {
        // The helper is a service. When it is not running there is no pipe to wait for, and
        // ConnectAsync would spin on CreateFile for its whole timeout every few seconds — for
        // every user without the helper, all day. Asking the service manager costs nothing.
        var servicePid = ServiceStatus.ProcessId(HelperProtocol.ServiceName);
        if (servicePid is null && !ConsoleHelperAllowed)
        {
            return false;
        }

        var pipe = new NamedPipeClientStream(".", HelperProtocol.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            await pipe.ConnectAsync(500, _stop.Token);
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            await pipe.DisposeAsync();
            return false;
        }

        // Only NetFluss's own service may answer. Any program of this user's can create a pipe
        // of this name before the service does and pose as the helper: it would be sent VPN
        // configurations and could report privileged actions done that were not.
        if (!ConsoleHelperAllowed && ServiceStatus.PipeServerProcessId(pipe.SafePipeHandle) != servicePid)
        {
            await pipe.DisposeAsync();
            return false;
        }

        _pipe = pipe;
        _writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };

        var reader = new StreamReader(pipe, Encoding.UTF8);
        if (!await SendAsync(new HelperRequest { Op = "hello" }))
        {
            Disconnect();
            return false;
        }

        // The hello answer carries the versions; nothing counts as connected without it.
        // Bounded: a pipe that accepts and never answers must not hold the loop forever.
        var line = await ReadLineAsync(reader).WaitAsync(TimeSpan.FromSeconds(5), _stop.Token);
        var hello = line is null ? null : HelperProtocol.Deserialize<HelperMessage>(line);
        if (hello is not { Type: "hello" })
        {
            Disconnect();
            return false;
        }

        HelperVersion = hello.HelperVersion;
        HelperProtocolVersion = hello.Version;
        HelperTraceStatus = hello.TraceStatus;
        IsConnected = true;
        Post(() => ConnectionChanged?.Invoke(this, EventArgs.Empty));

        if (_subscribed)
        {
            _ = SendAsync(new HelperRequest { Op = "subscribe", Flows = _wantFlows });
        }

        _ = Task.Run(() => ReadLoopAsync(reader));
        return true;
    }

    private async Task ReadLoopAsync(StreamReader reader)
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                var line = await ReadLineAsync(reader);
                if (line is null)
                {
                    break;
                }

                var message = HelperProtocol.Deserialize<HelperMessage>(line);
                if (message is null)
                {
                    continue;
                }

                switch (message.Type)
                {
                    case "traffic":
                        var sample = ToSample(message);
                        Post(() => TrafficReceived?.Invoke(this, sample));
                        break;

                    case "result":
                        if (_pending.TryGetValue(message.Id, out var completion))
                        {
                            completion.TrySetResult(message);
                        }

                        break;

                    case "hello":
                    case "status":
                        HelperTraceStatus = message.TraceStatus;
                        Post(() => ConnectionChanged?.Invoke(this, EventArgs.Empty));
                        break;
                }
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            // Anything else would end this loop unnoticed, leaving a connection that looks
            // alive and delivers nothing. Record it and reconnect instead.
            CrashLog.Write("helper", e);
        }

        Disconnect();
    }

    private static async Task<string?> ReadLineAsync(StreamReader reader)
    {
        var line = await reader.ReadLineAsync();
        return line is { Length: > HelperProtocol.MaximumLineLength } ? string.Empty : line;
    }

    private static TrafficSample ToSample(HelperMessage message)
    {
        var processes = (message.Processes ?? [])
            .Select(p => new ProcessBytes(p.Pid, p.Name, p.Rx, p.Tx))
            .ToList();

        var names = new Dictionary<int, string>();
        foreach (var process in processes)
        {
            names.TryAdd(process.ProcessId, process.Name);
        }

        var flows = new Dictionary<FlowKey, (long Received, long Sent)>();
        foreach (var flow in message.Flows ?? [])
        {
            if (!IPAddress.TryParse(flow.Local, out var local) || !IPAddress.TryParse(flow.Remote, out var remote))
            {
                continue;
            }

            var key = new FlowKey(
                flow.Pid,
                flow.Proto == "udp" ? TraceProtocol.Udp : TraceProtocol.Tcp,
                local,
                flow.LocalPort,
                remote,
                flow.RemotePort);

            flows[key] = (flow.Rx, flow.Tx);
        }

        return new TrafficSample(TimeSpan.FromMilliseconds(Math.Max(1, message.ElapsedMs)), processes, flows, names);
    }

    private async Task<bool> SendAsync(HelperRequest request)
    {
        var writer = _writer;
        if (writer is null)
        {
            return false;
        }

        await _writeLock.WaitAsync();
        try
        {
            await writer.WriteLineAsync(HelperProtocol.Serialize(request));
            return true;
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            return false;
        }
        finally
        {
            _writeLock.Release();
        }
    }

    private void Disconnect()
    {
        var wasConnected = IsConnected;
        IsConnected = false;

        _writer = null;
        _pipe?.Dispose();
        _pipe = null;

        foreach (var pending in _pending.Values)
        {
            pending.TrySetCanceled();
        }

        if (wasConnected)
        {
            Post(() => ConnectionChanged?.Invoke(this, EventArgs.Empty));

            // A helper that restarts — updated, or the service recovered — is found again
            // without waiting for a feature to ask for it; until then every DNS change would
            // ask for administrator approval although the helper is back.
            if (!_stop.IsCancellationRequested)
            {
                EnsureConnecting();
            }
        }
    }

    private void Post(Action action)
    {
        if (!_dispatcher.HasShutdownStarted)
        {
            _dispatcher.BeginInvoke(action);
        }
    }

    public void Dispose()
    {
        // Not disposed: a connect loop still unwinding reads its token, and a cancelled
        // source without timers holds nothing worth freeing.
        _stop.Cancel();
        Disconnect();
    }
}
