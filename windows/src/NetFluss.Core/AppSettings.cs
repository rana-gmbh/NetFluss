// Copyright (C) 2026 Rana GmbH
//
// This file is part of NetFluss.
//
// NetFluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// NetFluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with NetFluss. If not, see <https://www.gnu.org/licenses/>.

using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;


namespace NetFluss.Core;

/// <summary>Where the meter puts its numbers. Mirrors the macOS "Menu bar style" choice.</summary>
public enum MeterStyle
{
    TwoLine,
    DownloadOnly,
    UploadOnly,
    Icon,
}

/// <summary>
/// Which surface carries the live meter.
///
/// <para>macOS has one answer — a variable-width <c>NSStatusItem</c> — and Windows has
/// none that is both roomy and guaranteed. The notification area is permanent but capped
/// at a 16–32 px square; the taskbar overlay has the room but sits on undocumented
/// geometry. So the choice is the user's, and the app degrades rather than disappears.</para>
/// </summary>
public enum MeterSurface
{
    /// <summary>
    /// A window positioned over the taskbar beside the tray. Room for the full
    /// "↓ 4.72 MB/s ↑ 834 KB/s" line, and the closest thing to the macOS menu bar.
    /// Falls back to <see cref="Tray"/> on its own if the taskbar cannot be located.
    /// </summary>
    TaskbarOverlay,

    /// <summary>The notification-area icon. Cramped, and it never breaks.</summary>
    Tray,
}

/// <summary>How the roomier surfaces lay the rates out. Ports the macOS menu bar styles.</summary>
public enum ReadoutStyle
{
    /// <summary>One line: "↓ 4.72 MB/s   ↑ 834 KB/s". The macOS <c>unified</c> style.</summary>
    Unified,

    /// <summary>Two half-height lines, upload above download. The macOS <c>rates</c> stack.</summary>
    Stacked,

    /// <summary>Combined throughput only, for the narrowest placements.</summary>
    Total,

    /// <summary>
    /// The macOS <c>dashboard</c>: a dark capsule with a utilisation ring, the combined
    /// total, then download and upload. Uses router-wide traffic when a router reports it.
    /// </summary>
    Dashboard,

    /// <summary>The macOS <c>dashboardBasic</c>: the capsule with download and upload only.</summary>
    DashboardBasic,
}

/// <summary>
/// Everything Preferences can change, and the single source of truth for it.
///
/// <para><b>Why a JSON file and not the registry.</b> The macOS app keeps ordered lists in
/// <c>UserDefaults</c> — adapter order, hidden adapters, custom DNS presets. The registry
/// has no ordered-collection story worth using, so a JSON document under
/// <c>%LOCALAPPDATA%</c> is both the closer analogue and the thing a user can back up,
/// diff, or delete to reset. It also keeps a portable no-install build possible, which the
/// port plan treats as a requirement.</para>
///
/// <para>Defaults here are the registration list: they must match what the macOS
/// <c>AppState</c> registers, because a fresh install on either platform should behave the
/// same way.</para>
/// </summary>
public sealed class AppSettings : INotifyPropertyChanged
{
    private double _refreshIntervalSeconds = 1;
    private bool _useBits;
    private MeterStyle _meterStyle = MeterStyle.TwoLine;
    private bool _showArrows;
    private bool _enforceContrast = true;
    private string _downloadAccent = "system";
    private string _uploadAccent = "system";
    private string _downloadCustomHex = "0078D4";
    private string _uploadCustomHex = "2EA043";
    private string _themeId = "system";
    private AppLanguage _language = AppLanguage.System;
    private bool _launchAtLogin;
    private bool _excludeTunnelAdapters;
    private bool _totalsFromVisibleAdaptersOnly;
    private MeterSurface _meterSurface = MeterSurface.TaskbarOverlay;
    private ReadoutStyle _readoutStyle = ReadoutStyle.Unified;
    private double _readoutFontSize = 11;
    private bool _showFloatingWidget;
    private double? _floatingWidgetLeft;
    private double? _floatingWidgetTop;
    private string _trayIconGlyph = "netfluss";
    private bool _hideTrayIcon;
    private bool _showInactiveAdapters;
    private bool _showOtherAdapters = true;
    private double _popoverWidth = 340;
    private double _popoverHeight = 560;
    private bool _showTotalsHeader = true;
    private bool _showAdapterList = true;
    private bool _showUsageSummary;
    private ConnectionDisplayMode _connectionMode = ConnectionDisplayMode.Flow;
    private ConnectionDisplayMode _lastConnectionMode = ConnectionDisplayMode.Flow;
    private bool _externalIPv6;
    private bool _showDnsSwitcher;
    private bool _showWifiSwitcher;
    private bool _wifiLimitEnabled;
    private int _wifiLimitCount = 10;
    private bool _showTopApps;
    private bool _topAppsGraceEnabled;
    private double _topAppsGraceSeconds = 3;
    private bool _adapterGraceEnabled;
    private double _adapterGraceSeconds = 3;
    private bool _collectStatistics;
    private bool _collectAppStatistics = true;
    private bool _automaticUpdateChecks = true;
    private string _speedTestProvider = "mlab";
    private bool _speedTestMLabConsent;
    private bool _networkSliceHostsLive;
    private bool _networkSliceServicesLive;
    private bool _networkSliceAppsLive;
    private bool _fritzBoxEnabled;
    private string _fritzBoxHost = string.Empty;
    private bool _uniFiEnabled;
    private string _uniFiHost = string.Empty;
    private bool _uniFiUseApiKey;
    private bool _openWrtEnabled;
    private string _openWrtHost = string.Empty;
    private bool _opnSenseEnabled;
    private string _opnSenseHost = string.Empty;
    private string _lastNotifiedVersion = string.Empty;
    private DateTimeOffset? _lastUpdateCheck;
    private bool _firstLaunchHintShown;
    private bool _allowIpLookups = true;
    private bool _popoverPinned;
    private double? _pinnedLeft;
    private double? _pinnedTop;
    private string _dnsAdapterId = string.Empty;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// Tick interval. The macOS app offers 0.5–5 s and so does this; anything faster buys no
    /// visible precision and costs battery on a machine that is otherwise idle.
    /// </summary>
    public double RefreshIntervalSeconds
    {
        get => _refreshIntervalSeconds;
        set => Set(ref _refreshIntervalSeconds, Math.Clamp(value, 0.5, 5));
    }

    /// <summary>Bits per second rather than bytes. Off by default, as on macOS.</summary>
    public bool UseBits
    {
        get => _useBits;
        set => Set(ref _useBits, value);
    }

    public MeterStyle MeterStyle
    {
        get => _meterStyle;
        set => Set(ref _meterStyle, value);
    }

    /// <summary>
    /// Off by default: at 16–20 px the arrow eats width the digits need, and the row colour
    /// already carries the direction. See the Phase 0 verdict in windows/README.md.
    /// </summary>
    public bool ShowArrows
    {
        get => _showArrows;
        set => Set(ref _showArrows, value);
    }

    /// <summary>
    /// Lift both rate colours to WCAG AA against the taskbar they are drawn on. On by
    /// default — a user picking a colour is asking for that colour, not for an unreadable
    /// tray icon, and the correction preserves the hue.
    /// </summary>
    public bool EnforceContrast
    {
        get => _enforceContrast;
        set => Set(ref _enforceContrast, value);
    }

    /// <summary>Named entry in <see cref="AccentPalette"/>, "system", or "custom".</summary>
    public string DownloadAccent
    {
        get => _downloadAccent;
        set => Set(ref _downloadAccent, value);
    }

    public string UploadAccent
    {
        get => _uploadAccent;
        set => Set(ref _uploadAccent, value);
    }

    public string DownloadCustomHex
    {
        get => _downloadCustomHex;
        set => Set(ref _downloadCustomHex, value);
    }

    public string UploadCustomHex
    {
        get => _uploadCustomHex;
        set => Set(ref _uploadCustomHex, value);
    }

    /// <summary>Id from <see cref="AppTheme.All"/>.</summary>
    public string ThemeId
    {
        get => _themeId;
        set => Set(ref _themeId, value);
    }

    public AppLanguage Language
    {
        get => _language;
        set => Set(ref _language, value);
    }

    public bool LaunchAtLogin
    {
        get => _launchAtLogin;
        set => Set(ref _launchAtLogin, value);
    }

    public bool ExcludeTunnelAdapters
    {
        get => _excludeTunnelAdapters;
        set => Set(ref _excludeTunnelAdapters, value);
    }

    public bool TotalsFromVisibleAdaptersOnly
    {
        get => _totalsFromVisibleAdaptersOnly;
        set => Set(ref _totalsFromVisibleAdaptersOnly, value);
    }

    /// <summary>
    /// Which surface shows the meter. Defaults to the overlay because it is the only one
    /// with room for a real rate line; <c>App</c> falls back to the tray by itself if the
    /// taskbar cannot be anchored to, so this preference never leaves the user with nothing.
    /// </summary>
    public MeterSurface MeterSurface
    {
        get => _meterSurface;
        set => Set(ref _meterSurface, value);
    }

    /// <summary>Layout used by the overlay and the floating widget, not by the tray.</summary>
    public ReadoutStyle ReadoutStyle
    {
        get => _readoutStyle;
        set => Set(ref _readoutStyle, value);
    }

    /// <summary>Point size for the roomy surfaces. macOS clamps to 8–16 and so does this.</summary>
    public double ReadoutFontSize
    {
        get => _readoutFontSize;
        set => Set(ref _readoutFontSize, Math.Clamp(value, 8, 16));
    }

    /// <summary>
    /// The always-on-top desktop panel. Independent of <see cref="MeterSurface"/> — it is an
    /// addition, not an alternative, and the macOS "Pin" feature it ports behaves the same way.
    /// </summary>
    public bool ShowFloatingWidget
    {
        get => _showFloatingWidget;
        set => Set(ref _showFloatingWidget, value);
    }

    /// <summary>
    /// Last position of the floating widget, or null until it has been placed once.
    ///
    /// <para>Nullable rather than NaN: System.Text.Json refuses to write NaN at all, so the
    /// sentinel turned every settings save into an ArgumentException that Save could not
    /// catch. Absence is what is actually being modelled here anyway.</para>
    /// </summary>
    public double? FloatingWidgetLeft
    {
        get => _floatingWidgetLeft;
        set => Set(ref _floatingWidgetLeft, value);
    }

    public double? FloatingWidgetTop
    {
        get => _floatingWidgetTop;
        set => Set(ref _floatingWidgetTop, value);
    }

    /// <summary>
    /// Hide the notification-area icon while another surface is carrying the meter.
    ///
    /// <para><b>Off by default, and that is a deliberate safety choice.</b> The tray icon is
    /// where Windows users look for a background app's menu, and for a while this was
    /// hidden automatically whenever the taskbar overlay anchored — which left a user who
    /// had also turned off the floating widget with no discoverable way into Preferences and
    /// no way to quit at all, short of Task Manager.</para>
    ///
    /// <para>Turning it on is fine, and the overlay's own right-click menu still works, but
    /// it is a choice the user makes knowingly rather than a side effect of picking a
    /// placement. While it is on and the overlay is carrying the numbers, the tray icon
    /// drops to a static glyph so the rates are not shown twice.</para>
    /// </summary>
    public bool HideTrayIcon
    {
        get => _hideTrayIcon;
        set => Set(ref _hideTrayIcon, value);
    }

    /// <summary>Id from the tray glyph library, used by <see cref="MeterStyle.Icon"/>.</summary>
    public string TrayIconGlyph
    {
        get => _trayIconGlyph;
        set => Set(ref _trayIconGlyph, value);
    }

    /// <summary>
    /// User-defined DNS presets, appended to <see cref="DnsPreset.BuiltIn"/>. Mirrors the
    /// macOS custom-preset list, including that built-ins cannot be edited or removed.
    /// </summary>
    public List<DnsPreset> CustomDnsPresets { get; set; } = [];

    /// <summary>Built-ins followed by the user's own, which is the order the Mac shows them in.</summary>
    public IReadOnlyList<DnsPreset> AllDnsPresets() => [.. DnsPreset.BuiltIn, .. CustomDnsPresets];

    /// <summary>Adds a preset, rejecting anything that would not survive an elevated apply.</summary>
    public DnsValidation AddDnsPreset(string name, IReadOnlyList<string> servers)
    {
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            return DnsValidation.Fail(Localization.L("Give the preset a name."));
        }

        if (servers.Count == 0)
        {
            return DnsValidation.Fail(Localization.L("Give the preset at least one server."));
        }

        var validation = DnsValidator.Validate(servers);
        if (!validation.IsValid)
        {
            return validation;
        }

        if (AllDnsPresets().Any(preset => string.Equals(preset.Name, trimmed, StringComparison.OrdinalIgnoreCase)))
        {
            return DnsValidation.Fail(Localization.L("'{0}' already exists.", trimmed));
        }

        CustomDnsPresets =
        [
            .. CustomDnsPresets,
            new DnsPreset
            {
                Id = $"custom-{Guid.NewGuid():N}",
                Name = trimmed,
                Servers = servers,
            },
        ];

        OnPropertyChanged(nameof(CustomDnsPresets));
        return DnsValidation.Ok;
    }

    public void RemoveDnsPreset(string id)
    {
        var remaining = CustomDnsPresets.Where(preset => preset.Id != id).ToList();
        if (remaining.Count == CustomDnsPresets.Count)
        {
            return;
        }

        CustomDnsPresets = remaining;
        OnPropertyChanged(nameof(CustomDnsPresets));
    }

    /// <summary>BSD-equivalent interface ids in user order, mirroring macOS "adapterOrder".</summary>
    public List<string> AdapterOrder { get; set; } = [];

    /// <summary>Interface id → user label, mirroring macOS "adapterCustomNames".</summary>
    public Dictionary<string, string> AdapterCustomNames { get; set; } = [];

    /// <summary>Interface ids the user has hidden from the popover.</summary>
    public List<string> HiddenAdapters { get; set; } = [];

    /// <summary>Resolved download colour, or <paramref name="fallback"/> for "system".</summary>
    /// <summary>
    /// Show adapters that are down. Off by default: a laptop has a dozen disconnected
    /// virtual and tunnel interfaces and listing them all buries the one that matters.
    /// </summary>
    public bool ShowInactiveAdapters
    {
        get => _showInactiveAdapters;
        set => Set(ref _showInactiveAdapters, value);
    }

    /// <summary>Show interfaces NDIS could not classify. On by default, as on macOS.</summary>
    public bool ShowOtherAdapters
    {
        get => _showOtherAdapters;
        set => Set(ref _showOtherAdapters, value);
    }

    /// <summary>Remembered popover size. The user resizes it; it stays resized.</summary>
    public double PopoverWidth
    {
        get => _popoverWidth;
        set => Set(ref _popoverWidth, Math.Clamp(value, 280, 900));
    }

    /// <summary>
    /// The most the popover may grow to. It hugs its content below this, as the macOS
    /// popover does, so a short popover is never padded out with empty background; dragging
    /// the bottom edge sets the limit.
    /// </summary>
    public double PopoverHeight
    {
        get => _popoverHeight;
        set => Set(ref _popoverHeight, Math.Clamp(value, 220, 2000));
    }

    // ================================ Popover sections ================================

    /// <summary>
    /// Section order as macOS raw ids. Stored as given and resolved on read, so an id from a
    /// newer version survives a round trip through an older one.
    /// </summary>
    public List<string> PopoverSectionOrder { get; set; } = [.. PopoverSections.DefaultOrder.Select(s => s.Id())];

    /// <summary>The order every surface should draw in: unknown ids dropped, new sections appended.</summary>
    public IReadOnlyList<PopoverSection> SectionOrder() => PopoverSections.Resolve(PopoverSectionOrder);

    public void SetSectionOrder(IEnumerable<PopoverSection> order)
    {
        var ids = order.Select(s => s.Id()).ToList();
        if (ids.SequenceEqual(PopoverSectionOrder, StringComparer.Ordinal))
        {
            return;
        }

        PopoverSectionOrder = ids;
        OnPropertyChanged(nameof(PopoverSectionOrder));
    }

    /// <summary>
    /// Whether a section is switched on. Each one aliases the preference that already owns
    /// it rather than keeping a second flag — the macOS design, and the only way the reorder
    /// list and the individual toggles elsewhere in Preferences can never disagree.
    /// </summary>
    public bool IsSectionEnabled(PopoverSection section) => section switch
    {
        PopoverSection.Totals => ShowTotalsHeader,
        PopoverSection.Usage => ShowUsageSummary,
        PopoverSection.Adapters => ShowAdapterList,
        PopoverSection.Connection => ConnectionMode != ConnectionDisplayMode.None,
        PopoverSection.Dns => ShowDnsSwitcher,
        PopoverSection.Router => AnyRouterEnabled,
        PopoverSection.Wifi => ShowWifiSwitcher,
        PopoverSection.Vpn => ShowVpn,
        PopoverSection.TopApps => ShowTopApps,
        PopoverSection.Timer => ShowTrafficTimer,
        _ => false,
    };

    public void SetSectionEnabled(PopoverSection section, bool enabled)
    {
        switch (section)
        {
            case PopoverSection.Totals:
                ShowTotalsHeader = enabled;
                break;
            case PopoverSection.Usage:
                ShowUsageSummary = enabled;
                if (enabled)
                {
                    // The summary is read from the history; switching it on without
                    // collection would show a section that can only ever say "no data".
                    CollectStatistics = true;
                }

                break;
            case PopoverSection.Adapters:
                ShowAdapterList = enabled;
                break;
            case PopoverSection.Connection:
                // Off remembers which view was in use, so switching back on restores it.
                ConnectionMode = enabled ? LastConnectionMode : ConnectionDisplayMode.None;
                break;
            case PopoverSection.Dns:
                ShowDnsSwitcher = enabled;
                break;
            case PopoverSection.Wifi:
                ShowWifiSwitcher = enabled;
                break;
            case PopoverSection.TopApps:
                ShowTopApps = enabled;
                break;
            case PopoverSection.Timer:
                ShowTrafficTimer = enabled;
                break;
            case PopoverSection.Vpn:
                ShowVpn = enabled;
                break;
            case PopoverSection.Router when !enabled:
                // Off switches every router off; on needs a router chosen in the Router page.
                FritzBoxEnabled = UniFiEnabled = OpenWrtEnabled = OpnSenseEnabled = false;
                break;
        }
    }

    /// <summary>True when at least one router integration is on — the Router section's switch.</summary>
    [JsonIgnore]
    public bool AnyRouterEnabled => FritzBoxEnabled || UniFiEnabled || OpenWrtEnabled || OpnSenseEnabled;

    public bool ShowTotalsHeader
    {
        get => _showTotalsHeader;
        set => Set(ref _showTotalsHeader, value);
    }

    public bool ShowAdapterList
    {
        get => _showAdapterList;
        set => Set(ref _showAdapterList, value);
    }

    /// <summary>The Today / This Month data-usage block. Needs <see cref="CollectStatistics"/>.</summary>
    public bool ShowUsageSummary
    {
        get => _showUsageSummary;
        set => Set(ref _showUsageSummary, value);
    }

    public ConnectionDisplayMode ConnectionMode
    {
        get => _connectionMode;
        set
        {
            if (value != ConnectionDisplayMode.None)
            {
                LastConnectionMode = value;
            }

            Set(ref _connectionMode, value);
        }
    }

    /// <summary>The flow or list view to restore when the address section is switched back on.</summary>
    public ConnectionDisplayMode LastConnectionMode
    {
        get => _lastConnectionMode;
        set => Set(ref _lastConnectionMode, value == ConnectionDisplayMode.None ? ConnectionDisplayMode.Flow : value);
    }

    /// <summary>Show the IPv6 external address rather than the IPv4 one.</summary>
    public bool ExternalIPv6
    {
        get => _externalIPv6;
        set => Set(ref _externalIPv6, value);
    }

    public bool ShowDnsSwitcher
    {
        get => _showDnsSwitcher;
        set => Set(ref _showDnsSwitcher, value);
    }

    /// <summary>The adapter the popover's DNS switcher applies to; empty means the primary one.</summary>
    public string DnsAdapterId
    {
        get => _dnsAdapterId;
        set => Set(ref _dnsAdapterId, value ?? string.Empty);
    }

    public bool ShowWifiSwitcher
    {
        get => _showWifiSwitcher;
        set => Set(ref _showWifiSwitcher, value);
    }

    /// <summary>Cap the Wi-Fi list to the strongest networks. Pinned and current always show.</summary>
    public bool WifiLimitEnabled
    {
        get => _wifiLimitEnabled;
        set => Set(ref _wifiLimitEnabled, value);
    }

    public int WifiLimitCount
    {
        get => _wifiLimitCount;
        set => Set(ref _wifiLimitCount, Math.Clamp(value, 1, 50));
    }

    /// <summary>SSIDs pinned to the top of the Wi-Fi list, in pin order.</summary>
    public List<string> PinnedWifiNetworks { get; set; } = [];

    public bool IsWifiPinned(string ssid) => PinnedWifiNetworks.Contains(ssid, StringComparer.Ordinal);

    public void SetWifiPinned(string ssid, bool pinned)
    {
        if (IsWifiPinned(ssid) == pinned)
        {
            return;
        }

        var updated = PinnedWifiNetworks.Where(s => !string.Equals(s, ssid, StringComparison.Ordinal)).ToList();
        if (pinned)
        {
            updated.Add(ssid);
        }

        PinnedWifiNetworks = updated;
        OnPropertyChanged(nameof(PinnedWifiNetworks));
    }

    public bool ShowTopApps
    {
        get => _showTopApps;
        set => Set(ref _showTopApps, value);
    }

    /// <summary>Keep an app listed for a few seconds after it goes quiet, so the list does not flicker.</summary>
    public bool TopAppsGraceEnabled
    {
        get => _topAppsGraceEnabled;
        set => Set(ref _topAppsGraceEnabled, value);
    }

    public double TopAppsGraceSeconds
    {
        get => _topAppsGraceSeconds;
        set => Set(ref _topAppsGraceSeconds, Math.Clamp(value, 1, 30));
    }

    /// <summary>Process names kept out of Top Apps, matched case-insensitively.</summary>
    public List<string> HiddenApps { get; set; } = [];

    public bool IsAppHidden(string name) => HiddenApps.Contains(name, StringComparer.OrdinalIgnoreCase);

    public void SetAppHidden(string name, bool hidden)
    {
        if (string.IsNullOrWhiteSpace(name) || IsAppHidden(name) == hidden)
        {
            return;
        }

        var updated = HiddenApps.Where(a => !string.Equals(a, name, StringComparison.OrdinalIgnoreCase)).ToList();
        if (hidden)
        {
            updated.Add(name.Trim());
        }

        HiddenApps = updated;
        OnPropertyChanged(nameof(HiddenApps));
    }

    /// <summary>
    /// Show adapters only while they carry traffic, plus a grace period after. The macOS
    /// "adapter grace period" — for machines with a VPN that comes and goes.
    /// </summary>
    public bool AdapterGraceEnabled
    {
        get => _adapterGraceEnabled;
        set => Set(ref _adapterGraceEnabled, value);
    }

    public double AdapterGraceSeconds
    {
        get => _adapterGraceSeconds;
        set => Set(ref _adapterGraceSeconds, Math.Clamp(value, 1, 60));
    }

    // ======================================= VPN =======================================

    private bool _showVpn;

    /// <summary>The popover's VPN section, for the built-in VPN client. Off by default, as on macOS.</summary>
    public bool ShowVpn
    {
        get => _showVpn;
        set => Set(ref _showVpn, value);
    }

    // ================================== Traffic Timer ==================================

    private bool _showTrafficTimer;

    /// <summary>The 2.6 Traffic Timer section. Off by default, as on macOS.</summary>
    public bool ShowTrafficTimer
    {
        get => _showTrafficTimer;
        set => Set(ref _showTrafficTimer, value);
    }

    /// <summary>The saved timer, restored paused on the next launch; null when idle.</summary>
    public TrafficTimerSession? TrafficTimerSession { get; set; }

    // ================================== VPN indicator ==================================

    private string _vpnIndicator = "off";
    private string _vpnIndicatorColor = "green";
    private string _vpnIndicatorColorHex = string.Empty;
    private bool _vpnShowWhenOff = true;
    private bool _showCountryFlag;

    /// <summary>
    /// "off", "dot" or "shield": a mark after the rates showing whether any VPN is up —
    /// NetFluss's own or any other client's (the macOS 2.6 menu bar VPN indicator).
    /// </summary>
    public string VpnIndicator
    {
        get => _vpnIndicator;
        set => Set(ref _vpnIndicator, value is "dot" or "shield" ? value : "off");
    }

    /// <summary>Accent name, "system" or "custom" (with <see cref="VpnIndicatorColorHex"/>).</summary>
    public string VpnIndicatorColor
    {
        get => _vpnIndicatorColor;
        set => Set(ref _vpnIndicatorColor, string.IsNullOrWhiteSpace(value) ? "green" : value);
    }

    public string VpnIndicatorColorHex
    {
        get => _vpnIndicatorColorHex;
        set => Set(ref _vpnIndicatorColorHex, value ?? string.Empty);
    }

    /// <summary>Keep the mark visible, dimmed, while no VPN is connected.</summary>
    public bool VpnShowWhenOff
    {
        get => _vpnShowWhenOff;
        set => Set(ref _vpnShowWhenOff, value);
    }

    /// <summary>Show the country the public IP is in after the rates.</summary>
    public bool ShowCountryFlag
    {
        get => _showCountryFlag;
        set => Set(ref _showCountryFlag, value);
    }

    /// <summary>Whether anything on the meter needs VPN detection at all.</summary>
    [JsonIgnore]
    public bool NeedsVpnDetection => VpnIndicator != "off" || ShowCountryFlag;

    // =================================== Statistics ===================================

    /// <summary>Record per-adapter history for the Statistics window and Data Usage.</summary>
    public bool CollectStatistics
    {
        get => _collectStatistics;
        set => Set(ref _collectStatistics, value);
    }

    /// <summary>Also record per-app history. Only takes effect where per-app data is available.</summary>
    public bool CollectAppStatistics
    {
        get => _collectAppStatistics;
        set => Set(ref _collectAppStatistics, value);
    }

    // ===================================== Updates =====================================

    /// <summary>Check GitHub for a newer release once a day.</summary>
    public bool AutomaticUpdateChecks
    {
        get => _automaticUpdateChecks;
        set => Set(ref _automaticUpdateChecks, value);
    }

    /// <summary>The newest version the user has already been told about, so they are told once.</summary>
    public string LastNotifiedVersion
    {
        get => _lastNotifiedVersion;
        set => Set(ref _lastNotifiedVersion, value ?? string.Empty);
    }

    public DateTimeOffset? LastUpdateCheck
    {
        get => _lastUpdateCheck;
        set => Set(ref _lastUpdateCheck, value);
    }

    /// <summary>
    /// Whether NetFluss may ask online services about IP addresses: the public address and its
    /// country (api.ipify.org, ipwho.is) and the countries of the servers in Network Slice
    /// (api.country.is). Those services see the address asked about. Off, the public address,
    /// the VPN exit country and the country badges stay empty — a choice the installer offers
    /// too, as SignPath Foundation's privacy rules require.
    /// </summary>
    public bool AllowIpLookups
    {
        get => _allowIpLookups;
        set => Set(ref _allowIpLookups, value);
    }

    /// <summary>
    /// Whether NetFluss has said once where it lives. On a Mac the menu bar item is always in
    /// view; on Windows the meter may have fallen back to an icon that Windows tucks behind
    /// the "^" overflow, and an app with nothing on screen looks like one that quit.
    /// </summary>
    public bool FirstLaunchHintShown
    {
        get => _firstLaunchHintShown;
        set => Set(ref _firstLaunchHintShown, value);
    }

    // ==================================== Speed test ====================================

    /// <summary>"mlab" (the default, as on macOS) or "cloudflare"; remembered between runs.</summary>
    public string SpeedTestProvider
    {
        get => _speedTestProvider;
        set => Set(ref _speedTestProvider, value is "mlab" ? "mlab" : "cloudflare");
    }

    /// <summary>
    /// M-Lab publishes every result, including the client's IP address, as open data. The
    /// Mac asks once before the first M-Lab run and so does this.
    /// </summary>
    public bool SpeedTestMLabConsent
    {
        get => _speedTestMLabConsent;
        set => Set(ref _speedTestMLabConsent, value);
    }

    // ================================== Network Slice ==================================

    /// <summary>The hosts column shows the last few seconds rather than the session's totals.</summary>
    public bool NetworkSliceHostsLive
    {
        get => _networkSliceHostsLive;
        set => Set(ref _networkSliceHostsLive, value);
    }

    public bool NetworkSliceServicesLive
    {
        get => _networkSliceServicesLive;
        set => Set(ref _networkSliceServicesLive, value);
    }

    public bool NetworkSliceAppsLive
    {
        get => _networkSliceAppsLive;
        set => Set(ref _networkSliceAppsLive, value);
    }

    // ===================================== Pinning =====================================

    /// <summary>The popover is pinned open as a movable window — the macOS Pin button.</summary>
    public bool PopoverPinned
    {
        get => _popoverPinned;
        set => Set(ref _popoverPinned, value);
    }

    public double? PinnedLeft
    {
        get => _pinnedLeft;
        set => Set(ref _pinnedLeft, value);
    }

    public double? PinnedTop
    {
        get => _pinnedTop;
        set => Set(ref _pinnedTop, value);
    }

    // ====================================== DNS ======================================

    /// <summary>Preset ids hidden from the popover switcher. Built-ins can be hidden, not deleted.</summary>
    public List<string> HiddenDnsPresets { get; set; } = [];

    /// <summary>User order of preset ids; presets not listed follow in their natural order.</summary>
    public List<string> DnsPresetOrder { get; set; } = [];

    /// <summary>Every preset in the user's order, hidden ones included (for Preferences).</summary>
    public IReadOnlyList<DnsPreset> OrderedDnsPresets()
    {
        var all = AllDnsPresets();
        var rank = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < DnsPresetOrder.Count; i++)
        {
            rank.TryAdd(DnsPresetOrder[i], i);
        }

        return
        [
            .. all.Select((preset, index) => (preset, index))
                .OrderBy(p => rank.TryGetValue(p.preset.Id, out var r) ? r : int.MaxValue)
                .ThenBy(p => p.index)
                .Select(p => p.preset),
        ];
    }

    /// <summary>The presets the popover offers.</summary>
    public IReadOnlyList<DnsPreset> VisibleDnsPresets()
        => [.. OrderedDnsPresets().Where(p => !HiddenDnsPresets.Contains(p.Id, StringComparer.Ordinal))];

    public void SetDnsPresetHidden(string id, bool hidden)
    {
        var isHidden = HiddenDnsPresets.Contains(id, StringComparer.Ordinal);
        if (isHidden == hidden)
        {
            return;
        }

        var updated = HiddenDnsPresets.Where(h => h != id).ToList();
        if (hidden)
        {
            updated.Add(id);
        }

        HiddenDnsPresets = updated;
        OnPropertyChanged(nameof(HiddenDnsPresets));
    }

    public void MoveDnsPreset(string id, int newIndex)
    {
        var order = OrderedDnsPresets().Select(p => p.Id).Where(p => p != id).ToList();
        order.Insert(Math.Clamp(newIndex, 0, order.Count), id);
        if (order.SequenceEqual(DnsPresetOrder, StringComparer.Ordinal))
        {
            return;
        }

        DnsPresetOrder = order;
        OnPropertyChanged(nameof(DnsPresetOrder));
    }

    // ===================================== Routers =====================================
    // Each integration is a switch plus an address; empty means "the default gateway".
    // Credentials never live here — they are in Credential Manager (see CredentialStore).

    public bool FritzBoxEnabled
    {
        get => _fritzBoxEnabled;
        set => Set(ref _fritzBoxEnabled, value);
    }

    public string FritzBoxHost
    {
        get => _fritzBoxHost;
        set => Set(ref _fritzBoxHost, (value ?? string.Empty).Trim());
    }

    public bool UniFiEnabled
    {
        get => _uniFiEnabled;
        set => Set(ref _uniFiEnabled, value);
    }

    public string UniFiHost
    {
        get => _uniFiHost;
        set => Set(ref _uniFiHost, (value ?? string.Empty).Trim());
    }

    /// <summary>Authenticate with a Network API key instead of a local admin login.</summary>
    public bool UniFiUseApiKey
    {
        get => _uniFiUseApiKey;
        set => Set(ref _uniFiUseApiKey, value);
    }

    public bool OpenWrtEnabled
    {
        get => _openWrtEnabled;
        set => Set(ref _openWrtEnabled, value);
    }

    public string OpenWrtHost
    {
        get => _openWrtHost;
        set => Set(ref _openWrtHost, (value ?? string.Empty).Trim());
    }

    public bool OpnSenseEnabled
    {
        get => _opnSenseEnabled;
        set => Set(ref _opnSenseEnabled, value);
    }

    public string OpnSenseHost
    {
        get => _opnSenseHost;
        set => Set(ref _opnSenseHost, (value ?? string.Empty).Trim());
    }

    /// <summary>
    /// The visibility rules assembled from the individual preferences.
    ///
    /// <para>Built here rather than at the call site so the popover, the totals and the
    /// Preferences list cannot end up disagreeing about which adapters count — the whole
    /// reason <see cref="AdapterVisibilityOptions"/> bundles them.</para>
    /// </summary>
    public AdapterVisibilityOptions VisibilityOptions() => new()
    {
        Hidden = HiddenAdapters.ToHashSet(StringComparer.OrdinalIgnoreCase),
        ShowOtherAdapters = ShowOtherAdapters,
        ShowInactive = ShowInactiveAdapters,
    };

    /// <summary>Whether <paramref name="adapterId"/> is currently hidden by the user.</summary>
    public bool IsAdapterHidden(string adapterId)
        => HiddenAdapters.Contains(adapterId, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Shows or hides one adapter. Mutates the list in place and republishes it, because
    /// <see cref="Set{T}"/> compares by reference for a List and would not fire otherwise —
    /// which would leave the setting saved but unapplied until something else changed.
    /// </summary>
    public void SetAdapterHidden(string adapterId, bool hidden)
    {
        var already = IsAdapterHidden(adapterId);
        if (already == hidden)
        {
            return;
        }

        var updated = HiddenAdapters
            .Where(id => !string.Equals(id, adapterId, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (hidden)
        {
            updated.Add(adapterId);
        }

        HiddenAdapters = updated;
        OnPropertyChanged(nameof(HiddenAdapters));
    }

    /// <summary>
    /// Renames one adapter, or clears the label back to the Windows connection name when
    /// given blank. Stored per interface GUID, so it survives the adapter being renamed in
    /// Windows or moving between ports.
    /// </summary>
    public void SetAdapterName(string adapterId, string? name)
    {
        var trimmed = name?.Trim();
        var updated = new Dictionary<string, string>(AdapterCustomNames, StringComparer.OrdinalIgnoreCase);

        if (string.IsNullOrEmpty(trimmed))
        {
            if (!updated.Remove(adapterId))
            {
                return;
            }
        }
        else
        {
            if (updated.TryGetValue(adapterId, out var existing) && existing == trimmed)
            {
                return;
            }

            updated[adapterId] = trimmed;
        }

        // Replaced rather than mutated, for the same reason SetAdapterHidden replaces its
        // list: Set<T> compares a Dictionary by reference and an in-place edit would never
        // raise a change, leaving the rename applied in memory and absent from disk.
        AdapterCustomNames = updated;
        OnPropertyChanged(nameof(AdapterCustomNames));
    }

    /// <summary>The user's label for an adapter, or <paramref name="fallback"/> if unnamed.</summary>
    public string AdapterDisplayName(string adapterId, string fallback)
        => AdapterCustomNames.TryGetValue(adapterId, out var custom) && !string.IsNullOrWhiteSpace(custom)
            ? custom
            : fallback;

    /// <summary>
    /// Moves one adapter to a new position, recording the full order as it stands.
    ///
    /// <para>The whole visible sequence is stored rather than just the moved id, because a
    /// position is only meaningful relative to its neighbours — saving "the VPN is third"
    /// says nothing once the list it was third in has changed.</para>
    /// </summary>
    public void MoveAdapter(IReadOnlyList<string> currentOrder, string adapterId, int newIndex)
    {
        var reordered = currentOrder
            .Where(id => !string.Equals(id, adapterId, StringComparison.OrdinalIgnoreCase))
            .ToList();

        reordered.Insert(Math.Clamp(newIndex, 0, reordered.Count), adapterId);

        if (reordered.SequenceEqual(AdapterOrder, StringComparer.OrdinalIgnoreCase))
        {
            return;
        }

        AdapterOrder = reordered;
        OnPropertyChanged(nameof(AdapterOrder));
    }

    /// <summary>Forgets the user's ordering, returning every surface to busiest-first.</summary>
    public void ResetAdapterOrder()
    {
        if (AdapterOrder.Count == 0)
        {
            return;
        }

        AdapterOrder = [];
        OnPropertyChanged(nameof(AdapterOrder));
    }

    /// <summary>The selected theme, or <see cref="AppTheme.System"/> for an unknown id.</summary>
    [JsonIgnore]
    public AppTheme Theme => AppTheme.Named(ThemeId);

    public ThemeColor ResolveDownloadColor(ThemeColor fallback)
        => AccentPalette.Resolve(DownloadAccent, DownloadCustomHex, fallback) ?? fallback;

    public ThemeColor ResolveUploadColor(ThemeColor fallback)
        => AccentPalette.Resolve(UploadAccent, UploadCustomHex, fallback) ?? fallback;

    /// <summary>
    /// The rate colours every surface should draw with, given what Windows' own light or dark
    /// shell would use.
    ///
    /// <para><b>Precedence, which is the whole point of this method.</b> A theme supplies the
    /// base pair; an accent set to anything other than "Automatic" overrides it for that row.
    /// So picking Dracula recolours both rows, and a user who has separately pinned upload to
    /// orange keeps their orange. Matching macOS, where the theme sets the palette and the
    /// per-element colour pickers win over it.</para>
    ///
    /// <para>This exists because the two halves used to be wired independently: the theme
    /// picker wrote <see cref="ThemeId"/> and nothing ever read it, so choosing Dracula
    /// changed a line in the settings file and nothing else.</para>
    /// </summary>
    public (ThemeColor Download, ThemeColor Upload) ResolveRateColors(
        ThemeColor systemDownload,
        ThemeColor systemUpload)
    {
        var theme = Theme;

        var baseDownload = theme.IsExplicit ? theme.DownloadColor : systemDownload;
        var baseUpload = theme.IsExplicit ? theme.UploadColor : systemUpload;

        return (ResolveDownloadColor(baseDownload), ResolveUploadColor(baseUpload));
    }

    private void OnPropertyChanged(string name)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
