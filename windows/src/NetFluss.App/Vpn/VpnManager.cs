// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.IO;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows.Threading;
using NetFluss.Core;
using NetFluss.Core.Vpn;
using NetFluss.Native;

namespace NetFluss.App.Vpn;

/// <summary>
/// The built-in VPN client — port of the macOS <c>VPNManager</c>: the saved profiles, the
/// one active connection, and everything around it (credentials, automatic reconnection,
/// connecting at launch, a DNS preset while connected, the diagnostics log).
///
/// <para>Three backends. OpenVPN and WireGuard run through the helper service using the
/// installed OpenVPN Community and WireGuard for Windows; IKEv2 (and any other Windows VPN
/// connection) is dialled through Windows' own VPN stack, which needs no helper.</para>
/// </summary>
internal sealed class VpnManager : IDisposable
{
    private const string CredentialService = "vpn";
    private const int MaxReconnectAttempts = 10;
    private static readonly TimeSpan LivenessInterval = TimeSpan.FromSeconds(3);

    private readonly VpnProfileStore _store;
    private readonly HelperClient _helper;
    private readonly PrivilegedActions _privileged;
    private readonly SettingsStore _settings;
    private readonly NetworkMonitorService _monitor;
    private readonly Dispatcher _dispatcher;
    private readonly DispatcherTimer _liveness;
    private readonly DispatcherTimer _reconnect;
    private List<VpnProfile> _profiles;
    private OpenVpnManagementClient? _openVpn;
    private string? _tunnelHandle;
    private string? _nativeEntry;
    private string? _wireGuardService;
    private int _reconnectAttempts;
    private int _generation;

    internal VpnManager(HelperClient helper, PrivilegedActions privileged, SettingsStore settings, NetworkMonitorService monitor, Dispatcher dispatcher)
    {
        _helper = helper;
        _privileged = privileged;
        _settings = settings;
        _monitor = monitor;
        _dispatcher = dispatcher;
        _store = new VpnProfileStore(VpnProfileStore.DefaultRoot(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)));
        _profiles = [.. _store.Load()];

        _liveness = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = LivenessInterval };
        _liveness.Tick += (_, _) => CheckLiveness();
        _reconnect = new DispatcherTimer(DispatcherPriority.Normal, dispatcher);
        _reconnect.Tick += (_, _) => Reconnect();
    }

    /// <summary>Raised on the UI thread whenever the profiles or the status change.</summary>
    internal event EventHandler? Changed;

    internal IReadOnlyList<VpnProfile> Profiles => _profiles;

    internal VpnStatus Status { get; private set; } = VpnStatus.Idle;

    internal VpnProfile? Find(Guid id) => _profiles.FirstOrDefault(p => p.Id == id);

    // ===================================== Profiles =====================================

    internal (VpnProfile Profile, IReadOnlyList<string> Warnings) Import(VpnProtocol kind, string path)
    {
        var result = kind == VpnProtocol.OpenVpn ? VpnConfigImporter.ImportOpenVpn(path) : VpnConfigImporter.ImportWireGuard(path);
        var profile = new VpnProfile
        {
            Name = result.SuggestedName,
            Kind = kind,
            ConfigFileName = result.PrimaryFileName,
            Servers = result.Servers,
            RequiresCredentials = result.RequiresCredentials,
        };

        _store.WriteFiles(profile.Id, result.Files);
        _profiles.Add(profile);
        Save();
        VpnDiagnosticsLog.Log($"Imported {kind.DisplayName()} profile \"{profile.Name}\" with {result.Servers.Count} server(s)");
        return (profile, result.Warnings);
    }

    /// <summary>Creates a Windows IKEv2 connection and a profile that dials it.</summary>
    internal async Task<string?> AddIkev2Async(string name, string server, string username, string password)
    {
        var entry = UniqueEntryName(name.Trim());
        var error = await RasVpn.CreateIkev2Async(entry, server.Trim());
        if (error is not null)
        {
            VpnDiagnosticsLog.Log($"Creating IKEv2 connection \"{entry}\" failed: {error}");
            return error;
        }

        var profile = new VpnProfile
        {
            Name = name.Trim(),
            Kind = VpnProtocol.Ikev2,
            RequiresCredentials = true,
            NativeEntryName = entry,
            OwnsNativeEntry = true,
            Ikev2Server = server.Trim(),
            Ikev2Username = username.Trim(),
        };

        CredentialStore.Save(CredentialService, profile.CredentialAccount, username.Trim(), password);
        _profiles.Add(profile);
        Save();
        VpnDiagnosticsLog.Log($"Created IKEv2 connection \"{entry}\" to {server.Trim()}");
        return null;
    }

    private static string UniqueEntryName(string name)
    {
        var existing = RasVpn.Entries().Select(e => e.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var candidate = name.Length == 0 ? "NetFluss VPN" : name;
        for (var i = 2; existing.Contains(candidate); i++)
        {
            candidate = $"{name} {i}";
        }

        return candidate;
    }

    /// <summary>A profile for a VPN connection already set up in Windows Settings.</summary>
    internal VpnProfile AddSystem(string entry)
    {
        if (_profiles.FirstOrDefault(p => p.NativeEntryName == entry) is { } existing)
        {
            return existing;
        }

        var profile = new VpnProfile { Name = entry, Kind = VpnProtocol.Ikev2, NativeEntryName = entry };
        _profiles.Add(profile);
        Save();
        return profile;
    }

    internal async Task DeleteAsync(VpnProfile profile)
    {
        if (Status.ProfileId == profile.Id)
        {
            await DisconnectAsync();
        }

        CredentialStore.Delete(CredentialService, profile.CredentialAccount);
        _store.RemoveFiles(profile.Id);
        _profiles.RemoveAll(p => p.Id == profile.Id);
        Save();

        if (profile.OwnsNativeEntry && profile.NativeEntryName is { } entry)
        {
            if (await RasVpn.RemoveAsync(entry) is { } error)
            {
                VpnDiagnosticsLog.Log($"Removing Windows VPN connection \"{entry}\" failed: {error}");
            }
        }
    }

    internal void Rename(VpnProfile profile, string name)
    {
        var trimmed = name.Trim();
        if (trimmed.Length > 0)
        {
            Update(profile.Id, p => p with { Name = trimmed });
        }
    }

    internal void SelectServer(VpnProfile profile, int index) => Update(profile.Id, p => p with { SelectedServerIndex = index });

    internal void Move(VpnProfile profile, int newIndex)
    {
        var index = _profiles.FindIndex(p => p.Id == profile.Id);
        if (index < 0)
        {
            return;
        }

        var item = _profiles[index];
        _profiles.RemoveAt(index);
        _profiles.Insert(Math.Clamp(newIndex, 0, _profiles.Count), item);
        Save();
    }

    internal void SetOptions(VpnProfile profile, Func<VpnProfileOptions, VpnProfileOptions> change)
    {
        var updated = change(profile.Options);

        // One tunnel at a time, so only one profile can connect at launch.
        if (updated.ConnectOnLaunch)
        {
            for (var i = 0; i < _profiles.Count; i++)
            {
                if (_profiles[i].Id != profile.Id && _profiles[i].Options.ConnectOnLaunch)
                {
                    _profiles[i] = _profiles[i] with { Options = _profiles[i].Options with { ConnectOnLaunch = false } };
                }
            }
        }

        Update(profile.Id, p => p with { Options = updated });
    }

    internal bool HasCredentials(VpnProfile profile) => CredentialStore.Exists(CredentialService, profile.CredentialAccount);

    internal void SetCredentials(VpnProfile profile, string username, string password)
    {
        if (username.Length == 0 && password.Length == 0)
        {
            CredentialStore.Delete(CredentialService, profile.CredentialAccount);
        }
        else
        {
            CredentialStore.Save(CredentialService, profile.CredentialAccount, username, password);
        }

        Raise();
    }

    private void Update(Guid id, Func<VpnProfile, VpnProfile> change)
    {
        var index = _profiles.FindIndex(p => p.Id == id);
        if (index >= 0)
        {
            _profiles[index] = change(_profiles[index]);
            Save();
        }
    }

    private void Save()
    {
        try
        {
            _store.Save(_profiles);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            VpnDiagnosticsLog.Log("Saving profiles failed: " + e.Message);
        }

        Raise();
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);

    private void SetStatus(VpnStatus status)
    {
        Status = status;
        Raise();
    }

    // ===================================== Connect =====================================

    internal void Connect(VpnProfile profile)
    {
        if (Status.State.IsActive())
        {
            return;
        }

        _reconnect.Stop();
        _reconnectAttempts = 0;
        var server = profile.SelectedServer;
        VpnDiagnosticsLog.Log($"Connect requested: \"{profile.Name}\" [{profile.Kind}] server={server?.Label ?? "-"}");
        VpnDiagnosticsLog.LogEnvironment(_helper.IsConnected, _helper.HelperVersion);
        _ = StartAsync(profile, server, reconnecting: false);
    }

    private async Task StartAsync(VpnProfile profile, VpnServer? server, bool reconnecting)
    {
        var generation = ++_generation;
        SetStatus(new VpnStatus { State = reconnecting ? VpnState.Reconnecting : VpnState.Connecting, ProfileId = profile.Id, ServerId = server?.Id });

        try
        {
            switch (profile.Kind)
            {
                case VpnProtocol.OpenVpn:
                    await StartOpenVpnAsync(profile, server, generation);
                    break;
                case VpnProtocol.WireGuard:
                    await StartWireGuardAsync(profile, server, generation);
                    break;
                default:
                    await StartNativeAsync(profile, generation);
                    break;
            }
        }
        catch (Exception e)
        {
            // Anything at all: this runs as a discarded task, so an exception the filter let
            // through — an adapter appearing just as the tunnel came up throws
            // NetworkInformationException — vanished and left the profile "Connecting" for good.
            VpnDiagnosticsLog.Log("Connect failed: " + e);
            if (generation == _generation)
            {
                Fail(e.Message);
            }
        }
    }

    /// <summary>The helper, or a plain explanation of why OpenVPN and WireGuard need it.</summary>
    private async Task<bool> EnsureHelperAsync()
    {
        if (!_helper.IsConnected && !await _helper.ProbeAsync(TimeSpan.FromSeconds(3)))
        {
            Fail(Localization.L("OpenVPN and WireGuard connections run through the NetFluss helper. Install it under Preferences → General → System access, then connect again."));
            return false;
        }

        if (!_helper.SupportsVpn)
        {
            Fail(Localization.L("The NetFluss helper is out of date. Update it under Preferences → General → System access, then connect again."));
            return false;
        }

        return true;
    }

    /// <summary>The config a server connects with, plus the files it references, relative to the profile folder.</summary>
    private List<HelperFile> CollectFiles(VpnProfile profile, VpnServer? server, out string config)
    {
        var configPath = _store.ConfigPath(profile, server);
        var root = _store.ProfileDirectory(profile.Id);
        config = Path.GetRelativePath(root, configPath).Replace('\\', '/');
        var files = new List<HelperFile> { new(config, File.ReadAllBytes(configPath)) };

        if (profile.Kind == VpnProtocol.OpenVpn)
        {
            var directory = Path.GetDirectoryName(configPath)!;
            foreach (var reference in VpnConfigImporter.ReferencedFiles(File.ReadAllText(configPath)).Where(VpnConfigImporter.IsSafeRelative).Distinct())
            {
                var path = Path.Combine(directory, reference.Replace('/', '\\'));
                if (File.Exists(path))
                {
                    files.Add(new HelperFile(Path.GetRelativePath(root, path).Replace('\\', '/'), File.ReadAllBytes(path)));
                }
            }
        }

        return files;
    }

    private async Task StartOpenVpnAsync(VpnProfile profile, VpnServer? server, int generation)
    {
        if (VpnTools.OpenVpnPath() is null)
        {
            Fail(Localization.L("OpenVPN is not installed. Install OpenVPN Community from openvpn.net, then connect again."));
            return;
        }

        if (!await EnsureHelperAsync())
        {
            return;
        }

        var files = CollectFiles(profile, server, out var config);
        var reply = await _helper.RequestAsync(new HelperRequest { Op = "vpnStart", Kind = "openVpn", Files = files, Config = config }, TimeSpan.FromSeconds(20));
        if (generation != _generation)
        {
            StopOrphan(reply);
            return;
        }

        if (reply is not { Ok: true, Handle: { } handle })
        {
            var reason = reply?.Message ?? Localization.L("Could not start the VPN helper.");
            VpnDiagnosticsLog.Log("Helper start FAILED (OpenVPN): " + reason);
            Fail(reason);
            return;
        }

        _tunnelHandle = handle;
        VpnDiagnosticsLog.Log($"Helper started OpenVPN, handle={handle}");

        var openVpnPid = reply.Pid;
        var client = new OpenVpnManagementClient(reply.Port, reply.Secret ?? string.Empty, port => TcpListeners.OwnerOf(port) == openVpnPid);
        client.EventReceived += e => _dispatcher.BeginInvoke(() => OnOpenVpnEvent(e, client, profile));
        client.Closed += () => _dispatcher.BeginInvoke(() =>
        {
            if (_openVpn == client)
            {
                UnexpectedStop();
            }
        });
        _openVpn = client;

        try
        {
            await client.ConnectAsync(CancellationToken.None);
        }
        catch (Exception e) when (e is SocketException or IOException or OperationCanceledException)
        {
            if (_openVpn == client)
            {
                await FailWithLogAsync(Localization.L("Could not reach the OpenVPN management interface."));
            }
        }
    }

    private void OnOpenVpnEvent(OpenVpnEvent e, OpenVpnManagementClient client, VpnProfile profile)
    {
        if (_openVpn != client)
        {
            return;
        }

        switch (e)
        {
            case OpenVpnEvent.State { Name: "CONNECTED" } state:
                VpnDiagnosticsLog.Log("OpenVPN connected" + (state.AssignedIp is { } ip ? $" ({ip})" : string.Empty));
                Connected(state.AssignedIp, profile);
                break;
            case OpenVpnEvent.State { Name: "RECONNECTING" }:
                SetStatus(Status with { State = VpnState.Reconnecting });
                break;
            case OpenVpnEvent.State { Name: "EXITING" }:
                UnexpectedStop();
                break;
            case OpenVpnEvent.ByteCount count:
                Status = Status with { BytesIn = count.In, BytesOut = count.Out };
                break;
            case OpenVpnEvent.NeedCredentials need:
                if (CredentialStore.Load(CredentialService, profile.CredentialAccount) is { } credentials)
                {
                    _ = client.SendCredentialsAsync(need.Kind, need.UsernameToo ? credentials.First : null, credentials.Second);
                }
                else
                {
                    Fail(Localization.L("This VPN needs a username and password. Add them in the profile's settings and reconnect."));
                    _ = StopTunnelAsync();
                }

                break;
            case OpenVpnEvent.AuthFailed failed:
                _ = FailWithLogAsync(failed.Message);
                break;
        }
    }

    private async Task StartWireGuardAsync(VpnProfile profile, VpnServer? server, int generation)
    {
        if (VpnTools.WireGuardPath() is null)
        {
            Fail(Localization.L("WireGuard is not installed. Install WireGuard for Windows from wireguard.com, then connect again."));
            return;
        }

        if (!await EnsureHelperAsync())
        {
            return;
        }

        var files = CollectFiles(profile, server, out var config);
        var tunnel = VpnConfigPolicy.WireGuardTunnelName(profile.Name);
        var reply = await _helper.RequestAsync(new HelperRequest { Op = "vpnStart", Kind = "wireGuard", Files = files, Config = config, Tunnel = tunnel }, TimeSpan.FromSeconds(45));
        if (generation != _generation)
        {
            StopOrphan(reply);
            return;
        }

        if (reply is not { Ok: true, Handle: { } handle })
        {
            var reason = reply?.Message ?? Localization.L("Could not start the VPN helper.");
            VpnDiagnosticsLog.Log("Helper start FAILED (WireGuard): " + reason);
            Fail(reason);
            return;
        }

        _tunnelHandle = handle;
        _wireGuardService = "WireGuardTunnel$" + handle["wg:".Length..];

        // The tunnel service starts in the background; it is up once it is running.
        for (var i = 0; i < 40 && generation == _generation; i++)
        {
            if (ServiceRunning(_wireGuardService))
            {
                var text = File.ReadAllText(_store.ConfigPath(profile, server));
                VpnDiagnosticsLog.Log($"WireGuard connected: tunnel={_wireGuardService["WireGuardTunnel$".Length..]}");
                Connected(VpnConfigImporter.WireGuardAddress(text), profile);
                return;
            }

            await Task.Delay(250);
        }

        if (generation == _generation)
        {
            await FailWithLogAsync(Localization.L("The VPN connection stopped."));
        }
    }

    private static bool ServiceRunning(string name) => ServiceStatus.IsRunning(name);

    private async Task StartNativeAsync(VpnProfile profile, int generation)
    {
        if (profile.NativeEntryName is not { } entry || RasVpn.Entries().All(e => !e.Name.Equals(entry, StringComparison.OrdinalIgnoreCase)))
        {
            Fail(Localization.L("No system VPN service is associated with this profile."));
            return;
        }

        var credentials = CredentialStore.Load(CredentialService, profile.CredentialAccount);
        if (profile.RequiresCredentials && credentials is null)
        {
            Fail(Localization.L("The VPN password isn't stored — remove the profile and add it again."));
            return;
        }

        _nativeEntry = entry;
        var error = await Task.Run(() => RasVpn.Dial(entry, credentials?.First, credentials?.Second));
        if (generation != _generation)
        {
            // Disconnected while dialling: a dial that succeeded anyway must not stay up unowned.
            if (error is null)
            {
                _ = Task.Run(() => RasVpn.HangUp(entry));
            }

            return;
        }

        if (error is not null)
        {
            VpnDiagnosticsLog.Log($"Windows VPN \"{entry}\" failed: {error}");
            _nativeEntry = null;
            if (!ScheduleReconnect())
            {
                Fail(error);
            }

            return;
        }

        VpnDiagnosticsLog.Log($"Windows VPN \"{entry}\" connected");
        Connected(AdapterAddress(entry), profile);
    }

    /// <summary>A tunnel adapter's IPv4 address, found by the adapter's name.</summary>
    private static string? AdapterAddress(string name)
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .FirstOrDefault(n => n.Name.Equals(name, StringComparison.OrdinalIgnoreCase))?
                .GetIPProperties().UnicastAddresses
                .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork)?.Address.ToString();
        }
        catch (NetworkInformationException)
        {
            // The adapter list is changing — the tunnel has only just come up. The address
            // is a detail; the connection is not worth failing over it.
            return null;
        }
    }

    private void Connected(string? assignedIp, VpnProfile profile)
    {
        _reconnectAttempts = 0;
        SetStatus(Status with
        {
            State = VpnState.Connected,
            ConnectedSince = Status.ConnectedSince ?? DateTimeOffset.Now,
            AssignedIp = assignedIp ?? Status.AssignedIp,
            Error = null,
        });
        _liveness.Start();
        RefreshPublicAddress();
        _ = ApplyProfileDnsAsync(profile, assignedIp);
    }

    /// <summary>The exit address changes the moment a tunnel comes up or goes down.</summary>
    private void RefreshPublicAddress()
    {
        _monitor.InvalidatePublicAddress();
        _monitor.Refresh();
        _ = Task.Delay(2500).ContinueWith(_ => _dispatcher.BeginInvoke(() =>
        {
            _monitor.InvalidatePublicAddress();
            _monitor.Refresh();
        }), TaskScheduler.Default);
    }

    /// <summary>
    /// The profile's DNS preset, set on the tunnel adapter itself — Windows asks the
    /// tunnel's resolvers first while it is up, and they vanish with the adapter, so there
    /// is nothing to restore afterwards.
    /// </summary>
    private async Task ApplyProfileDnsAsync(VpnProfile profile, string? assignedIp)
    {
        if (!profile.Options.UseProfileDns ||
            _settings.Settings.AllDnsPresets().FirstOrDefault(p => p.Id == profile.Options.DnsPresetId) is not { Servers.Count: > 0 } preset)
        {
            return;
        }

        NetworkInterface? adapter;
        try
        {
            adapter = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n =>
                (_nativeEntry is not null && n.Name.Equals(_nativeEntry, StringComparison.OrdinalIgnoreCase)) ||
                (_wireGuardService is not null && n.Name.Equals(_wireGuardService["WireGuardTunnel$".Length..], StringComparison.OrdinalIgnoreCase)) ||
                (assignedIp is not null && n.GetIPProperties().UnicastAddresses.Any(a => a.Address.ToString() == assignedIp)));
        }
        catch (NetworkInformationException)
        {
            // Adapters still settling right after the tunnel came up.
            adapter = null;
        }

        if (adapter is null)
        {
            VpnDiagnosticsLog.Log("Profile DNS: tunnel adapter not found");
            return;
        }

        var result = await _privileged.SetDnsAsync(adapter.Id, adapter.Name, preset.Servers);
        VpnDiagnosticsLog.Log($"Profile DNS {preset.Name} on {adapter.Name}: {(result.Succeeded ? "applied" : result.Message)}");
    }

    // ===================================== Disconnect and drops =====================================

    internal async Task DisconnectAsync()
    {
        if (!Status.State.IsActive() && _tunnelHandle is null && _nativeEntry is null && _openVpn is null && Status.State != VpnState.Failed)
        {
            return;
        }

        _reconnect.Stop();
        _liveness.Stop();
        _reconnectAttempts = 0;
        _generation++;
        SetStatus(Status with { State = VpnState.Disconnecting });

        await StopTunnelAsync();
        VpnDiagnosticsLog.Log("Disconnected");
        SetStatus(VpnStatus.Idle with { ProfileId = Status.ProfileId });
        RefreshPublicAddress();
    }

    /// <summary>Tears down whatever backend is running, without touching the displayed state.</summary>
    private async Task StopTunnelAsync()
    {
        // Take everything before the first await: a new connection may start while this one
        // is still being torn down, and must not have its tunnel stopped by the old stop.
        var client = _openVpn;
        var handle = _tunnelHandle;
        var entry = _nativeEntry;
        _openVpn = null;
        _tunnelHandle = null;
        _nativeEntry = null;
        _wireGuardService = null;

        if (client is not null)
        {
            await client.SignalExitAsync();
            await Task.Delay(500);
            await client.DisposeAsync();
        }

        if (handle is not null)
        {
            await StopHandleAsync(handle);
        }

        if (entry is not null)
        {
            await Task.Run(() => RasVpn.HangUp(entry));
        }
    }

    private async Task StopHandleAsync(string handle)
    {
        var reply = await _helper.RequestAsync(new HelperRequest { Op = "vpnStop", Handle = handle }, TimeSpan.FromSeconds(30));
        if (reply is not { Ok: true })
        {
            VpnDiagnosticsLog.Log($"Stopping {handle} failed: {reply?.Message ?? "no answer from the helper"}");
        }
    }

    /// <summary>
    /// A tunnel the helper started for a connect the user has since cancelled: nothing owns
    /// it any more, so it is stopped rather than left running behind an "idle" status.
    /// </summary>
    private void StopOrphan(HelperMessage? reply)
    {
        if (reply is { Ok: true, Handle: { } handle })
        {
            VpnDiagnosticsLog.Log($"Stopping {handle}: its connect was cancelled");
            _ = StopHandleAsync(handle);
        }
    }

    /// <summary>WireGuard and Windows VPNs have no event channel; poll for a dropped tunnel.</summary>
    private void CheckLiveness()
    {
        if (Status.State != VpnState.Connected)
        {
            return;
        }

        var alive = _wireGuardService is { } service ? ServiceRunning(service)
            : _nativeEntry is { } entry ? RasVpn.IsConnected(entry)
            : true;

        if (!alive)
        {
            VpnDiagnosticsLog.Log("Tunnel went away");
            UnexpectedStop();
        }
    }

    private void UnexpectedStop()
    {
        if (Status.State is VpnState.Failed or VpnState.Idle or VpnState.Disconnecting)
        {
            return;
        }

        // OpenVPN reports an exit twice — the EXITING state, then the closed socket. The
        // first schedules the retry; the second must not spend another attempt.
        if (Status.State == VpnState.Reconnecting && _reconnect.IsEnabled)
        {
            return;
        }

        RefreshPublicAddress();
        if (!ScheduleReconnect())
        {
            _ = FailWithLogAsync(Localization.L("The VPN connection stopped."));
        }
    }

    /// <summary>Retries with backoff — 2, 4, 8, 16, 30 s — when the profile asks for it.</summary>
    private bool ScheduleReconnect()
    {
        if (Status.ProfileId is not { } id || Find(id) is not { Options.AutoReconnect: true } || _reconnectAttempts >= MaxReconnectAttempts)
        {
            return false;
        }

        var delay = Math.Min(30, 2 * Math.Pow(2, _reconnectAttempts));
        _reconnectAttempts++;
        _liveness.Stop();
        SetStatus(Status with { State = VpnState.Reconnecting });
        VpnDiagnosticsLog.Log($"Reconnecting in {delay:0} s (attempt {_reconnectAttempts})");
        _reconnect.Interval = TimeSpan.FromSeconds(delay);
        _reconnect.Start();
        return true;
    }

    private async void Reconnect()
    {
        _reconnect.Stop();
        if (Status.State != VpnState.Reconnecting || Status.ProfileId is not { } id || Find(id) is not { } profile)
        {
            return;
        }

        await StopTunnelAsync();
        if (Status.State != VpnState.Reconnecting)
        {
            return;
        }

        var server = profile.Servers.FirstOrDefault(s => s.Id == Status.ServerId) ?? profile.SelectedServer;
        await StartAsync(profile, server, reconnecting: true);
    }

    private void Fail(string message)
    {
        VpnDiagnosticsLog.Log("VPN failed: " + message);
        _liveness.Stop();
        SetStatus(Status with { State = VpnState.Failed, Error = message });
    }

    /// <summary>Fails with a provisional reason, then refines it from the tool's own log.</summary>
    private async Task FailWithLogAsync(string message)
    {
        var handle = _tunnelHandle;
        var profileId = Status.ProfileId;
        Fail(message);
        await StopTunnelAsync();

        if (handle is null)
        {
            return;
        }

        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (attempt > 0)
            {
                await Task.Delay(400);
            }

            var reply = await _helper.RequestAsync(new HelperRequest { Op = "vpnLog", Handle = handle }, TimeSpan.FromSeconds(10));
            if (reply?.Message is { Length: > 0 } log)
            {
                VpnDiagnosticsLog.LogBlock("tool log", log);
                if (Status.ProfileId == profileId && Status.State == VpnState.Failed && OpenVpnManagementClient.SummarizeLog(log) is { } summary)
                {
                    SetStatus(Status with { Error = summary });
                }

                return;
            }
        }
    }

    // ===================================== Launch =====================================

    /// <summary>
    /// Connects the connect-at-launch profile a few seconds after startup, once networking
    /// and the helper have settled — an immediate connect at login is unreliable.
    /// </summary>
    internal void ConnectOnLaunchIfNeeded()
    {
        if (_profiles.FirstOrDefault(p => p.Options.ConnectOnLaunch) is not { } profile)
        {
            return;
        }

        _ = Task.Delay(TimeSpan.FromSeconds(5)).ContinueWith(_ => _dispatcher.BeginInvoke(() =>
        {
            if (!Status.State.IsActive() && Find(profile.Id) is { } current)
            {
                Connect(current);
            }
        }), TaskScheduler.Default);
    }

    /// <summary>Called on exit: a tunnel NetFluss started must not outlive it unowned.</summary>
    public void Dispose()
    {
        _reconnect.Stop();
        _liveness.Stop();
        if (_tunnelHandle is not null || _nativeEntry is not null || _openVpn is not null)
        {
            // Off the UI thread: the stop awaits helper replies that would otherwise wait on it.
            Task.Run(StopTunnelAsync).Wait(TimeSpan.FromSeconds(5));
        }
    }
}
