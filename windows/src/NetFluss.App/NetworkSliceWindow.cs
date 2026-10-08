// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Globalization;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// Network Slice — port of the macOS <c>NetworkSliceView</c>: who this PC is talking to
/// right now. A live traffic chart, then the busiest remote hosts, services and apps, each
/// switchable between the last few seconds and the session's totals, and a slide-in
/// table of the connections behind any row.
///
/// <para>The macOS window diffs <c>netstat</c> snapshots; here the Kernel-Network trace
/// (through the helper service) already reports per-flow bytes for each interval. The
/// trace runs only while this window is open.</para>
/// </summary>
internal sealed class NetworkSliceWindow : Window
{
    private const int MaximumRatePoints = 240;
    private const int MaximumDetailRows = 300;

    private static readonly HttpClient Http = CreateHttp();

    private readonly NetworkMonitorService _monitor;
    private readonly TrafficService _traffic;
    private readonly HelperClient _helper;
    private readonly SettingsStore _store;
    private readonly NetworkSlice _slice = new();
    private readonly List<(DateTime Time, double Rx, double Tx)> _ratePoints = [];
    private readonly HashSet<string> _lookupsInFlight = [];
    private readonly NetworkSliceDemo? _demo;
    private readonly DispatcherTimer? _demoTimer;

    private readonly TextBlock _rxRate = Ui.Number("—", 15, Ui.Text, FontWeights.SemiBold);
    private readonly TextBlock _txRate = Ui.Number("—", 15, Ui.Text, FontWeights.SemiBold);
    private readonly TextBlock _rxSession = Ui.Number(string.Empty, 11, Ui.Secondary);
    private readonly TextBlock _txSession = Ui.Number(string.Empty, 11, Ui.Secondary);
    private readonly Button _pause;
    private readonly SliceRateChart _chart = new();
    private readonly TextBlock _chartPlaceholder;
    private readonly Border _helperBanner;
    private readonly TextBlock _helperText = Ui.Wrapping(string.Empty, 12);
    private readonly Button _helperButton;
    private readonly SliceColumn[] _columns;
    private readonly Grid _detailLayer = new() { Visibility = Visibility.Collapsed, ClipToBounds = true };

    private (SliceKind Kind, SliceEntry Entry)? _detail;
    private IDisposable? _lease;
    private bool _paused;
    private bool _installing;
    private int _detailRenderedFor = -1;

    internal NetworkSliceWindow(
        NetworkMonitorService monitor,
        TrafficService traffic,
        HelperClient helper,
        SettingsStore store,
        SurfacePalette surface,
        ThemeColor download,
        ThemeColor upload,
        bool demo)
    {
        _monitor = monitor;
        _traffic = traffic;
        _helper = helper;
        _store = store;

        Title = Localization.L("Network Slice");
        Width = 1080;
        Height = 760;
        MinWidth = 920;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Ui.UiFont;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/NetFluss;component/PopoverResources.xaml") });
        ThemeBrushes.Apply(Resources, surface, download, upload);
        SetResourceReference(BackgroundProperty, "PopoverBackgroundBrush");
        SourceInitialized += (_, _) => ThemeBrushes.ApplyFrame(this, surface.IsDark);

        _pause = Ui.TextButton(string.Empty, TogglePause, accent: false);
        _helperButton = Ui.TextButton(string.Empty, InstallHelper, accent: true);
        _chartPlaceholder = Ui.Label(Localization.L("Gathering data…"), 13, Ui.Secondary);
        _chartPlaceholder.HorizontalAlignment = HorizontalAlignment.Center;

        var settings = store.Settings;
        _columns =
        [
            new SliceColumn(this, SliceKind.Host, "Network Hosts", Glyph.Globe, s => s.NetworkSliceHostsLive, (s, v) => s.NetworkSliceHostsLive = v, "No active hosts right now."),
            new SliceColumn(this, SliceKind.Service, "Services", Glyph.Tag, s => s.NetworkSliceServicesLive, (s, v) => s.NetworkSliceServicesLive = v, "No active services right now."),
            new SliceColumn(this, SliceKind.App, "Apps", Glyph.Apps, s => s.NetworkSliceAppsLive, (s, v) => s.NetworkSliceAppsLive = v, "No active apps right now."),
        ];

        _helperBanner = HelperBanner();

        var columns = Ui.Columns(Ui.Star, Ui.Fixed(18), Ui.Star, Ui.Fixed(18), Ui.Star);
        columns.Margin = new Thickness(0, 18, 0, 0);
        for (var i = 0; i < _columns.Length; i++)
        {
            columns.Children.Add(_columns[i].View.At(i * 2));
        }

        var body = new Grid();
        body.Children.Add(new ScrollViewer
        {
            Content = Ui.Column(_helperBanner, RateCard(), columns).Margin(24, 24, 24, 24),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        _detailLayer.SetResourceReference(Panel.BackgroundProperty, "PopoverBackgroundBrush");
        body.Children.Add(_detailLayer);

        var page = new DockPanel();
        var header = Header();
        DockPanel.SetDock(header, Dock.Top);
        page.Children.Add(header);
        var divider = Ui.Divider();
        DockPanel.SetDock(divider, Dock.Top);
        page.Children.Add(divider);
        page.Children.Add(body);
        Content = page;

        if (demo)
        {
            _demo = new NetworkSliceDemo();
            _demo.Prime(_slice);
            _demoTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _demoTimer.Tick += (_, _) => DemoTick();
        }

        Loaded += (_, _) => Start();
        Closed += (_, _) => Stop();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape && _detail is not null)
            {
                CloseDetail();
                e.Handled = true;
            }
        };

        Render();
    }

    private static HttpClient CreateHttp()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("NetFluss-Windows");
        return http;
    }

    private bool UseBits => _store.Settings.UseBits;

    // ===================================== Lifecycle =====================================

    private void Start()
    {
        _monitor.Ticked += OnMonitorTick;
        _store.Settings.PropertyChanged += OnSettingChanged;
        if (_demo is not null)
        {
            // Fills the window at once, so a preview needs no waiting.
            for (var i = 0; i < 30; i++)
            {
                DemoTick(DateTime.Now.AddSeconds(i - 30));
            }

            _demoTimer!.Start();
            return;
        }

        _traffic.Sampled += OnSampled;
        _traffic.AvailabilityChanged += OnAvailabilityChanged;
        _helper.ConnectionChanged += OnAvailabilityChanged;
        _lease = _traffic.Acquire(flows: true);
        UpdateHelperBanner();
    }

    private void Stop()
    {
        _monitor.Ticked -= OnMonitorTick;
        _store.Settings.PropertyChanged -= OnSettingChanged;
        _traffic.Sampled -= OnSampled;
        _traffic.AvailabilityChanged -= OnAvailabilityChanged;
        _helper.ConnectionChanged -= OnAvailabilityChanged;
        _demoTimer?.Stop();
        _lease?.Dispose();
        _lease = null;
    }

    private void OnSettingChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppSettings.UseBits) or nameof(AppSettings.NetworkSliceHostsLive)
            or nameof(AppSettings.NetworkSliceServicesLive) or nameof(AppSettings.NetworkSliceAppsLive))
        {
            Render();
        }
    }

    private void OnAvailabilityChanged(object? sender, EventArgs e) => UpdateHelperBanner();

    private void TogglePause()
    {
        _paused = !_paused;
        Render();
    }

    private void OnMonitorTick(object? sender, EventArgs e)
    {
        if (_paused || _demo is not null)
        {
            return;
        }

        var totals = _monitor.Totals;
        AddRatePoint(DateTime.Now, totals.RxRateBps, totals.TxRateBps);
        RenderHeaderAndChart();
    }

    private void AddRatePoint(DateTime time, double rx, double tx)
    {
        _ratePoints.Add((time, rx, tx));
        if (_ratePoints.Count > MaximumRatePoints)
        {
            _ratePoints.RemoveRange(0, _ratePoints.Count - MaximumRatePoints);
        }
    }

    private void OnSampled(object? sender, TrafficSample sample)
    {
        if (_paused)
        {
            return;
        }

        var flows = sample.Flows.Select(pair => new SliceFlow(
            sample.ProcessNames.GetValueOrDefault(pair.Key.ProcessId) ?? pair.Key.ProcessId.ToString(CultureInfo.InvariantCulture),
            pair.Key.Protocol == Native.TraceProtocol.Udp ? "udp" : "tcp",
            pair.Key.LocalAddress.ToString(),
            pair.Key.LocalPort,
            pair.Key.RemoteAddress.ToString(),
            pair.Key.RemotePort,
            pair.Value.Received,
            pair.Value.Sent));

        _slice.Ingest(flows, sample.Elapsed);
        ScheduleLookups();
        Render();
    }

    private void DemoTick() => DemoTick(DateTime.Now);

    private void DemoTick(DateTime time)
    {
        if (_paused || _demo is null)
        {
            return;
        }

        var flows = _demo.Next(TimeSpan.FromSeconds(1));
        _slice.Ingest(flows, TimeSpan.FromSeconds(1));
        AddRatePoint(time, flows.Sum(f => (double)f.Received), flows.Sum(f => (double)f.Sent));
        Render();
    }

    /// <summary>Reverse names for every visible host, countries for the public ones — once each per session.</summary>
    private void ScheduleLookups()
    {
        foreach (var host in _slice.VisibleHosts())
        {
            if (!_slice.HasHostname(host) && _lookupsInFlight.Add("dns|" + host))
            {
                _ = LookupName(host);
            }

            // api.country.is sees every address asked about: only with the user's consent.
            if (_store.Settings.AllowIpLookups && !_slice.IsPrivate(host) && !_slice.HasCountry(host) && _lookupsInFlight.Add("geo|" + host))
            {
                _ = LookupCountry(host);
            }
        }
    }

    private async Task LookupName(string host)
    {
        var name = await NetworkSlice.ReverseLookupAsync(host);
        _lookupsInFlight.Remove("dns|" + host);
        _slice.SetHostname(host, name);
        if (name is not null && IsLoaded)
        {
            Render();
        }
    }

    private async Task LookupCountry(string host)
    {
        var code = await NetworkSlice.CountryAsync(Http, host);
        _lookupsInFlight.Remove("geo|" + host);
        _slice.SetCountry(host, code);
        if (code is not null && IsLoaded)
        {
            Render();
        }
    }

    // ===================================== Layout =====================================

    private FrameworkElement Header()
    {
        var title = Ui.Label(Localization.L("Network Slice"), 26, Ui.Text, FontWeights.Bold);
        var subtitle = Ui.Label(Localization.L("Who your PC is talking to right now."), 13, Ui.Secondary).Margin(0, 6, 0, 0);

        FrameworkElement Rate(string glyph, string brush, TextBlock rate, TextBlock session)
            => Ui.Row(Ui.Icon(glyph, 13, brush).Margin(0, 0, 8, 0), Ui.Column(rate, session));

        _pause.VerticalAlignment = VerticalAlignment.Center;
        var right = Ui.Row(
            Rate(Glyph.Down, Ui.Download, _rxRate, _rxSession),
            Rate(Glyph.Up, Ui.Upload, _txRate, _txSession).Margin(20, 0, 0, 0),
            _pause.Margin(20, 0, 0, 0));
        right.VerticalAlignment = VerticalAlignment.Center;

        var grid = Ui.Columns(Ui.Star, Ui.Auto);
        grid.Margin = new Thickness(24, 18, 24, 18);
        grid.Children.Add(Ui.Column(title, subtitle).At(0));
        grid.Children.Add(right.At(1));
        return grid;
    }

    private Border RateCard()
    {
        Border Dot(string brush) => new() { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Margin = new Thickness(0, 0, 5, 0) };

        var downDot = Dot(Ui.Download);
        downDot.SetResourceReference(Border.BackgroundProperty, Ui.Download);
        var upDot = Dot(Ui.Upload);
        upDot.SetResourceReference(Border.BackgroundProperty, Ui.Upload);
        var legend = Ui.Row(
            downDot, Ui.Label(Localization.L("Download"), 11, Ui.Secondary, FontWeights.Medium),
            upDot.Margin(14, 0, 5, 0), Ui.Label(Localization.L("Upload"), 11, Ui.Secondary, FontWeights.Medium));

        var head = Ui.Columns(Ui.Star, Ui.Auto);
        head.Children.Add(SectionTitle("Traffic Rate", Glyph.Pulse).At(0));
        head.Children.Add(legend.At(1));

        var plot = new Grid { Height = 180, Margin = new Thickness(0, 14, 0, 0) };
        plot.Children.Add(_chart);
        plot.Children.Add(_chartPlaceholder);

        Loaded += (_, _) => _chart.SetInk(
            ((SolidColorBrush)FindResource(Ui.Download)).Color,
            ((SolidColorBrush)FindResource(Ui.Upload)).Color,
            (Brush)FindResource(Ui.Secondary),
            (Brush)FindResource("PopoverDividerBrush"));

        return Card(Ui.Column(head, plot), new Thickness(22));
    }

    private Border HelperBanner()
    {
        var icon = Ui.Icon(Glyph.Shield, 16, Ui.Orange).Margin(0, 0, 12, 0);
        var text = Ui.Column(Ui.Label(Localization.L("Needs the NetFluss helper"), 14, Ui.Text, FontWeights.SemiBold), _helperText);
        var grid = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto);
        grid.Children.Add(icon.At(0));
        grid.Children.Add(text.At(1));
        _helperButton.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(_helperButton.Margin(12, 0, 0, 0).At(2));

        var banner = Card(grid, new Thickness(16, 12, 16, 12));
        banner.Margin = new Thickness(0, 0, 0, 18);
        banner.Visibility = Visibility.Collapsed;
        return banner;
    }

    internal static Border Card(UIElement child, Thickness padding)
    {
        var card = new Border { CornerRadius = new CornerRadius(16), Padding = padding, Child = child };
        card.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        return card;
    }

    internal static FrameworkElement SectionTitle(string title, string glyph)
    {
        var label = Ui.Label(Localization.L(title).ToUpper(Localization.Culture), 12, Ui.Secondary, FontWeights.SemiBold);
        return Ui.Row(Ui.Icon(glyph, 11, Ui.Secondary).Margin(0, 0, 6, 0), label);
    }

    /// <summary>The trace cannot run, so the columns will stay empty until the helper is sorted out.</summary>
    private bool IsBlocked => _demo is null && _lease is not null &&
        _traffic.Availability is TrafficAvailability.NeedsHelper or TrafficAvailability.HelperOutdated or TrafficAvailability.HelperFailed;

    private void UpdateHelperBanner()
    {
        var availability = _traffic.Availability;
        _helperBanner.Visibility = IsBlocked ? Visibility.Visible : Visibility.Collapsed;
        foreach (var column in _columns)
        {
            column.Render();
        }

        var helperNewer = _traffic.HelperIsNewer;
        _helperText.Text = availability switch
        {
            TrafficAvailability.HelperOutdated when helperNewer => Localization.L("This NetFluss is older than its helper. Update NetFluss, or reinstall the helper from this version, to see who this PC is talking to."),
            TrafficAvailability.HelperOutdated => Localization.L("The NetFluss helper is out of date. Update it to see who this PC is talking to."),
            TrafficAvailability.HelperFailed => Localization.L("The NetFluss helper is running, but Windows refused it access to network activity. Reinstalling the helper usually fixes this."),
            _ => Localization.L("Windows only lets administrators watch connections by app and host. The optional NetFluss helper does it for you; installing it asks for approval once."),
        };

        _helperButton.Content = _installing
            ? Localization.L("Installing…")
            : availability switch
            {
                TrafficAvailability.HelperOutdated when helperNewer => Localization.L("Reinstall helper…"),
                TrafficAvailability.HelperOutdated => Localization.L("Update helper…"),
                TrafficAvailability.HelperFailed => Localization.L("Reinstall helper…"),
                _ => Localization.L("Install helper…"),
            };
        _helperButton.IsEnabled = !_installing;
    }

    private async void InstallHelper()
    {
        if (_installing)
        {
            return;
        }

        _installing = true;
        UpdateHelperBanner();
        var error = await HelperSetup.InstallAsync();
        _installing = false;
        if (error is not null)
        {
            UpdateHelperBanner();
            _helperText.Text = error;
            return;
        }

        await _helper.ProbeAsync(TimeSpan.FromSeconds(10));
        UpdateHelperBanner();
    }

    // ===================================== Rendering =====================================

    private void Render()
    {
        RenderHeaderAndChart();
        foreach (var column in _columns)
        {
            column.Render();
        }

        if (_detail is not null)
        {
            RenderDetail();
        }
    }

    private void RenderHeaderAndChart()
    {
        var latest = _ratePoints.Count > 0 ? _ratePoints[^1] : default;
        _rxRate.Text = RateFormatter.FormatRate(latest.Rx, UseBits);
        _txRate.Text = RateFormatter.FormatRate(latest.Tx, UseBits);
        _rxSession.Text = Bytes(_slice.SessionReceived);
        _txSession.Text = Bytes(_slice.SessionSent);

        var glyph = Ui.Icon(_paused ? Glyph.Play : Glyph.Pause, 11).Margin(0, 0, 6, 0);
        _pause.Content = Ui.Row(glyph, Ui.Label(Localization.L(_paused ? "Resume" : "Pause"), 12, Ui.Text, FontWeights.SemiBold));

        var enough = _ratePoints.Count >= 2;
        _chartPlaceholder.Visibility = enough ? Visibility.Collapsed : Visibility.Visible;
        _chart.SetData(enough ? [.. _ratePoints] : [], UseBits);
    }

    internal static string Bytes(ulong bytes) => RateFormatter.FormatBytes(bytes, Localization.Culture);

    // ===================================== Detail =====================================

    private void OpenDetail(SliceKind kind, SliceEntry entry)
    {
        _detail = (kind, entry);
        _detailRenderedFor = -1;
        RenderDetail();
        _detailLayer.Visibility = Visibility.Visible;

        // Slides in from the trailing edge, as the Mac's .move(edge: .trailing) transition does.
        var slide = new TranslateTransform(ActualWidth, 0);
        _detailLayer.RenderTransform = slide;
        slide.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(ActualWidth > 0 ? ActualWidth : 600, 0, TimeSpan.FromMilliseconds(220))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        });
    }

    private void CloseDetail()
    {
        _detail = null;
        _detailLayer.Visibility = Visibility.Collapsed;
        _detailLayer.Children.Clear();
    }

    private void RenderDetail()
    {
        if (_detail is not { } selection)
        {
            return;
        }

        // The live entry, so the name, flag and totals keep updating while the table is open.
        var entry = _slice.Find(selection.Kind, selection.Entry.Id) ?? selection.Entry;
        var rows = _slice.Connections(selection.Kind, selection.Entry.Id);

        // Rebuilding the table drops a scroll position; rebuild only when something changed.
        var signature = HashCode.Combine(entry.Label, entry.CountryCode, rows.Count, rows.Sum(r => (double)r.Total));
        if (signature == _detailRenderedFor)
        {
            return;
        }

        _detailRenderedFor = signature;
        var scroller = _detailLayer.Children.OfType<DockPanel>().FirstOrDefault()?.Children.OfType<ScrollViewer>().FirstOrDefault();
        var offset = scroller?.VerticalOffset ?? 0;

        _detailLayer.Children.Clear();
        var page = new DockPanel();
        var header = DetailHeader(selection.Kind, entry, rows);
        DockPanel.SetDock(header, Dock.Top);
        page.Children.Add(header);
        var divider = Ui.Divider();
        DockPanel.SetDock(divider, Dock.Top);
        page.Children.Add(divider);

        if (rows.Count == 0)
        {
            var waiting = Ui.Label(Localization.L("Gathering data…"), 13, Ui.Secondary);
            waiting.HorizontalAlignment = HorizontalAlignment.Center;
            page.Children.Add(waiting);
        }
        else
        {
            var table = new StackPanel { Margin = new Thickness(24, 12, 24, 12) };
            table.Children.Add(DetailRow(selection.Kind, null, 0));
            for (var i = 0; i < Math.Min(rows.Count, MaximumDetailRows); i++)
            {
                table.Children.Add(DetailRow(selection.Kind, rows[i], i));
            }

            var newScroller = new ScrollViewer { Content = table, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            page.Children.Add(newScroller);
            newScroller.Loaded += (_, _) => newScroller.ScrollToVerticalOffset(offset);
        }

        _detailLayer.Children.Add(page);
    }

    private FrameworkElement DetailHeader(SliceKind kind, SliceEntry entry, IReadOnlyList<SliceConnection> rows)
    {
        // Totals from the table itself, correct whichever mode the row was clicked in.
        var rx = rows.Aggregate(0UL, (sum, r) => sum + r.Received);
        var tx = rows.Aggregate(0UL, (sum, r) => sum + r.Sent);

        var back = Ui.TextButton(string.Empty, CloseDetail, accent: false);
        back.Content = Ui.Icon(Glyph.Back, 13);
        back.ToolTip = Localization.L("Back");
        back.VerticalAlignment = VerticalAlignment.Center;

        var icon = kind switch
        {
            SliceKind.Host => HostIcon(entry, large: true),
            SliceKind.Service => Ui.Icon(Glyph.Tag, 20, Ui.Secondary),
            _ => Ui.Icon(Glyph.Apps, 20, Ui.Secondary),
        };
        icon.Margin = new Thickness(14, 0, 14, 0);
        icon.VerticalAlignment = VerticalAlignment.Center;

        var caption = new List<string>();
        if (entry.Detail is { } detail)
        {
            caption.Add(detail);
        }

        caption.Add(Localization.L("{0} connections", rows.Count));
        var text = Ui.Column(
            Ui.Label(entry.Label, 20, Ui.Text, FontWeights.Bold),
            Ui.Label(string.Join("   ", caption), 12, Ui.Secondary).Margin(0, 2, 0, 0));

        var totals = Ui.Row(
            Ui.Icon(Glyph.Down, 12, Ui.Download).Margin(0, 0, 6, 0),
            Ui.Number(Bytes(rx), 14, Ui.Text, FontWeights.SemiBold),
            Ui.Icon(Glyph.Up, 12, Ui.Upload).Margin(18, 0, 6, 0),
            Ui.Number(Bytes(tx), 14, Ui.Text, FontWeights.SemiBold));
        totals.VerticalAlignment = VerticalAlignment.Center;

        var grid = Ui.Columns(Ui.Auto, Ui.Auto, Ui.Star, Ui.Auto);
        grid.Margin = new Thickness(24, 14, 24, 14);
        grid.Children.Add(back.At(0));
        grid.Children.Add(icon.At(1));
        grid.Children.Add(text.At(2));
        grid.Children.Add(totals.At(3));
        return grid;
    }

    /// <summary>One connection row, or the header row when <paramref name="row"/> is null.</summary>
    private FrameworkElement DetailRow(SliceKind kind, SliceConnection? row, int index)
    {
        var widths = new List<GridLength> { Ui.Star };
        if (kind == SliceKind.Service)
        {
            widths.Add(Ui.Fixed(140));
        }

        widths.AddRange([Ui.Fixed(84), Ui.Fixed(94), Ui.Fixed(68)]);
        if (kind != SliceKind.Service)
        {
            widths.Add(Ui.Fixed(110));
        }

        widths.AddRange([Ui.Fixed(84), Ui.Fixed(84)]);
        var grid = Ui.Columns([.. widths.SelectMany(w => new[] { w, Ui.Fixed(10) }).SkipLast(1)]);

        var column = 0;
        void Cell(string text, string brush = Ui.Text, bool right = false, bool header = false)
        {
            var label = header
                ? Ui.Label(Localization.L(text).ToUpper(Localization.Culture), 10, Ui.Secondary, FontWeights.SemiBold)
                : Ui.Number(text, 12, brush);
            if (right)
            {
                label.HorizontalAlignment = HorizontalAlignment.Right;
            }

            grid.Children.Add(label.At(column));
            column += 2;
        }

        static string Port(int? port) => port?.ToString(CultureInfo.InvariantCulture) ?? "–";

        if (row is null)
        {
            Cell(kind == SliceKind.Host ? "App" : "Host", header: true);
            if (kind == SliceKind.Service)
            {
                Cell("App", header: true);
            }

            Cell("Local Port", right: true, header: true);
            Cell("Remote Port", right: true, header: true);
            Cell("Protocol", header: true);
            if (kind != SliceKind.Service)
            {
                Cell("Service", header: true);
            }

            Cell("Download", right: true, header: true);
            Cell("Upload", right: true, header: true);
        }
        else
        {
            Cell(kind == SliceKind.Host ? row.Process : _slice.Hostname(row.Host) ?? row.Host);
            if (kind == SliceKind.Service)
            {
                Cell(row.Process);
            }

            Cell(Port(row.LocalPort), right: true);
            Cell(Port(row.RemotePort), right: true);
            Cell(row.Protocol, Ui.Secondary);
            if (kind != SliceKind.Service)
            {
                Cell(row.ServiceKey is { } key ? NetworkSlice.ServiceDisplayName(key) : "–", Ui.Secondary);
            }

            Cell(Bytes(row.Received), Ui.Download, right: true);
            Cell(Bytes(row.Sent), Ui.Upload, right: true);
            grid.ToolTip = $"{row.LocalAddress}:{Port(row.LocalPort)} → {row.Host}:{Port(row.RemotePort)}";
        }

        var border = new Border { Padding = new Thickness(8, 5, 8, 5), Child = grid, CornerRadius = new CornerRadius(4) };
        if (row is not null && index % 2 == 1)
        {
            border.SetResourceReference(Border.BackgroundProperty, "PopoverHoverBrush");
        }

        return border;
    }

    /// <summary>
    /// House for the LAN, the country code for a located host, a globe otherwise. Windows
    /// fonts draw flag emoji as two letters, so the code goes in a badge instead of a flag.
    /// </summary>
    internal static FrameworkElement HostIcon(SliceEntry entry, bool large = false)
    {
        if (entry.IsPrivateHost)
        {
            return Ui.Icon(Glyph.Home, large ? 20 : 10, Ui.Secondary);
        }

        if (entry.CountryCode is { } code)
        {
            var badge = Ui.Badge(Ui.Label(code, large ? 13 : 9, Ui.Text, FontWeights.SemiBold));
            badge.Padding = large ? new Thickness(8, 3, 8, 3) : new Thickness(3, 0, 3, 0);
            badge.ToolTip = CountryName(code);
            return badge;
        }

        return Ui.Icon(Glyph.Globe, large ? 20 : 10, Ui.Secondary);
    }

    /// <summary>A country code's display name for the badge tooltip, falling back to the code.</summary>
    private static string CountryName(string code) => NetFluss.Native.CountryNames.Display(code, Localization.UiCulture);

    // ===================================== Columns =====================================

    /// <summary>One of the three columns, its rows pooled so hover survives each tick.</summary>
    private sealed class SliceColumn
    {
        private readonly NetworkSliceWindow _owner;
        private readonly SliceKind _kind;
        private readonly Func<AppSettings, bool> _getLive;
        private readonly Action<AppSettings, bool> _setLive;
        private readonly string _emptyLive;
        private readonly StackPanel _rows = new();
        private readonly TextBlock _empty = Ui.Label(string.Empty, 12, Ui.Secondary);
        private readonly Button _liveButton;
        private readonly Button _totalButton;
        private readonly List<Row> _pool = [];

        internal SliceColumn(NetworkSliceWindow owner, SliceKind kind, string title, string glyph, Func<AppSettings, bool> getLive, Action<AppSettings, bool> setLive, string emptyLive)
        {
            _owner = owner;
            _kind = kind;
            _getLive = getLive;
            _setLive = setLive;
            _emptyLive = emptyLive;

            _liveButton = ModeButton(Glyph.Bolt, true, "Live view — traffic from the last few seconds.");
            _totalButton = ModeButton("Σ", false, "Accumulated view — total traffic since this window was opened.");
            _totalButton.FontFamily = Ui.UiFont;
            _totalButton.FontWeight = FontWeights.SemiBold;
            var toggle = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(2), Child = Ui.Row(Chip(_liveButton), Chip(_totalButton)) };
            toggle.SetResourceReference(Border.BackgroundProperty, "PopoverTrackBrush");

            var head = Ui.Columns(Ui.Star, Ui.Auto);
            head.Children.Add(SectionTitle(title, glyph).At(0));
            head.Children.Add(toggle.At(1));

            _empty.Margin = new Thickness(0, 10, 0, 10);
            _rows.Margin = new Thickness(0, 14, 0, 0);
            var body = Ui.Column(head, _rows, _empty);
            View = Card(body, new Thickness(18));
            View.VerticalAlignment = VerticalAlignment.Stretch;
        }

        internal Border View { get; }

        private bool Live
        {
            get => _getLive(_owner._store.Settings);
            set => _setLive(_owner._store.Settings, value);
        }

        private Button ModeButton(string glyph, bool live, string help)
        {
            var button = Ui.IconButton(glyph, Localization.L(help), () => Live = live, 10);
            button.Width = 26;
            button.Height = 18;
            return button;
        }

        /// <summary>The capsule behind a mode button; the icon button template draws no background of its own.</summary>
        private static Border Chip(Button button) => new() { CornerRadius = new CornerRadius(9), Child = button };

        internal void Render()
        {
            var live = Live;
            foreach (var (button, isLive) in new[] { (_liveButton, true), (_totalButton, false) })
            {
                var active = live == isLive;
                button.SetResourceReference(ForegroundProperty, active ? Ui.Accent : Ui.Secondary);
                var chip = (Border)button.Parent;
                if (active)
                {
                    chip.SetResourceReference(Border.BackgroundProperty, "PopoverAccentSoftBrush");
                }
                else
                {
                    chip.Background = Brushes.Transparent;
                }
            }

            var entries = _owner._slice.Entries(_kind, live);
            _empty.Text = Localization.L(
                _owner.IsBlocked ? "Waiting for the NetFluss helper." :
                live ? _emptyLive :
                _owner._slice.HasSample ? "No traffic captured yet." : "Gathering data…");
            _empty.Visibility = entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

            while (_pool.Count < entries.Count)
            {
                var row = new Row(this);
                _pool.Add(row);
                _rows.Children.Add(row.View);
            }

            var max = Math.Max(entries.Count == 0 ? 1 : entries.Max(e => e.Total), 1);
            for (var i = 0; i < _pool.Count; i++)
            {
                if (i < entries.Count)
                {
                    _pool[i].Update(entries[i], max, live);
                    _pool[i].View.Visibility = Visibility.Visible;
                }
                else
                {
                    _pool[i].View.Visibility = Visibility.Collapsed;
                }
            }
        }

        private sealed class Row
        {
            private readonly SliceColumn _column;
            private readonly ContentControl _icon = new() { Width = 22, Focusable = false, IsTabStop = false };
            private readonly TextBlock _label = Ui.Label(string.Empty, 12.5, Ui.Text, FontWeights.Medium);
            private readonly TextBlock _amount = Ui.Number(string.Empty, 11.5, Ui.Secondary);
            private readonly Grid _track = new() { Height = 4, Margin = new Thickness(0, 4, 0, 0) };
            private readonly Border _rx = new();
            private readonly Border _tx = new();
            private SliceEntry? _entry;
            private string? _iconKey;
            private double _fraction;
            private double _rxShare;

            internal Row(SliceColumn column)
            {
                _column = column;

                var background = new Border { CornerRadius = new CornerRadius(2) };
                background.SetResourceReference(Border.BackgroundProperty, "PopoverTrackBrush");
                _rx.SetResourceReference(Border.BackgroundProperty, Ui.Download);
                _tx.SetResourceReference(Border.BackgroundProperty, Ui.Upload);
                var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left };
                bar.Children.Add(_rx);
                bar.Children.Add(_tx);
                var clip = new Border { CornerRadius = new CornerRadius(2), Child = bar, HorizontalAlignment = HorizontalAlignment.Left, ClipToBounds = true };
                _track.Children.Add(background);
                _track.Children.Add(clip);
                _track.SizeChanged += (_, _) => Layout();

                var top = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto, Ui.Auto);
                _icon.HorizontalContentAlignment = HorizontalAlignment.Left;
                top.Children.Add(_icon.At(0));
                top.Children.Add(_label.At(1));
                top.Children.Add(_amount.Margin(8, 0, 0, 0).At(2));
                top.Children.Add(Ui.Icon(Glyph.ChevronRight, 9, Ui.Tertiary).Margin(6, 0, 0, 0).At(3));

                var content = Ui.Column(top, _track);
                View = Ui.RowButton(content, () =>
                {
                    if (_entry is { } entry)
                    {
                        _column._owner.OpenDetail(_column._kind, entry);
                    }
                });
                View.HorizontalContentAlignment = HorizontalAlignment.Stretch;
                View.Padding = new Thickness(4, 4, 4, 4);
                View.Margin = new Thickness(-4, 0, -4, 3);
            }

            internal Button View { get; }

            internal void Update(SliceEntry entry, ulong max, bool live)
            {
                _entry = entry;
                _label.Text = entry.Label;
                View.ToolTip = entry.Detail ?? entry.Label;
                var owner = _column._owner;
                _amount.Text = live
                    ? RateFormatter.FormatRate(entry.Total / Math.Max(owner._slice.LastIntervalSeconds, 0.5), owner.UseBits)
                    : Bytes(entry.Total);

                if (_column._kind == SliceKind.Host)
                {
                    var key = entry.IsPrivateHost ? "home" : entry.CountryCode ?? "globe";
                    if (key != _iconKey)
                    {
                        _iconKey = key;
                        _icon.Content = HostIcon(entry);
                    }

                    _icon.Visibility = Visibility.Visible;
                    _track.Margin = new Thickness(22, 4, 0, 0);
                }
                else
                {
                    _icon.Visibility = Visibility.Collapsed;
                }

                _fraction = entry.Total / (double)max;
                _rxShare = entry.Total > 0 ? entry.Received / (double)entry.Total : 0;
                Layout();
            }

            private void Layout()
            {
                var width = Math.Max(_track.ActualWidth * _fraction, 3);
                _rx.Width = width * _rxShare;
                _tx.Width = width * (1 - _rxShare);
                ((Border)_track.Children[1]).Width = width;
            }
        }
    }

    // ===================================== Previews =====================================

    /// <summary>For the snapshot harness: opens the drill-down for the top row of a column.</summary>
    internal void PreviewDetail(SliceKind kind)
    {
        if (_slice.Entries(kind, live: false) is [var first, ..])
        {
            OpenDetail(kind, first);
            _detailLayer.RenderTransform = null;
        }
    }
}
