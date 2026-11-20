// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.Service;

/// <summary>
/// The helper's side of encrypted DNS that outlives a single call: DNS-over-TLS, and the
/// record of what it changed.
///
/// <para><b>DoT is machine-wide.</b> Windows keeps it as an "encryption" entry per server
/// address in the DNS client's table, plus a global switch, and only <c>netsh dnsclient</c>
/// writes either — there is no Win32 API. An entry upgrades every query to that address, on
/// every adapter. So the helper records each entry it adds or changes, and whether it switched
/// the global setting on, in <see cref="HelperPaths.EncryptedDnsState"/>; it takes back exactly
/// those, and never touches entries the user or Windows made.</para>
///
/// <para><b>Nothing reaches netsh unchecked.</b> Arguments go through
/// <see cref="ProcessStartInfo.ArgumentList"/>, never a shell, and are built only from a
/// canonical IP address and a host name that passed <see cref="EncryptedDnsValidator"/> —
/// both checked again here, whatever the caller did.</para>
/// </summary>
internal sealed class EncryptedDnsTable
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(30);

    /// <summary>A failed runtime check is asked again after this long; a passed one is kept.</summary>
    private static readonly TimeSpan RuntimeRecheck = TimeSpan.FromMinutes(10);

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    /// <summary>DoT's port (RFC 7858), written out rather than relying on netsh's default.</summary>
    private const string DotPort = "853";

    private readonly string _statePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _runtimeGate = new();
    private Task<bool>? _runtime;
    private DateTime _runtimeCheckedAt;

    internal EncryptedDnsTable(string statePath) => _statePath = statePath;

    internal Action<string>? Log { get; set; }

    /// <summary>What this PC can do, including the netsh check behind DoT.</summary>
    internal async Task<EncryptedDnsCapabilities> CapabilitiesAsync()
    {
        var build = EncryptedDnsPlatform.Build;
        var runtime = build >= EncryptedDnsCapabilities.DotMinimumBuild && await RuntimeAvailableAsync();
        return EncryptedDnsCapabilities.Evaluate(build, EncryptedDnsPlatform.DohPolicy(), runtime);
    }

    /// <summary>
    /// Build 26100 is an assumption, not a documented floor, so DoT also has to show that the
    /// DNS client's netsh context is there: <c>netsh dnsclient show global</c> must succeed.
    /// </summary>
    private Task<bool> RuntimeAvailableAsync()
    {
        lock (_runtimeGate)
        {
            var failed = _runtime is { IsCompleted: true } done && (!done.IsCompletedSuccessfully || !done.Result);
            if (_runtime is null || (failed && DateTime.UtcNow - _runtimeCheckedAt > RuntimeRecheck))
            {
                _runtimeCheckedAt = DateTime.UtcNow;
                _runtime = CheckRuntimeAsync();
            }

            return _runtime;
        }
    }

    private async Task<bool> CheckRuntimeAsync()
    {
        try
        {
            var (exit, _) = await NetshAsync("dnsclient", "show", "global");
            Log?.Invoke($"netsh dnsclient show global -> {exit}");
            return exit == 0;
        }
        catch (Exception e) when (e is InvalidOperationException or IOException)
        {
            Log?.Invoke($"netsh dnsclient show global failed: {e.Message}");
            return false;
        }
    }

    /// <summary>
    /// NetFluss's DoT entries, as recorded. Read without the gate, so a record being replaced
    /// at that moment reads as none for this one answer rather than failing the reply.
    /// </summary>
    internal IReadOnlyList<HelperDotServer> Servers()
    {
        try
        {
            return [.. Load().Entries.Select(entry => new HelperDotServer(entry.Server, entry.Host))];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>
    /// Adds or updates a DoT entry for every server and switches DoT on globally. Returns null
    /// on success, otherwise what went wrong. Entries already added stay recorded on a failure,
    /// so <see cref="TidyAsync"/> can take them back.
    /// </summary>
    internal async Task<string?> ApplyAsync(IReadOnlyList<string> servers, string host)
    {
        if (EncryptedDnsValidator.NormalizeDotHost(host) != host || !DnsValidator.Validate(servers).IsValid || servers.Count == 0)
        {
            return "Invalid DNS-over-TLS server.";
        }

        await _gate.WaitAsync();
        try
        {
            var state = Load();
            foreach (var server in servers.Select(Canonical))
            {
                var dothost = $"dothost={host}:{DotPort}";
                var existing = state.Entries.FirstOrDefault(entry => entry.Server == server);
                bool created;

                if (existing is not null)
                {
                    // Ours already: only the host may change, and who created it does not.
                    var (exit, output) = await NetshAsync("dnsclient", "set", "encryption", $"server={server}", dothost, "autoupgrade=yes", "udpfallback=no");
                    if (exit != 0)
                    {
                        return Failure("set encryption", exit, output);
                    }

                    created = existing.Created;
                    state.Entries.Remove(existing);
                }
                else
                {
                    var (exit, _) = await NetshAsync("dnsclient", "add", "encryption", $"server={server}", dothost, "autoupgrade=yes", "udpfallback=no");
                    if (exit == 0)
                    {
                        // A server on Windows' built-in DoH list keeps its entry when NetFluss
                        // lets go, whatever add reported: only the DoT part is NetFluss's.
                        created = !IsWellKnownDohServer(server);
                    }
                    else
                    {
                        // add refuses a server that already has an entry — Windows' own DoH
                        // list covers Cloudflare, Google and Quad9. Change that one instead,
                        // and remember it was not NetFluss's.
                        var (setExit, setOutput) = await NetshAsync("dnsclient", "set", "encryption", $"server={server}", dothost, "autoupgrade=yes", "udpfallback=no");
                        if (setExit != 0)
                        {
                            return Failure("add/set encryption", setExit, setOutput);
                        }

                        created = false;
                    }
                }

                state.Entries.Add(new Entry(server, host, created));

                // Recorded after every entry: a helper stopped half-way still knows what it owns.
                Save(state);
            }

            if (!state.GlobalEnabledByNetFluss)
            {
                // Whether DoT was on already is read by comparison, not by parsing: netsh's
                // output is localised, but an unchanged report means the switch was on before.
                var before = await NetshAsync("dnsclient", "show", "global");
                var (exit, output) = await NetshAsync("dnsclient", "set", "global", "dot=yes");
                if (exit != 0)
                {
                    return Failure("set global", exit, output);
                }

                var after = await NetshAsync("dnsclient", "show", "global");
                if (before.Exit == 0 && after.Exit == 0 && before.Output != after.Output)
                {
                    state.GlobalEnabledByNetFluss = true;
                    Save(state);
                }
            }

            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log?.Invoke($"encrypted dns state: {e.Message}");
            return "Could not record the DNS-over-TLS settings.";
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Takes back NetFluss's DoT entries for <paramref name="release"/>, and those for servers
    /// no adapter uses statically any more — an entry nobody points at would otherwise wait to
    /// encrypt whatever adapter is given that address next. Switches global DoT back off once
    /// none are left, if NetFluss was the one that switched it on.
    /// </summary>
    internal async Task TidyAsync(IReadOnlyCollection<string> release)
    {
        await _gate.WaitAsync();
        try
        {
            var state = Load();
            var released = release.Select(Canonical).ToHashSet(StringComparer.OrdinalIgnoreCase);

            // Unreadable means unknown, and unknown keeps the entry.
            var inUse = StaticServersInUse();
            var stale = state.Entries
                .Where(entry => released.Contains(entry.Server) || (inUse is not null && !inUse.Contains(entry.Server)))
                .ToList();

            foreach (var entry in stale)
            {
                await RemoveEntryAsync(entry);
                state.Entries.Remove(entry);
                Save(state);
            }

            await ReleaseGlobalIfUnusedAsync(state);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log?.Invoke($"encrypted dns state: {e.Message}");
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Remembers an adapter that got DoH from NetFluss, for uninstalling.</summary>
    internal Task RecordDohAdapterAsync(Guid adapter) => UpdateAsync(state =>
    {
        if (state.DohAdapters.Contains(adapter))
        {
            return false;
        }

        state.DohAdapters.Add(adapter);
        return true;
    });

    /// <summary>Forgets it again once NetFluss wrote that adapter without DoH.</summary>
    internal Task ForgetDohAdapterAsync(Guid adapter) => UpdateAsync(state => state.DohAdapters.Remove(adapter));

    /// <summary>
    /// Everything NetFluss changed, taken back: DoH on the adapters it encrypted (their servers
    /// stay), its DoT entries, the global switch if it set it, and the record itself. For
    /// uninstalling the helper, which leaves nothing behind that the app could no longer undo.
    /// </summary>
    internal async Task RestoreAllAsync()
    {
        await _gate.WaitAsync();
        try
        {
            var state = Load();
            foreach (var adapter in state.DohAdapters)
            {
                InterfaceDns.ClearDoh(adapter);
            }

            state.DohAdapters.Clear();
            foreach (var entry in state.Entries.ToList())
            {
                await RemoveEntryAsync(entry);
                state.Entries.Remove(entry);
            }

            await ReleaseGlobalIfUnusedAsync(state);
            if (!state.GlobalEnabledByNetFluss && File.Exists(_statePath))
            {
                File.Delete(_statePath);
            }
            else
            {
                Save(state);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log?.Invoke($"encrypted dns state: {e.Message}");
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task UpdateAsync(Func<State, bool> change)
    {
        await _gate.WaitAsync();
        try
        {
            var state = Load();
            if (change(state))
            {
                Save(state);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log?.Invoke($"encrypted dns state: {e.Message}");
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// An entry NetFluss created goes completely. One it only changed loses its DoT host and
    /// gets Windows' defaults back for the two switches it set — the built-in DoH entries ship
    /// with auto-upgrade and UDP fallback off.
    /// </summary>
    private async Task RemoveEntryAsync(Entry entry)
    {
        if (DnsValidator.Validate([entry.Server]).Error is { } invalid)
        {
            // A hand-edited record: nothing that is not an address goes on a command line.
            Log?.Invoke($"skipped DoT entry: {invalid}");
            return;
        }

        if (entry.Created)
        {
            var (exit, output) = await NetshAsync("dnsclient", "delete", "encryption", $"server={entry.Server}");
            Log?.Invoke($"delete encryption {entry.Server} -> {exit} {output.Trim()}");
            if (exit == 0)
            {
                return;
            }
        }

        var (dotExit, dotOutput) = await NetshAsync("dnsclient", "delete", "encryption", $"server={entry.Server}", "protocol=dot");
        Log?.Invoke($"delete encryption {entry.Server} protocol=dot -> {dotExit} {dotOutput.Trim()}");
        if (!entry.Created)
        {
            var (setExit, _) = await NetshAsync("dnsclient", "set", "encryption", $"server={entry.Server}", "autoupgrade=no", "udpfallback=no");
            Log?.Invoke($"set encryption {entry.Server} autoupgrade=no -> {setExit}");
        }
    }

    private async Task ReleaseGlobalIfUnusedAsync(State state)
    {
        if (state.Entries.Count > 0 || !state.GlobalEnabledByNetFluss)
        {
            return;
        }

        var (exit, output) = await NetshAsync("dnsclient", "set", "global", "dot=no");
        Log?.Invoke($"set global dot=no -> {exit} {output.Trim()}");
        if (exit == 0)
        {
            state.GlobalEnabledByNetFluss = false;
            Save(state);
        }
    }

    private string Failure(string step, int exit, string output)
    {
        Log?.Invoke($"netsh dnsclient {step} -> {exit} {output.Trim()}");
        return $"netsh could not set DNS-over-TLS (error {exit}).";
    }

    /// <summary>
    /// Windows' built-in DoH list (Cloudflare, Google, Quad9…), one key per address. Read so
    /// an entry Windows shipped is never deleted as if NetFluss had made it.
    /// </summary>
    private static bool IsWellKnownDohServer(string server)
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DohWellKnownServers\{server}");
            return key is not null;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            // Unknown counts as Windows': keeping an entry is the harmless mistake.
            return true;
        }
    }

    /// <summary>
    /// Every static DNS server on every adapter, both stacks, or null when that cannot be read.
    /// The same registry values the app reads for the checkmark.
    /// </summary>
    private static HashSet<string>? StaticServersInUse()
    {
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var stack in new[] { "Tcpip", "Tcpip6" })
            {
                using var interfaces = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{stack}\Parameters\Interfaces");
                if (interfaces is null)
                {
                    continue;
                }

                foreach (var name in interfaces.GetSubKeyNames())
                {
                    using var adapter = interfaces.OpenSubKey(name);
                    if (adapter?.GetValue("NameServer") is string value)
                    {
                        foreach (var server in DnsValidator.Parse(value))
                        {
                            used.Add(Canonical(server));
                        }
                    }
                }
            }
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }

        return used;
    }

    private static string Canonical(string server)
        => IPAddress.TryParse(server, out var address) ? address.ToString() : server;

    private State Load()
    {
        try
        {
            return File.Exists(_statePath)
                ? JsonSerializer.Deserialize<State>(File.ReadAllText(_statePath), Json) ?? new State()
                : new State();
        }
        catch (JsonException e)
        {
            Log?.Invoke($"encrypted dns state unreadable: {e.Message}");
            return new State();
        }
    }

    /// <summary>
    /// Written whole and moved into place, readable and writable by SYSTEM and Administrators
    /// only: the record decides what the helper deletes from a machine-wide table.
    /// </summary>
    private void Save(State state)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_statePath)!);
        var temporary = _statePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, Json));

        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
        {
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl, AccessControlType.Allow));
        }

        new FileInfo(temporary).SetAccessControl(security);
        File.Move(temporary, _statePath, overwrite: true);
    }

    private static async Task<(int Exit, string Output)> NetshAsync(params string[] arguments)
    {
        var info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "netsh.exe"),
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(info);
            if (process is null)
            {
                return (-1, string.Empty);
            }

            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(CommandTimeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                return (-1, "Timed out.");
            }

            return (process.ExitCode, (await stdout) + (await stderr));
        }
        catch (Win32Exception e)
        {
            return (-1, e.Message);
        }
    }

    /// <summary>One DoT entry: the address, the host, and whether NetFluss created it or changed an existing one.</summary>
    internal sealed record Entry(string Server, string Host, bool Created);

    internal sealed class State
    {
        public List<Entry> Entries { get; set; } = [];

        /// <summary>NetFluss switched global DoT on, so it switches it off again when done.</summary>
        public bool GlobalEnabledByNetFluss { get; set; }

        /// <summary>Adapters NetFluss gave DoH, cleared again when the helper is uninstalled.</summary>
        public List<Guid> DohAdapters { get; set; } = [];
    }
}
