// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Net.NetworkInformation;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.App;

/// <summary>
/// Windows counterpart of the macOS <c>NetworkMonitor</c>: one timer on the UI dispatcher
/// drives one <see cref="InterfaceSampler"/> pass and republishes adapters and totals.
///
/// <para>Deliberately a single timer, as on macOS, and the energy rule from the Mac side
/// carries over verbatim: anything beyond the counters — Wi-Fi radio details, addresses,
/// the public IP — is only refreshed while something that shows it is open
/// (<see cref="DetailMonitoring"/>), and each on its own slower cadence. A tray meter that
/// queried the radio every second all day would be a battery defect.</para>
/// </summary>
public sealed class NetworkMonitorService : INotifyPropertyChanged, IDisposable
{
    private static readonly TimeSpan WifiDetailInterval = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan AddressInterval = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan PublicIpInterval = TimeSpan.FromMinutes(5);

    private readonly InterfaceSampler _sampler = new();
    private readonly DispatcherTimer _timer;
    private readonly PublicIpLookup _publicIp = new();
    private readonly Dictionary<string, DateTimeOffset> _graceDeadlines = new(StringComparer.OrdinalIgnoreCase);

    private RateTotals _totals = RateTotals.Zero;
    private AdapterVisibilityOptions _visibility = new();
    private bool _excludeTunnelAdapters;
    private bool _totalsFromVisibleOnly;
    private bool _detailMonitoring;
    private IReadOnlyDictionary<string, WifiDetail> _wifiDetails = new Dictionary<string, WifiDetail>();
    private WlanAccess _wifiAccess = WlanAccess.Ok;
    private LocalAddresses _addresses = LocalAddresses.Empty;
    private PublicIp? _publicAddress;
    private DateTime _lastWifiRefresh = DateTime.MinValue;
    private DateTime _lastAddressRefresh = DateTime.MinValue;
    private DateTime _lastPublicIpRefresh = DateTime.MinValue;
    private bool _publicIpInFlight;
    private bool _publicIpWantsCountry;
    private volatile bool _networkChanged;
    private IReadOnlyList<AdapterStatus> _lastSample = [];

    public NetworkMonitorService(TimeSpan interval)
    {
        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = interval };
        _timer.Tick += (_, _) => Refresh();

        // An address change is the one moment the slow caches are certainly stale: a new
        // network, a VPN coming up, a cable unplugged. Refresh on the next tick rather than
        // waiting out the interval.
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised after every refresh, once all the published properties are current.</summary>
    public event EventHandler? Ticked;

    /// <summary>The adapters that pass the visibility filter, in user order.</summary>
    public ObservableCollection<AdapterStatus> Adapters { get; } = [];

    /// <summary>
    /// Every adapter the machine reports, filter or no filter.
    ///
    /// <para>Preferences lists from this rather than from <see cref="Adapters"/>: hiding an
    /// adapter removes it from the filtered set, so a checklist built on that would drop the
    /// row the moment it was unticked and leave no way to ever tick it back.</para>
    /// </summary>
    public ObservableCollection<AdapterStatus> AllAdapters { get; } = [];

    /// <summary>The raw last sample, every interface included, for consumers that do their own filtering.</summary>
    public IReadOnlyList<AdapterStatus> LastSample => _lastSample;

    public RateTotals Totals
    {
        get => _totals;
        private set
        {
            if (_totals == value)
            {
                return;
            }

            _totals = value;
            OnPropertyChanged();
        }
    }

    public LocalAddresses Addresses
    {
        get => _addresses;
        private set
        {
            if (Equals(_addresses, value) || (_addresses.InternalIp == value.InternalIp &&
                                               _addresses.GatewayIp == value.GatewayIp &&
                                               _addresses.Fingerprint == value.Fingerprint &&
                                               _addresses.Tunnels.SequenceEqual(value.Tunnels)))
            {
                return;
            }

            _addresses = value;
            OnPropertyChanged();
        }
    }

    /// <summary>
    /// Whether the public address may be looked up online (the AllowIpLookups setting).
    /// Switching it off also forgets the one already shown.
    /// </summary>
    public bool AllowIpLookups
    {
        get => _allowIpLookups;
        set
        {
            _allowIpLookups = value;
            if (!value)
            {
                PublicAddress = null;
            }
        }
    }

    private bool _allowIpLookups = true;

    public PublicIp? PublicAddress
    {
        get => _publicAddress;
        private set
        {
            if (Equals(_publicAddress, value))
            {
                return;
            }

            _publicAddress = value;
            OnPropertyChanged();
        }
    }

    /// <summary>Why Wi-Fi details are missing, when they are.</summary>
    public WlanAccess WifiAccess => _wifiAccess;

    public TimeSpan Interval
    {
        get => _timer.Interval;
        set => _timer.Interval = value;
    }

    public bool ExcludeTunnelAdapters
    {
        get => _excludeTunnelAdapters;
        set => _excludeTunnelAdapters = value;
    }

    public bool TotalsFromVisibleAdaptersOnly
    {
        get => _totalsFromVisibleOnly;
        set => _totalsFromVisibleOnly = value;
    }

    /// <summary>User labels by interface GUID; empty means use the Windows connection name.</summary>
    public IReadOnlyDictionary<string, string> AdapterNames { get; set; }
        = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    /// <summary>User ordering by interface GUID; empty means busiest first.</summary>
    public IReadOnlyList<string> AdapterOrder { get; set; } = [];

    public AdapterVisibilityOptions Visibility
    {
        get => _visibility;
        set => _visibility = value;
    }

    /// <summary>Seconds an adapter stays listed after it goes quiet, or null when the grace period is off.</summary>
    public double? AdapterGraceSeconds { get; set; }

    /// <summary>Show the IPv6 external address rather than the IPv4 one.</summary>
    public bool PreferIPv6 { get; set; }

    /// <summary>
    /// Whether a country is on screen. Only then is the external address geolocated — a
    /// lookup per refresh would give a third party a log of every network for no visible
    /// benefit.
    /// </summary>
    public bool WantsCountry
    {
        get => _publicIpWantsCountry || _meterShowsCountry;
        set
        {
            if (_publicIpWantsCountry == value)
            {
                return;
            }

            _publicIpWantsCountry = value;
            if (value && _publicAddress is { CountryCode: null })
            {
                _lastPublicIpRefresh = DateTime.MinValue;
            }
        }
    }

    /// <summary>
    /// The meter shows a VPN mark or the exit country, so tunnels are watched even while
    /// the popover is closed — cheaply, every few seconds, the 2.6 VPN indicator's cadence.
    /// </summary>
    public bool DetectVpn { get; set; }

    /// <summary>The meter shows the exit country, so the public address is kept fresh.</summary>
    public bool MeterShowsCountry
    {
        get => _meterShowsCountry;
        set
        {
            if (_meterShowsCountry == value)
            {
                return;
            }

            _meterShowsCountry = value;
            if (value && _publicAddress is not { CountryCode: not null })
            {
                _lastPublicIpRefresh = DateTime.MinValue;
            }
        }
    }

    private bool _meterShowsCountry;
    private DateTime? _settleRefreshAt;
    // A safety net only: an address change already triggers a read at once (OnNetworkChanged).
    private static readonly TimeSpan VpnInterval = TimeSpan.FromSeconds(30);

    /// <summary>
    /// True while the popover, a pinned popover or another detail view is on screen. The
    /// macOS <c>setDetailMonitoringEnabled</c>: switching it on forces an immediate refresh of
    /// everything, so the first frame is never a page of stale or empty fields.
    /// </summary>
    public bool DetailMonitoring
    {
        get => _detailMonitoring;
        set
        {
            if (_detailMonitoring == value)
            {
                return;
            }

            _detailMonitoring = value;
            if (value)
            {
                _lastWifiRefresh = DateTime.MinValue;
                _lastAddressRefresh = DateTime.MinValue;
                Refresh();
            }
        }
    }

    /// <summary>
    /// Set while the session is locked — the macOS app's display-sleep/lock suspension.
    /// Rates are still sampled; the lookups behind the popover and the meter's accessories
    /// pause, and run at once when it clears.
    /// </summary>
    public bool Quiet
    {
        get => _quiet;
        set
        {
            if (_quiet == value)
            {
                return;
            }

            _quiet = value;
            if (!value)
            {
                _lastWifiRefresh = _lastAddressRefresh = _lastPublicIpRefresh = DateTime.MinValue;
                Refresh();
            }
        }
    }

    private bool _quiet;

    /// <summary>Forgets the public address so the next detail tick fetches it again.</summary>
    public void InvalidatePublicAddress() => _lastPublicIpRefresh = DateTime.MinValue;

    public void Start()
    {
        // Prime the counters so the first visible tick already has a delta to work from.
        Refresh();
        _timer.Start();
    }

    public void Stop() => _timer.Stop();

    public void Refresh()
    {
        IReadOnlyList<AdapterStatus> sampled;
        try
        {
            sampled = _sampler.Sample();
        }
        catch (InvalidOperationException)
        {
            // GetIfTable2 can fail transiently while a driver is being reloaded. Skip the
            // tick rather than take the meter down; the next one recovers.
            return;
        }

        var now = DateTime.UtcNow;

        if (_networkChanged)
        {
            _networkChanged = false;
            _lastAddressRefresh = DateTime.MinValue;
            _lastWifiRefresh = DateTime.MinValue;
            _lastPublicIpRefresh = DateTime.MinValue;
        }

        // Locked: keep counting bytes — statistics and the meter must stay right — but skip
        // every lookup that only matters to someone looking at the screen.
        if (!Quiet)
        {
            RefreshDetails(now);
        }

        sampled = AttachWifi(sampled);
        _lastSample = sampled;

        var visibility = WithGrace(sampled, now);

        Totals = AdapterTotalsFilter.Totals(
            sampled,
            _totalsFromVisibleOnly,
            _excludeTunnelAdapters,
            visibility);

        // Custom names are applied to the user-facing list only. AllAdapters below stays as
        // Windows reports it, because the rename field in Preferences has to be able to show
        // what an adapter is called *without* a custom name — otherwise committing an
        // untouched field would pin the current label and quietly stop the adapter from ever
        // following its Windows name again.
        var visible = AdapterTotalsFilter.InUserOrder(
            AdapterTotalsFilter.WithCustomNames(
                AdapterTotalsFilter.VisibleAdapters(sampled, visibility),
                AdapterNames),
            AdapterOrder);

        // Rebuild in place: replacing the collection would drop the popover's bindings.
        Adapters.Clear();
        foreach (var adapter in visible)
        {
            Adapters.Add(adapter);
        }

        // Loopback and the WFP/QoS filter pseudo-interfaces are excluded even here: they
        // mirror the adapter they sit on, so offering them in a checklist would be offering
        // the user four copies of their Ethernet card to choose between.
        //
        // Ranked adapters first in the user's order, then the rest alphabetically —
        // deliberately *not* by traffic like the popover. This list is the one being
        // rearranged, and rows that resort themselves every second would slide out from
        // under the pointer mid-drag.
        var rank = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < AdapterOrder.Count; i++)
        {
            rank.TryAdd(AdapterOrder[i], i);
        }

        AllAdapters.Clear();
        foreach (var adapter in sampled
                     .Where(adapter => !adapter.IsNonInternet)
                     .OrderBy(adapter => rank.TryGetValue(adapter.Id, out var position) ? position : int.MaxValue)
                     .ThenBy(adapter => adapter.DisplayName, StringComparer.CurrentCultureIgnoreCase))
        {
            AllAdapters.Add(adapter);
        }

        OnPropertyChanged(nameof(AllAdapters));
        RaiseTicked();
    }

    /// <summary>
    /// The visibility options with the grace deadlines filled in. An adapter carrying traffic
    /// pushes its deadline out; one that has been quiet past its deadline drops off.
    /// </summary>
    private AdapterVisibilityOptions WithGrace(IReadOnlyList<AdapterStatus> sampled, DateTime now)
    {
        if (AdapterGraceSeconds is not { } seconds)
        {
            _graceDeadlines.Clear();
            return _visibility with { GraceEnabled = false };
        }

        var nowOffset = new DateTimeOffset(now, TimeSpan.Zero);
        foreach (var adapter in sampled)
        {
            if (adapter.HasTraffic)
            {
                _graceDeadlines[adapter.Id] = nowOffset.AddSeconds(seconds);
            }
        }

        foreach (var expired in _graceDeadlines.Where(pair => pair.Value <= nowOffset).Select(pair => pair.Key).ToList())
        {
            _graceDeadlines.Remove(expired);
        }

        return _visibility with
        {
            GraceEnabled = true,
            GraceDeadlines = new Dictionary<string, DateTimeOffset>(_graceDeadlines, StringComparer.OrdinalIgnoreCase),
        };
    }

    /// <summary>Wi-Fi details, local addresses and the public address, each on its own cadence.</summary>
    private void RefreshDetails(DateTime now)
    {
        if (_detailMonitoring && !_wifiReadInFlight && now - _lastWifiRefresh >= WifiDetailInterval)
        {
            _lastWifiRefresh = now;
            _ = RefreshWifiDetailsAsync();
        }

        // Addresses are read while the popover is open, and — on a faster cadence — whenever
        // the meter shows a VPN mark or the exit country, since those change with the network
        // whether or not anything else is on screen.
        var addressInterval = DetectVpn ? VpnInterval : AddressInterval;
        if ((_detailMonitoring || DetectVpn) && !_addressReadInFlight && now - _lastAddressRefresh >= addressInterval)
        {
            _lastAddressRefresh = now;
            _ = RefreshAddressesAsync();
        }

        if (_settleRefreshAt is { } settle && now >= settle && !_publicIpInFlight)
        {
            _settleRefreshAt = null;
            _lastPublicIpRefresh = DateTime.MinValue;
        }

        if (AllowIpLookups && (_detailMonitoring || _meterShowsCountry) && !_publicIpInFlight && now - _lastPublicIpRefresh >= PublicIpInterval)
        {
            _lastPublicIpRefresh = now;
            _ = RefreshPublicAddressAsync();
        }
    }

    // Both reads below are synchronous Windows calls — the adapter list with its addresses,
    // the WLAN service — that take milliseconds to a good part of a second on a busy machine.
    // They run on the thread pool; their results are applied back here, on the UI thread.
    private bool _addressReadInFlight;
    private bool _wifiReadInFlight;

    private async Task RefreshAddressesAsync()
    {
        _addressReadInFlight = true;
        try
        {
            var previous = _addresses.Fingerprint;
            Addresses = await Task.Run(NetworkAddresses.Read);

            // A different set of local addresses means a VPN came up or went down or the
            // network changed: the public address and its country follow now, and once more
            // a moment later because routes and DNS take a little while to settle.
            if (_meterShowsCountry && previous.Length > 0 && previous != _addresses.Fingerprint)
            {
                _lastPublicIpRefresh = DateTime.MinValue;
                _settleRefreshAt = DateTime.UtcNow + TimeSpan.FromSeconds(2.5);
            }
        }
        catch (Exception e)
        {
            CrashLog.Write("addresses", e);
        }
        finally
        {
            _addressReadInFlight = false;
        }
    }

    private async Task RefreshWifiDetailsAsync()
    {
        _wifiReadInFlight = true;
        try
        {
            (_wifiAccess, _wifiDetails) = await Task.Run(ReadWifiDetails);
        }
        catch (Exception e)
        {
            CrashLog.Write("wifi details", e);
        }
        finally
        {
            _wifiReadInFlight = false;
        }
    }

    private static (WlanAccess Access, IReadOnlyDictionary<string, WifiDetail> Details) ReadWifiDetails()
    {
        using var client = WlanClient.TryOpen();
        if (client is null)
        {
            return (WlanAccess.NoAdapter, new Dictionary<string, WifiDetail>());
        }

        var details = new Dictionary<string, WifiDetail>(StringComparer.OrdinalIgnoreCase);
        var access = WlanAccess.Ok;

        foreach (var radio in client.Interfaces())
        {
            if (!radio.IsConnected)
            {
                continue;
            }

            var detail = client.CurrentConnection(radio.Id, out var radioAccess);
            if (radioAccess == WlanAccess.LocationDenied)
            {
                access = WlanAccess.LocationDenied;
            }

            if (detail is not null)
            {
                details[radio.Id.ToString("B")] = detail;
            }
        }

        return (access, details);
    }

    private IReadOnlyList<AdapterStatus> AttachWifi(IReadOnlyList<AdapterStatus> sampled)
    {
        if (_wifiDetails.Count == 0)
        {
            return sampled;
        }

        var result = new List<AdapterStatus>(sampled.Count);
        foreach (var adapter in sampled)
        {
            if (adapter.Type == AdapterType.WiFi && adapter.IsUp && _wifiDetails.TryGetValue(adapter.Id, out var detail))
            {
                result.Add(adapter with
                {
                    Wifi = detail,
                    WifiSsid = detail.Ssid,
                    WifiTxRateMbps = detail.TxRateMbps,
                    WifiMode = detail.Band is { } band ? $"Wi-Fi ({WifiFormat.BandLabel(band)})" : "Wi-Fi",
                });
            }
            else
            {
                result.Add(adapter);
            }
        }

        return result;
    }

    private async Task RefreshPublicAddressAsync()
    {
        _publicIpInFlight = true;
        try
        {
            var result = await _publicIp.LookupAsync(PreferIPv6, WantsCountry);

            // A failed lookup clears the address rather than leaving the last network's on
            // screen: after a move from home to a café, showing the home address as "current"
            // would be worse than showing a dash.
            PublicAddress = result;
        }
        finally
        {
            _publicIpInFlight = false;
        }
    }

    private void OnNetworkChanged(object? sender, EventArgs e) => _networkChanged = true;

    public void Dispose()
    {
        _timer.Stop();
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
        _publicIp.Dispose();
    }

    /// <summary>
    /// Every listener in turn, each on its own. The tray icon, the meters, statistics and the
    /// popover all hang off these two events; one of them throwing — the tray while Explorer
    /// restarts, say — used to cancel every listener after it and the rest of the tick with it.
    /// </summary>
    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        if (PropertyChanged is not { } handlers)
        {
            return;
        }

        var args = new PropertyChangedEventArgs(name);
        foreach (var handler in handlers.GetInvocationList())
        {
            try
            {
                ((PropertyChangedEventHandler)handler)(this, args);
            }
            catch (Exception e)
            {
                CrashLog.Write($"tick ({name})", e);
            }
        }
    }

    private void RaiseTicked()
    {
        if (Ticked is not { } handlers)
        {
            return;
        }

        foreach (var handler in handlers.GetInvocationList())
        {
            try
            {
                ((EventHandler)handler)(this, EventArgs.Empty);
            }
            catch (Exception e)
            {
                CrashLog.Write("tick", e);
            }
        }
    }
}
