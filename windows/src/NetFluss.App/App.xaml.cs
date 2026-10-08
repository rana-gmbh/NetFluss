// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Interop;
using NetFluss.App.Popover;
using NetFluss.Core;
using NetFluss.Tray;

namespace NetFluss.App;

/// <summary>
/// Entry point. Mirrors the macOS <c>AppDelegate</c> → <c>AppState</c> →
/// <c>NetworkMonitor</c> + <c>StatusBarController</c> wiring order.
///
/// <para>The class is not called <c>App</c> on purpose: a type named <c>App</c> inside a
/// namespace ending in <c>.App</c> resolves ambiguously in generated XAML partials.</para>
/// </summary>
public partial class NetFlussApplication : Application
{
    /// <summary>
    /// Clicking the tray icon while the popover is open deactivates it first, so by the
    /// time the click arrives the popover has already hidden itself and the toggle would
    /// immediately reopen it. Ignoring a toggle that lands right after a hide is the
    /// standard fix; NSPopover handles this for us on macOS.
    /// </summary>
    private static readonly TimeSpan ReopenSuppressionWindow = TimeSpan.FromMilliseconds(250);

    private SingleInstance? _instance;
    private SettingsStore? _store;
    private NetworkMonitorService? _monitor;
    private HelperClient? _helper;
    private TrafficService? _traffic;
    private WifiService? _wifi;
    private DnsSwitcher? _dns;
    private PrivilegedActions? _privileged;
    private StatisticsService? _statistics;
    private RouterService? _routers;
    private IDisposable? _dashboardRouters;
    private Vpn.VpnManager? _vpn;
    private StatisticsWindow? _statisticsWindow;
    private NetworkSliceWindow? _sliceWindow;
    private AboutWindow? _aboutWindow;
    private DiagnosticsWindow? _diagnosticsWindow;
    private UpdateNotifier? _updates;
    private readonly TrafficTimer _timer = new();
    private AppCommands? _commands;
    private TrayIconHost? _tray;
    private PopoverWindow? _popover;
    private PreferencesWindow? _preferences;
    private TaskbarOverlayWindow? _overlay;
    private FloatingWidgetWindow? _widget;
    private SpeedTestWindow? _speedTest;
    private SpeedTestHistory? _speedTestHistory;
    private DateTime _popoverHiddenAt = DateTime.MinValue;
    private bool _lastIPv6;

    /// <summary>
    /// Set when the overlay was asked for but could not anchor to the taskbar, so the tray
    /// meter is standing in for it. Preferences reads this to explain itself rather than
    /// leaving the user staring at a setting that appears to do nothing.
    /// </summary>
    internal static bool OverlayFellBackToTray { get; private set; }

    internal AppCommands Commands => _commands!;

    /// <summary>Set first thing in OnExit: from then on nothing re-applies settings or repaints.</summary>
    private bool _exiting;

    /// <summary>Whether this instance wrote the session marker, and so removes it on exit.</summary>
    private bool _ownsSession;

    /// <summary>What clicking the last notification does: About for an update, the popover for the hint.</summary>
    private Action? _notificationAction;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        CrashLog.Install(this);

        // The UI-thread handler above marks exceptions handled so a broken section cannot take
        // the meter down. During startup that is the wrong call: it stopped startup half-way
        // and left a process with no icon and no meter that still held the single-instance
        // lock, so every later launch handed over to it and quit. Fail whole instead.
        try
        {
            Start(e);
        }
        catch (Exception exception)
        {
            CrashLog.Write("startup", exception);
            Shutdown(1);
        }
    }

    private void Start(StartupEventArgs e)
    {
        // One NetFluss per session. A second launch hands its arguments to the first and
        // leaves — which, with no arguments, opens the popover of the one already running.
        _instance = SingleInstance.Acquire();
        if (!_instance.IsPrimary)
        {
            _instance.Forward(e.Args);
            _instance.Dispose();
            _instance = null;
            Shutdown();
            return;
        }

        // Only the primary instance owns the session marker: a second launch that hands over
        // and quits must not erase the running one's.
        var uncleanSince = SessionGuard.Begin();
        _ownsSession = true;

        _store = new SettingsStore(SettingsStore.DefaultPath);
        ApplyInstallerChoices(_store);
        NetFluss.Core.Localization.Use(_store.Settings.Language);
        _lastIPv6 = _store.Settings.ExternalIPv6;

        _monitor = new NetworkMonitorService(TimeSpan.FromSeconds(_store.Settings.RefreshIntervalSeconds));
        _helper = new HelperClient(Dispatcher);
        _traffic = new TrafficService(_helper);
        _wifi = new WifiService(_store);
        _privileged = new PrivilegedActions(_helper);
        _dns = new DnsSwitcher(_store, _monitor, _privileged);
        _statistics = new StatisticsService(_store, _monitor);
        _routers = new RouterService(_monitor, _store);
        _vpn = new Vpn.VpnManager(_helper, _privileged, _store, _monitor, Dispatcher);
        _updates = new UpdateNotifier(_store);
        _updates.UpdateFound += OnUpdateFound;

        _commands = new AppCommands
        {
            ShowPreferences = () => ShowPreferences(),
            ShowSpeedTest = ShowSpeedTest,
            ShowStatistics = ShowStatistics,
            ShowNetworkSlice = ShowNetworkSlice,
            ShowAbout = ShowAbout,
            CopyDiagnostics = CopyDiagnostics,
            Quit = Shutdown,
        };

        _tray = new TrayIconHost(_monitor, BuildMeterOptions(), _commands);
        _tray.LeftClicked += (_, _) => TogglePopover(Screens.CursorAnchor());
        _tray.NotificationClicked += (_, _) => (_notificationAction ?? ShowAbout)();

        // Preferences writes, then everything re-reads. One direction, so there is no way
        // for the tray and the settings file to disagree about what is configured.
        _store.Changed += (_, change) =>
        {
            if (!change.IsStateOnly)
            {
                ApplySettings();
            }
        };

        // Surfaces repaint on the same tick that drives the tray meter.
        _monitor.PropertyChanged += (_, args) =>
        {
            if (_exiting)
            {
                return;
            }

            if (args.PropertyName == nameof(NetworkMonitorService.Totals))
            {
                PushTotals();
            }
            else if (args.PropertyName is nameof(NetworkMonitorService.Addresses) or nameof(NetworkMonitorService.PublicAddress))
            {
                PushAccessories();
            }
        };

        // The Traffic Timer counts whether or not the popover is open, and comes back paused
        // after a restart: traffic while NetFluss was not running cannot be counted.
        _timer.Restore(_store.Settings.TrafficTimerSession);
        _monitor.Ticked += (_, _) => _timer.Ingest(_monitor.LastSample, _store.Settings.ExcludeTunnelAdapters);
        var lastTimerState = _timer.State;
        _timer.Changed += (_, _) =>
        {
            if (_timer.State != lastTimerState)
            {
                lastTimerState = _timer.State;
                SaveTimer();
            }
        };

        ApplySettings();
        _monitor.Start();

        _instance.Listen(args => Dispatcher.BeginInvoke(() => HandleCommand(args)));

        // The helper is optional; connecting quietly in the background means a popover
        // opened later already knows whether per-app traffic is available.
        _helper.EnsureConnecting();
        _updates.Start();
        _vpn.ConnectOnLaunchIfNeeded();

        // Sign-out, shutdown and sleep must not lose the last few minutes of history or a
        // running timer: OnExit is not guaranteed to run when Windows ends the session, and
        // a machine that never wakes from sleep never exits at all.
        SessionEnding += (_, _) =>
        {
            // Windows ending the session is a clean end, even if OnExit never runs.
            SessionGuard.End();
            PersistState();
        };
        // While the session is locked nobody sees the popover, the meter's VPN mark or the
        // router rates: pause their lookups (macOS does the same on lock and display sleep).
        Microsoft.Win32.SystemEvents.SessionSwitch += (_, args) =>
        {
            var quiet = args.Reason switch
            {
                Microsoft.Win32.SessionSwitchReason.SessionLock or Microsoft.Win32.SessionSwitchReason.ConsoleDisconnect or
                    Microsoft.Win32.SessionSwitchReason.RemoteDisconnect => true,
                Microsoft.Win32.SessionSwitchReason.SessionUnlock or Microsoft.Win32.SessionSwitchReason.ConsoleConnect or
                    Microsoft.Win32.SessionSwitchReason.RemoteConnect => false,
                _ => (bool?)null,
            };

            if (quiet is { } value)
            {
                Dispatcher.BeginInvoke(() => _monitor.Quiet = value);
            }
        };

        // Windows switching between light and dark, or changing its accent, changes the taskbar
        // the meters are drawn for and the surface of every window — until now only a
        // NetFluss setting change or a restart picked that up. Windows sends several of these
        // per switch, so they are gathered into one repaint.
        var themeChanged = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        themeChanged.Tick += (_, _) =>
        {
            themeChanged.Stop();
            if (!_exiting)
            {
                ApplySettings();
                _preferences?.ApplySystemTheme();
            }
        };

        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, args) =>
        {
            if (args.Category is Microsoft.Win32.UserPreferenceCategory.General or Microsoft.Win32.UserPreferenceCategory.Color or
                Microsoft.Win32.UserPreferenceCategory.VisualStyle)
            {
                Dispatcher.BeginInvoke(() =>
                {
                    themeChanged.Stop();
                    themeChanged.Start();
                });
            }
        };

        Microsoft.Win32.SystemEvents.PowerModeChanged += (_, args) =>
        {
            // Raised on a SystemEvents thread; the settings write fans out to WPF objects.
            if (args.Mode == Microsoft.Win32.PowerModes.Suspend)
            {
                // This runs on the SystemEvents thread, where an exception is not caught by the
                // UI-thread handler and would end NetFluss as the machine goes to sleep.
                try
                {
                    Dispatcher.Invoke(PersistState);
                }
                catch (Exception exception)
                {
                    CrashLog.Write("suspend", exception);
                }
            }
        };

        HandleCommand(e.Args);

        // At idle, once the meter has been placed, so the hint can say where it really is.
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () => AfterStartup(uncleanSince));
    }

    /// <summary>
    /// The privacy choices made in the installer (NetFluss.iss writes them only from an
    /// interactive installation), taken over once and then removed, so Preferences stays in
    /// charge afterwards.
    /// </summary>
    private static void ApplyInstallerChoices(SettingsStore store)
    {
        const string key = @"Software\NetFluss\InstallerChoices";
        try
        {
            using (var choices = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(key))
            {
                if (choices is null)
                {
                    return;
                }

                var updates = choices.GetValue("AutomaticUpdateChecks") as int?;
                var lookups = choices.GetValue("AllowIpLookups") as int?;
                store.Batch(settings =>
                {
                    if (updates is { } update)
                    {
                        settings.AutomaticUpdateChecks = update != 0;
                    }

                    if (lookups is { } lookup)
                    {
                        settings.AllowIpLookups = lookup != 0;
                    }
                });
            }

            Microsoft.Win32.Registry.CurrentUser.DeleteSubKey(key, throwOnMissingSubKey: false);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException)
        {
            CrashLog.Write("installer choices", e);
        }
    }

    /// <summary>What can wait until NetFluss is up: the crash report and the first-launch hint.</summary>
    private async void AfterStartup(DateTimeOffset? uncleanSince)
    {
        if (uncleanSince is { } since)
        {
            // Reading the event log can take a moment; it is not the UI thread's job.
            var crashed = await Task.Run(() => SessionGuard.RecordPreviousCrash(since));
            if (crashed && !_exiting)
            {
                _notificationAction = CopyDiagnostics;
                _tray?.Notify("NetFluss", Localization.L("NetFluss quit unexpectedly last time. Click to see what Windows recorded, and please include it in a report."));
                return;
            }
        }

        if (_store is { Settings.FirstLaunchHintShown: false })
        {
            // A moment for the overlay to anchor, or fall back to the notification area.
            await Task.Delay(TimeSpan.FromSeconds(2));
            ShowFirstLaunchHint();
        }
    }

    /// <summary>
    /// Says once where NetFluss lives, and opens the popover there. On a Mac the menu bar item
    /// is always in view; on Windows a new icon goes behind the "^" overflow by default, and
    /// an app that shows nothing looks like one that quit.
    /// </summary>
    private void ShowFirstLaunchHint()
    {
        if (_store is null || _tray is null || _exiting)
        {
            return;
        }

        _store.Batch(settings => settings.FirstLaunchHintShown = true);

        var message = _store.Settings.MeterSurface == MeterSurface.TaskbarOverlay && _overlay is { IsAnchored: true }
            ? Localization.L("Your rates are on the taskbar, next to the clock. Click them for details, right-click them for Preferences.")
            : Localization.L("NetFluss is in the notification area. If you don't see its icon, click ^ next to the clock — you can drag the icon onto the taskbar to keep it in view.");
        _notificationAction = () => ShowPopover(DefaultAnchor());
        _tray.Notify(Localization.L("NetFluss is running"), message);
        ShowPopover(DefaultAnchor());
    }

    /// <summary>
    /// Command-line verbs, from this launch or forwarded from a later one. They make the
    /// app scriptable from a shortcut — "NetFluss.exe --speedtest" — and are what the
    /// verification harness drives the real UI with.
    /// </summary>
    private void HandleCommand(string[] args)
    {
        if (args.Length == 0)
        {
            return;
        }

        switch (args[0].ToLowerInvariant())
        {
            case "--popover":
                ShowPopover(DefaultAnchor());
                break;
            case "--hide-popover":
                if (_popover is { IsVisible: true })
                {
                    _popover.HideAndNotify();
                }

                break;
            case "--preferences":
                ShowPreferences(args.Length > 1 ? args[1] : null);
                break;
            case "--speedtest":
                ShowSpeedTest();
                break;
            case "--statistics":
                ShowStatistics();
                break;
            case "--slice":
                ShowNetworkSlice();
                break;
            case "--about":
                ShowAbout();
                break;
            case "--quit":
                Shutdown();
                break;
            case "--timer" when args.Length > 1:
                switch (args[1].ToLowerInvariant())
                {
                    case "start":
                        _timer.Start();
                        break;
                    case "pause":
                        _timer.Pause();
                        break;
                    case "reset":
                        _timer.Reset();
                        break;
                }

                break;
            case "--vpn" when args.Length > 1 && _vpn is not null:
                // "--vpn connect [profile name]" (the first profile without a name), "--vpn disconnect".
                if (args[1].Equals("disconnect", StringComparison.OrdinalIgnoreCase))
                {
                    _ = _vpn.DisconnectAsync();
                }
                else if (args[1].Equals("connect", StringComparison.OrdinalIgnoreCase))
                {
                    var name = args.Length > 2 ? string.Join(' ', args[2..]) : null;
                    var profile = name is null
                        ? _vpn.Profiles.FirstOrDefault()
                        : _vpn.Profiles.FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
                    if (profile is not null)
                    {
                        _vpn.Connect(profile);
                    }
                }

                break;
            case "--snapshot" when args.Length >= 3:
                var delay = args.Length > 3 && int.TryParse(args[3], out var ms) ? ms : 3000;
                SnapshotAsync(args[1].ToLowerInvariant(), args[2], delay).ContinueWith(
                    task => CrashLog.Write("snapshot", task.Exception!),
                    TaskContinuationOptions.OnlyOnFaulted);
                break;
        }
    }

    /// <summary>
    /// Renders a window to a PNG without showing it to anyone — the verification harness.
    /// Targets: "popover[:bottom|:section]", "preferences[:tab]", "speedtest", "widget", "taskbar".
    /// </summary>
    private async Task SnapshotAsync(string target, string path, int delayMilliseconds)
    {
        if (target == "popover" || target.StartsWith("popover:", StringComparison.Ordinal))
        {
            ShowPopover(DefaultAnchor(), offScreen: true);
            if (_popover is null)
            {
                return;
            }

            await Task.Delay(delayMilliseconds);

            // "popover:bottom", or "popover:vpn" for a section scrolled to the top.
            if (target.Length > "popover:".Length)
            {
                _popover.ScrollTo(target["popover:".Length..]);
            }

            Snapshot.Save(_popover, path);
            _popover.HideOffScreen();
            return;
        }

        // The live meters as they are on screen right now, accessories included.
        if (target is "widget" or "taskbar")
        {
            Window? live = target == "widget" ? _widget : _overlay;
            if (live is not null)
            {
                await Task.Delay(delayMilliseconds);
                Snapshot.Save(live, path);
            }

            return;
        }

        Window? window = null;
        if (target.StartsWith("preferences", StringComparison.Ordinal) && _store is not null && _monitor is not null)
        {
            var preferences = new PreferencesWindow(PreferencesContext());
            // "preferences:vpn:bottom" opens a page scrolled to its end.
            var parts = target.Split(':');
            if (parts.Length > 1)
            {
                preferences.SelectTab(parts[1]);
            }

            if (parts.Contains("bottom"))
            {
                preferences.ContentRendered += (_, _) => preferences.ScrollToEnd();
            }

            window = preferences;
        }
        else if (target == "menu" && _commands is not null)
        {
            // A popup cannot be placed off-screen and a ContextMenu cannot live in a window,
            // so its items are laid out in a frame matching its template, with its resources.
            var menu = SurfaceMenu.Build(_commands);
            var items = menu.Items.Cast<object>().ToList();
            menu.Items.Clear();
            var panel = new System.Windows.Controls.StackPanel();
            foreach (var item in items.Cast<UIElement>())
            {
                if (item is System.Windows.Controls.Separator separator)
                {
                    separator.SetResourceReference(FrameworkElement.StyleProperty, System.Windows.Controls.MenuItem.SeparatorStyleKey);
                }

                panel.Children.Add(item);
            }

            var frame = new System.Windows.Controls.Border { Padding = new Thickness(4), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = panel, Margin = new Thickness(12) };
            frame.SetResourceReference(System.Windows.Controls.Border.BackgroundProperty, "NfMenuBackground");
            frame.SetResourceReference(System.Windows.Controls.Border.BorderBrushProperty, "NfMenuBorder");
            var host = new Window { Content = frame, SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None, FontFamily = menu.FontFamily, FontSize = 13 };
            host.Resources.MergedDictionaries.Add(menu.Resources);
            window = host;
        }
        else if (target == "about" && _store is not null && _updates is not null)
        {
            var (surface, download, upload) = Palette();
            window = new AboutWindow(_updates, surface, download, upload);
        }
        else if (target.StartsWith("speedtest", StringComparison.Ordinal) && _store is not null)
        {
            // "speedtest:result|running|consent|error|history|note" previews a state with
            // sample numbers and a throwaway history, so snapshots never touch the real one.
            var (surface, download, upload) = Palette();
            var speedTest = new SpeedTestWindow(_store, new SpeedTestHistory(null), surface, download, upload);
            if (target.Split(':') is [_, var state])
            {
                speedTest.Preview(state);
            }

            window = speedTest;
        }
        else if (target.StartsWith("slice", StringComparison.Ordinal) && _store is not null && _monitor is not null && _traffic is not null && _helper is not null)
        {
            // "slice:demo[:host|service|app]" fills the window with generated traffic and,
            // optionally, opens the drill-down for that column's top row.
            var parts = target.Split(':');
            var slice = CreateSliceWindow(parts.Contains("demo"));
            var detail = parts.Contains("host") ? SliceKind.Host : parts.Contains("service") ? SliceKind.Service : parts.Contains("app") ? SliceKind.App : (SliceKind?)null;
            if (detail is { } kind)
            {
                slice.Loaded += (_, _) => slice.PreviewDetail(kind);
            }

            window = slice;
        }
        else if (target.StartsWith("statistics", StringComparison.Ordinal) && _store is not null && _statistics is not null)
        {
            // "statistics:demo:30d" previews the generated year at a given range.
            var parts = target.Split(':');
            _statistics.SetDemo(parts.Contains("demo"));
            var settings = _store.Settings;
            var (systemDownload, systemUpload) = SystemTheme.DefaultInk();
            var (download, upload) = settings.ResolveRateColors(systemDownload, systemUpload);
            var statisticsWindow = new StatisticsWindow(_statistics, _store, settings.Theme.Surface(SystemTheme.IsAppLight()), download, upload, () => { });
            foreach (var range in Enum.GetValues<StatisticsRange>())
            {
                if (parts.Contains(range.Code().ToLowerInvariant()))
                {
                    statisticsWindow.InitialRange = range;
                }
            }

            window = statisticsWindow;
        }

        if (window is null)
        {
            return;
        }

        window.ShowActivated = false;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = Snapshot.OffScreen;
        window.Top = Snapshot.OffScreen;
        window.Show();
        await Task.Delay(delayMilliseconds);
        Snapshot.Save(window, path);
        window.Close();
        _statistics?.SetDemo(false);
    }

    /// <summary>Where the popover opens when nothing was clicked: the meter, or the tray corner.</summary>
    private Rect DefaultAnchor()
    {
        if (_overlay is { IsAnchored: true })
        {
            return Screens.WindowAnchor(new WindowInteropHelper(_overlay).Handle);
        }

        // Bottom-right of the primary monitor, where the notification area normally is.
        var monitor = Screens.MonitorFromPoint(0, 0);
        return monitor is { } info
            ? new Rect(info.Work.Right - 40, info.Work.Bottom - 8, 16, 8)
            : Screens.CursorAnchor();
    }

    private void SaveTimer() => _store?.Batch(settings => settings.TrafficTimerSession = _timer.Save());

    /// <summary>
    /// The VPN mark and exit country after the rates on the taskbar meter and the widget.
    /// Each draws its dimmed state in its own secondary ink: the taskbar's, or the theme's.
    /// </summary>
    private void PushAccessories()
    {
        if (_store is null || _monitor is null)
        {
            return;
        }

        var settings = _store.Settings;
        var vpn = _monitor.Addresses.IsVpnActive;
        var country = _monitor.PublicAddress?.CountryCode;

        if (_overlay is not null)
        {
            var taskbarIdle = SystemTheme.IsShellLight() ? ThemeColor.FromHex("5D5D5D") : ThemeColor.FromHex("C5C5C5");
            _overlay.SetAccessories(MeterAccessories.From(settings, vpn, country, taskbarIdle), settings.ReadoutFontSize);
        }

        if (_widget is not null)
        {
            var surface = settings.Theme.Surface(SystemTheme.IsAppLight());
            _widget.SetAccessories(MeterAccessories.From(settings, vpn, country, surface.TextSecondary));
        }

        _tray?.SetVpnStatus(settings.VpnIndicator != "off" ? (vpn, country) : null);
    }

    private void PushTotals()
    {
        if (_store is null || _monitor is null)
        {
            return;
        }

        // Dashboard prefers the router's view of the whole line, as on macOS.
        DashboardMetrics? dashboard = null;
        if (_store.Settings.ReadoutStyle is ReadoutStyle.Dashboard or ReadoutStyle.DashboardBasic)
        {
            dashboard = _routers?.DashboardSource() is { } router
                ? DashboardMetrics.Router(router.Bandwidth, router.Key)
                : DashboardMetrics.Local(_monitor.Totals);
        }

        _overlay?.Update(_monitor.Totals, _store.Settings.UseBits, dashboard);
        _widget?.Update(_monitor.Totals, _store.Settings.UseBits, dashboard);
    }

    private TrayMeterOptions BuildMeterOptions()
    {
        var settings = _store!.Settings;
        var (systemDownload, systemUpload) = SystemTheme.DefaultInk();
        var (downloadInk, uploadInk) = settings.ResolveRateColors(systemDownload, systemUpload);

        return new TrayMeterOptions
        {
            Size = Dpi.TrayIconSize(),
            Layout = PreferencesWindow.ToLayout(settings.MeterStyle),
            DownloadColor = downloadInk,
            UploadColor = uploadInk,
            UseBits = settings.UseBits,
            ShowArrows = settings.ShowArrows,
            TaskbarBackground = SystemTheme.TaskbarBackground(),
            MinimumContrastRatio = settings.EnforceContrast ? Contrast.MinimumReadableRatio : 0,
            IconGlyph = settings.TrayIconGlyph,
        };
    }

    private void ApplySettings()
    {
        if (_exiting || _store is null || _monitor is null || _tray is null)
        {
            return;
        }

        var settings = _store.Settings;
        NetFluss.Core.Localization.Use(settings.Language);

        _monitor.Interval = TimeSpan.FromSeconds(settings.RefreshIntervalSeconds);
        _monitor.ExcludeTunnelAdapters = settings.ExcludeTunnelAdapters;
        _monitor.TotalsFromVisibleAdaptersOnly = settings.TotalsFromVisibleAdaptersOnly;
        _monitor.AdapterGraceSeconds = settings.AdapterGraceEnabled ? settings.AdapterGraceSeconds : null;
        _monitor.PreferIPv6 = settings.ExternalIPv6;
        _monitor.DetectVpn = settings.NeedsVpnDetection;
        _monitor.MeterShowsCountry = settings.ShowCountryFlag;
        _monitor.AllowIpLookups = settings.AllowIpLookups;

        // Switching IPv4/IPv6 must show the other address now, not after the five-minute
        // cache runs out — on macOS the setting change triggers the same refetch.
        if (_lastIPv6 != settings.ExternalIPv6)
        {
            _lastIPv6 = settings.ExternalIPv6;
            _monitor.InvalidatePublicAddress();
        }

        // Adapter visibility was the same shape of bug as the theme: HiddenAdapters was
        // stored and round-trip tested, and nothing ever handed it to the monitor.
        _monitor.Visibility = settings.VisibilityOptions();
        _monitor.AdapterNames = settings.AdapterCustomNames;
        _monitor.AdapterOrder = settings.AdapterOrder;
        _monitor.Refresh();

        // The Dashboard style reads router-wide traffic, so routers are polled for it even
        // while the popover is closed — as on macOS — but only then.
        var dashboardWantsRouters = settings.ReadoutStyle == ReadoutStyle.Dashboard && settings.AnyRouterEnabled &&
                                    (settings.MeterSurface == MeterSurface.TaskbarOverlay || settings.ShowFloatingWidget);
        if (dashboardWantsRouters && _dashboardRouters is null)
        {
            _dashboardRouters = _routers?.Acquire();
        }
        else if (!dashboardWantsRouters && _dashboardRouters is not null)
        {
            _dashboardRouters.Dispose();
            _dashboardRouters = null;
        }

        var (systemDownload, systemUpload) = SystemTheme.DefaultInk();
        var (download, upload) = settings.ResolveRateColors(systemDownload, systemUpload);

        // One resolved palette for every themed window, so a theme cannot reach some
        // surfaces and not others — which is how it came to be wired to none of them.
        var surface = settings.Theme.Surface(SystemTheme.IsAppLight());

        ApplyOverlay(settings, download, upload);
        ApplyWidget(settings, download, upload, surface);
        ApplyPopoverTheme();
        _popover?.ApplyLayout();

        var overlayCarriesTheMeter = _overlay is { IsAnchored: true };

        // While another surface shows the numbers, the tray icon drops to a static glyph so
        // the rates are not displayed twice — but it stays *present*, because it is where a
        // Windows user looks for a background app's menu. Hiding it is opt-in.
        _tray.Options = overlayCarriesTheMeter
            ? BuildMeterOptions() with { Layout = TrayMeterLayout.Icon }
            : BuildMeterOptions();

        _tray.Redraw();
        _tray.IsVisible = !(settings.HideTrayIcon && overlayCarriesTheMeter);

        PushTotals();
        PushAccessories();
    }

    private void ApplyOverlay(AppSettings settings, ThemeColor download, ThemeColor upload)
    {
        if (settings.MeterSurface != MeterSurface.TaskbarOverlay)
        {
            _overlay?.Stop();
            _overlay?.Close();
            _overlay = null;
            OverlayFellBackToTray = false;
            return;
        }

        if (_overlay is null)
        {
            _overlay = new TaskbarOverlayWindow(_monitor!)
            {
                ContextMenu = SurfaceMenu.Build(_commands!),
            };

            _overlay.Clicked += (_, _) => TogglePopover(Screens.WindowAnchor(new WindowInteropHelper(_overlay).Handle));

            // The overlay reports rather than decides. Losing the anchor brings the tray
            // meter back immediately, so there is never a moment with no meter at all.
            _overlay.AnchorLost += (_, _) =>
            {
                OverlayFellBackToTray = true;
                if (_tray is not null)
                {
                    _tray.IsVisible = true;
                }

                // The icon was the static glyph while the overlay carried the rates; it has to
                // carry them now. Deferred: this is raised from inside a placement.
                Dispatcher.BeginInvoke(ApplySettings);
            };

            // And back: the tray returns to the glyph (or hides, if the user asked), and the
            // "showing in the notification area instead" notice goes.
            _overlay.AnchorRegained += (_, _) =>
            {
                if (OverlayFellBackToTray)
                {
                    Dispatcher.BeginInvoke(ApplySettings);
                }
            };

            _overlay.Start();
        }

        _overlay.ApplySettings(settings, download, upload);
        OverlayFellBackToTray = !_overlay.IsAnchored;
    }

    /// <summary>Pushes the current theme into the popover, whenever one exists to push into.</summary>
    private void ApplyPopoverTheme()
    {
        if (_store is null || _popover is null)
        {
            return;
        }

        var settings = _store.Settings;
        var (systemDownload, systemUpload) = SystemTheme.DefaultInk();
        var (download, upload) = settings.ResolveRateColors(systemDownload, systemUpload);

        _popover.ApplyTheme(settings.Theme.Surface(SystemTheme.IsAppLight()), download, upload);
    }

    private void ApplyWidget(AppSettings settings, ThemeColor download, ThemeColor upload, SurfacePalette surface)
    {
        if (!settings.ShowFloatingWidget)
        {
            _widget?.CloseForGood();
            _widget = null;
            return;
        }

        if (_widget is null)
        {
            _widget = new FloatingWidgetWindow(settings)
            {
                ContextMenu = SurfaceMenu.Build(_commands!),
            };

            _widget.Clicked += (_, _) => TogglePopover(Screens.WindowAnchor(new WindowInteropHelper(_widget).Handle));

            // Alt+F4 turns the widget off, as the Preferences switch does. Deferred, because WPF
            // also closes every window when the app quits — before OnExit sets _exiting — and a
            // quit must not switch the widget off for the next start.
            _widget.CloseRequested += (_, _) => Dispatcher.BeginInvoke(() =>
            {
                if (!_exiting && _store is not null)
                {
                    _store.Settings.ShowFloatingWidget = false;
                }
            });
            _widget.Show();
            _widget.Place();
        }

        _widget.ApplySettings(settings, download, upload, surface);
    }

    /// <summary>The themed palette for a window opened now: surface, then the two rate inks.</summary>
    private (SurfacePalette Surface, ThemeColor Download, ThemeColor Upload) Palette()
    {
        var settings = _store!.Settings;
        var (systemDownload, systemUpload) = SystemTheme.DefaultInk();
        var (download, upload) = settings.ResolveRateColors(systemDownload, systemUpload);
        return (settings.Theme.Surface(SystemTheme.IsAppLight()), download, upload);
    }

    /// <summary>
    /// Opens one of the app's windows, or brings the open one forward — every window is a
    /// singleton, as on macOS, where choosing a menu item twice never stacks two copies.
    /// </summary>
    private void Open<T>(Func<T?> current, Action<T?> remember, Func<T> create)
        where T : Window
    {
        if (current() is { IsLoaded: true } open)
        {
            if (open.WindowState == WindowState.Minimized)
            {
                open.WindowState = WindowState.Normal;
            }

            open.Activate();
            return;
        }

        var window = create();
        AppIcon.Apply(window);
        window.Closed += (_, _) => remember(null);
        remember(window);
        window.Show();
        window.Activate();
    }

    private void ShowSpeedTest()
    {
        if (_store is not null)
        {
            Open(() => _speedTest, w => _speedTest = w, () =>
            {
                var (surface, download, upload) = Palette();
                _speedTestHistory ??= new SpeedTestHistory(SpeedTestHistory.DefaultPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)));
                return new SpeedTestWindow(_store, _speedTestHistory, surface, download, upload);
            });
        }
    }

    private void ShowStatistics()
    {
        if (_store is null || _statistics is null)
        {
            return;
        }

        Open(() => _statisticsWindow, w => _statisticsWindow = w, () =>
        {
            var (surface, download, upload) = Palette();
            return new StatisticsWindow(_statistics, _store, surface, download, upload, () => ShowPreferences("statistics"));
        });
    }

    private void ShowNetworkSlice()
    {
        if (_store is null || _monitor is null || _traffic is null || _helper is null)
        {
            return;
        }

        Open(() => _sliceWindow, w => _sliceWindow = w, () => CreateSliceWindow(StatisticsService.DemoAvailable && Environment.GetEnvironmentVariable("NETFLUSS_SAMPLE_SLICE") == "1"));
    }

    private NetworkSliceWindow CreateSliceWindow(bool demo)
    {
        var (surface, download, upload) = Palette();
        return new NetworkSliceWindow(_monitor!, _traffic!, _helper!, _store!, surface, download, upload, demo);
    }

    private void ShowAbout()
    {
        if (_store is null || _updates is null)
        {
            return;
        }

        Open(() => _aboutWindow, w => _aboutWindow = w, () =>
        {
            var (surface, download, upload) = Palette();
            return new AboutWindow(_updates, surface, download, upload);
        });
    }

    private void CopyDiagnostics()
    {
        if (_store is null || _monitor is null || _helper is null)
        {
            return;
        }

        Open(() => _diagnosticsWindow, w => _diagnosticsWindow = w, () =>
        {
            var (surface, download, upload) = Palette();
            return new DiagnosticsWindow(_monitor, _helper, _store, surface, download, upload);
        });
    }

    private PreferencesContext PreferencesContext() => new()
    {
        Store = _store!,
        Monitor = _monitor!,
        Helper = _helper!,
        Privileged = _privileged!,
        Statistics = _statistics!,
        Traffic = _traffic!,
        Routers = _routers!,
        Vpn = _vpn!,
        Commands = _commands!,
    };

    private void ShowPreferences(string? tab = null)
    {
        if (_store is null)
        {
            return;
        }

        Open(() => _preferences, w => _preferences = w, () => new PreferencesWindow(PreferencesContext()));
        if (tab is not null)
        {
            _preferences?.SelectTab(tab);
        }
    }

    /// <summary>
    /// A newer release was found: one notification from the tray, and a quiet line in the
    /// popover footer for as long as it stays relevant.
    /// </summary>
    private void OnUpdateFound(object? sender, AvailableUpdate update)
    {
        var message = Localization.L("NetFluss {0} is available!", update.Version);
        _notificationAction = ShowAbout;
        _tray?.Notify("NetFluss", message);
        _popover?.SetFooterStatus(message);
    }

    private void TogglePopover(Rect anchor)
    {
        if (_popover is { IsVisible: true })
        {
            // A pinned popover is a window, not a popover: clicking the meter brings it
            // forward rather than closing it.
            if (_popover.IsPinned)
            {
                _popover.Activate();
            }
            else
            {
                _popover.HideAndNotify();
            }

            return;
        }

        if (DateTime.UtcNow - _popoverHiddenAt < ReopenSuppressionWindow)
        {
            return;
        }

        ShowPopover(anchor);
    }

    private void ShowPopover(Rect anchor, bool offScreen = false)
    {
        if (_monitor is null || _store is null)
        {
            return;
        }

        if (_popover is null)
        {
            _popover = new PopoverWindow(new PopoverContext
            {
                Monitor = _monitor,
                Store = _store,
                Wifi = _wifi!,
                Dns = _dns!,
                Traffic = _traffic!,
                Helper = _helper!,
                Privileged = _privileged!,
                Statistics = _statistics!,
                Timer = _timer,
                Routers = _routers!,
                Vpn = _vpn!,
                Commands = _commands!,
            });

            _popover.Hidden += (_, _) => _popoverHiddenAt = DateTime.UtcNow;
            if (_updates?.Available is { } update)
            {
                _popover.SetFooterStatus(Localization.L("NetFluss {0} is available!", update.Version));
            }

            // Themed on creation as well as on every settings change: the window is built
            // lazily on first open, so waiting for a change would show it unthemed once.
            ApplyPopoverTheme();
        }

        if (_popover.IsVisible)
        {
            if (!offScreen)
            {
                _popover.Activate();
            }

            return;
        }

        if (offScreen)
        {
            _popover.ShowOffScreen();
            return;
        }

        _popover.ShowAt(anchor);
    }

    /// <summary>Writes everything that lives in memory between periodic saves.</summary>
    private void PersistState()
    {
        SaveTimer();
        _statistics?.Flush();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        // Saving the timer is a settings write, and every settings write re-applies settings
        // to the meters. Do it while they still exist, and let nothing react after this —
        // re-applying to closed windows and a disposed icon is what used to throw here.
        _exiting = true;
        SaveTimer();

        _overlay?.Stop();
        _overlay?.Close();
        _widget?.CloseForGood();
        _tray?.Dispose();
        _traffic?.Dispose();
        _statistics?.Dispose();
        _routers?.Dispose();
        _vpn?.Dispose();
        _helper?.Dispose();
        _monitor?.Dispose();
        _instance?.Dispose();

        if (_ownsSession)
        {
            SessionGuard.End();
        }

        base.OnExit(e);
    }
}
