// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// The speed test — port of the macOS <c>SpeedTestView</c> and <c>SpeedTestManager</c>,
/// running the macOS app's own HTML/JS engine.
///
/// <para><b>The engine is shared; only the host is ported.</b>
/// <c>Packaging/Resources/SpeedTest/*.html</c> renders nothing at all — it measures and posts
/// results to the host, which is why the macOS app draws the readout in SwiftUI and this one
/// draws it in WPF. Sharing the measurement code is the whole point: forking it would let the
/// two platforms quietly start reporting different numbers for the same link.</para>
///
/// <para>The page talks to its host through <c>webkit.messageHandlers.speedTestBridge</c>,
/// which exists on WKWebView and not on WebView2. A four-line shim maps it onto
/// <c>chrome.webview.postMessage</c>, and that shim is the entire engine port.</para>
/// </summary>
internal sealed class SpeedTestWindow : Window
{
    /// <summary>
    /// Serves the assets over a real https origin rather than file://, which several of the
    /// APIs the providers use will not run under.
    /// </summary>
    private const string VirtualHost = "netfluss.speedtest";

    private const double InfoCardHeight = 188;

    private readonly SettingsStore _store;
    private readonly SpeedTestHistory _history;
    private readonly WebView2 _engine = new();

    // Header
    private readonly TextBlock _runtimeDescription = Ui.Wrapping(string.Empty, 13);
    private readonly StackPanel _providerButtons = new() { Orientation = Orientation.Horizontal };
    private readonly Button _run;
    private readonly Button _cancel;

    // Status card
    private readonly TextBlock _phaseTitle = Ui.Label(string.Empty, 28, Ui.Text, FontWeights.Bold);
    private readonly TextBlock _phaseDetail = Ui.Wrapping(string.Empty, 14);
    private readonly TextBlock _serverLine = Ui.Label(string.Empty, 12, Ui.Secondary, FontWeights.Medium);
    private readonly StackPanel _serverRow;
    private readonly TextBlock _timeLine = Ui.Label(string.Empty, 12, Ui.Secondary);
    private readonly TextBlock _download = Ui.Number("—", 28, Ui.Download, FontWeights.Bold);
    private readonly TextBlock _upload = Ui.Number("—", 28, Ui.Upload, FontWeights.Bold);
    private readonly TextBlock _latency = Ui.Number("—", 28, Ui.Secondary, FontWeights.Bold);
    private readonly Grid _progressTrack;
    private readonly Border _progressFill;
    private readonly TextBlock _badge = Ui.Label(string.Empty, 12, Ui.Text, FontWeights.SemiBold);
    private readonly TextBlock _shortDescription = Ui.Label(string.Empty, 11, Ui.Tertiary);

    // Lower area: the result cards, or the consent card.
    private readonly StackPanel _lower = new() { Margin = new Thickness(0, 18, 0, 0) };

    // Sheets: history, and the note editor above it.
    private readonly Grid _sheetLayer = new() { Visibility = Visibility.Collapsed };
    private readonly Grid _noteLayer = new() { Visibility = Visibility.Collapsed };

    // Run state, as on SpeedTestManager.
    private SpeedTestPhase _phase = SpeedTestPhase.Idle;
    private string _detail = "Choose a provider and run a speed test when you want.";
    private SpeedTestProvider _activeProvider;
    private bool _awaitingConsent;
    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _finishedAt;
    private double? _downloadMbps;
    private double? _uploadMbps;
    private double? _latencyMs;
    private double? _jitterMs;
    private string? _serverName;
    private string? _serverLocation;
    private SpeedTestResult? _result;
    private string? _error;
    private int _runId;
    private bool _ready;
    private string? _engineProblem;

    internal SpeedTestWindow(SettingsStore store, SpeedTestHistory history, SurfacePalette surface, ThemeColor download, ThemeColor upload)
    {
        _store = store;
        _history = history;
        _activeProvider = SelectedProvider;

        Title = Localization.L("Speed Test");
        Width = 1040;
        Height = 760;
        MinWidth = 860;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Ui.UiFont;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/NetFluss;component/PopoverResources.xaml") });
        ThemeBrushes.Apply(Resources, surface, download, upload);
        SetResourceReference(BackgroundProperty, "PopoverBackgroundBrush");
        SourceInitialized += (_, _) => ThemeBrushes.ApplyFrame(this, surface.IsDark);

        _run = Ui.TextButton(string.Empty, () => Start(SelectedProvider, bypassConsent: false), accent: true);
        _cancel = Ui.TextButton(Localization.L("Cancel"), Cancel, accent: false);
        (_progressTrack, _progressFill) = Ui.Bar(Ui.Download);
        _serverRow = Ui.Row(Ui.Icon(Glyph.Globe, 12, Ui.Secondary).Margin(0, 0, 6, 0), _serverLine);

        var page = new DockPanel();
        var header = Header();
        DockPanel.SetDock(header, Dock.Top);
        page.Children.Add(header);
        var divider = Ui.Divider();
        DockPanel.SetDock(divider, Dock.Top);
        page.Children.Add(divider);
        page.Children.Add(new ScrollViewer
        {
            Content = Ui.Column(StatusCard(), _lower).Margin(24, 24, 24, 24),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });

        // Zero-sized and never shown. This is a measurement engine, not a page.
        _engine.Width = 0;
        _engine.Height = 0;
        _engine.Visibility = Visibility.Collapsed;

        var root = new Grid();
        root.Children.Add(page);
        root.Children.Add(_engine);
        root.Children.Add(_sheetLayer);
        root.Children.Add(_noteLayer);
        Content = root;

        PreviewKeyDown += OnKey;
        Loaded += async (_, _) => await InitialiseAsync();
        Render();
    }

    private SpeedTestProvider SelectedProvider => SpeedTestProviders.FromId(_store.Settings.SpeedTestProvider);

    /// <summary>
    /// The provider the window describes: the run's once one has started, the picker's
    /// before — the Mac's <c>displayedProvider</c>.
    /// </summary>
    private SpeedTestProvider DisplayedProvider =>
        _startedAt is not null || _phase != SpeedTestPhase.Idle || _result is not null || _error is not null || _awaitingConsent
            ? _activeProvider
            : SelectedProvider;

    // ===================================== Layout =====================================

    private FrameworkElement Header()
    {
        var title = Ui.Label(Localization.L("Speed Test"), 26, Ui.Text, FontWeights.Bold);
        _runtimeDescription.MaxWidth = 420;
        _runtimeDescription.HorizontalAlignment = HorizontalAlignment.Left;
        _runtimeDescription.Margin = new Thickness(0, 6, 0, 0);

        foreach (var provider in new[] { SpeedTestProvider.MLab, SpeedTestProvider.Cloudflare })
        {
            var label = provider == SpeedTestProvider.MLab ? Localization.L("M-Lab (Recommended)") : provider.DisplayName();
            var button = new Button { Content = label, Tag = provider, Padding = new Thickness(12, 5, 12, 5) };
            button.SetResourceReference(StyleProperty, "NfRowButton");
            button.Click += (_, _) =>
            {
                _store.Settings.SpeedTestProvider = provider.Id();
                if (!_phase.IsRunning())
                {
                    // Choosing a provider while a result is showing starts a fresh page
                    // for that provider, as the Mac's picker does through displayedProvider.
                    Render();
                }
            };
            _providerButtons.Children.Add(button);
        }

        var segmented = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(3), Child = _providerButtons };
        segmented.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        var picker = Ui.Column(Ui.Label(Localization.L("Provider"), 12, Ui.Secondary, FontWeights.SemiBold).Margin(2, 0, 0, 6), segmented);
        picker.VerticalAlignment = VerticalAlignment.Top;

        foreach (var button in new[] { _run, _cancel })
        {
            button.Width = 120;
        }

        var history = Ui.TextButton(Localization.L("History"), ShowHistory, accent: false);
        history.Width = 120;
        var actions = Ui.Column(_run, _cancel, history.Margin(0, 8, 0, 0));
        actions.Margin = new Thickness(12, 0, 0, 0);

        var grid = Ui.Columns(Ui.Star, Ui.Auto, Ui.Auto);
        grid.Margin = new Thickness(24, 18, 24, 18);
        grid.Children.Add(Ui.Column(title, _runtimeDescription).At(0));
        grid.Children.Add(picker.At(1));
        grid.Children.Add(actions.At(2));
        return grid;
    }

    private FrameworkElement StatusCard()
    {
        var right = Ui.Column(_serverRow, _timeLine.Margin(0, 6, 0, 0));
        right.HorizontalAlignment = HorizontalAlignment.Right;
        _timeLine.HorizontalAlignment = HorizontalAlignment.Right;
        _serverRow.HorizontalAlignment = HorizontalAlignment.Right;

        var top = Ui.Columns(Ui.Star, Ui.Auto);
        top.Children.Add(Ui.Column(_phaseTitle, _phaseDetail.Margin(0, 4, 0, 0)).At(0));
        top.Children.Add(right.At(1));

        var tiles = Ui.Columns(Ui.Star, Ui.Fixed(14), Ui.Star, Ui.Fixed(14), Ui.Star);
        tiles.Margin = new Thickness(0, 18, 0, 0);
        tiles.Children.Add(Tile("Download", _download).At(0));
        tiles.Children.Add(Tile("Upload", _upload).At(2));
        tiles.Children.Add(Tile("Latency", _latency).At(4));

        _progressTrack.Height = 6;
        ((Border)_progressTrack.Children[0]).CornerRadius = new CornerRadius(3);
        _progressFill.CornerRadius = new CornerRadius(3);
        _progressTrack.SizeChanged += (_, _) => UpdateProgress();

        var badge = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 5, 10, 5), Child = _badge };
        badge.SetResourceReference(Border.BackgroundProperty, "PopoverTrackBrush");
        var footer = Ui.Columns(Ui.Auto, Ui.Star);
        footer.Margin = new Thickness(0, 8, 0, 0);
        footer.Children.Add(badge.At(0));
        _shortDescription.HorizontalAlignment = HorizontalAlignment.Right;
        _shortDescription.Margin = new Thickness(12, 0, 0, 0);
        footer.Children.Add(_shortDescription.At(1));

        var body = Ui.Column(top, tiles, _progressTrack.Margin(0, 18, 0, 0), footer);

        // The Mac's card washes from the download ink into the upload ink at 10 %.
        var card = new Border { CornerRadius = new CornerRadius(20), Padding = new Thickness(22), Child = body, BorderThickness = new Thickness(1) };
        card.SetResourceReference(Border.BorderBrushProperty, "PopoverDividerBrush");
        card.Background = Wash();
        return card;
    }

    private Brush Wash()
    {
        Color Soft(string key)
        {
            var color = ((SolidColorBrush)FindResource(key)).Color;
            return Color.FromArgb(0x1A, color.R, color.G, color.B);
        }

        var brush = new LinearGradientBrush(Soft(Ui.Download), Soft(Ui.Upload), new Point(0, 0), new Point(1, 1));
        brush.Freeze();
        return brush;
    }

    private static Border Tile(string title, TextBlock value)
    {
        var caption = Ui.Label(Localization.L(title).ToUpper(Localization.Culture), 11, Ui.Secondary, FontWeights.SemiBold);
        var tile = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(16),
            Child = Ui.Column(caption, new Viewbox
            {
                Child = value,
                Stretch = Stretch.Uniform,
                StretchDirection = StretchDirection.DownOnly,
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 10, 0, 0),
            }),
        };
        tile.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        return tile;
    }

    private static Border InfoCard(string title, string glyph, string tint, FrameworkElement content, bool fixedHeight = true)
    {
        var heading = Ui.Row(Ui.Icon(glyph, 14, tint).Margin(0, 0, 8, 0), Ui.Label(Localization.L(title), 15, Ui.Text, FontWeights.SemiBold));
        var card = new Border
        {
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(18),
            BorderThickness = new Thickness(1),
            Child = Ui.Column(heading, content.Margin(0, 14, 0, 0)),
        };
        if (fixedHeight)
        {
            card.Height = InfoCardHeight;
        }

        card.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "PopoverDividerBrush");
        return card;
    }

    private static T Spaced<T>(T element, double top)
        where T : FrameworkElement
        => element.Margin(0, top, 0, 0);

    private static FrameworkElement DetailRow(string label, string value)
    {
        var grid = Ui.Columns(Ui.Fixed(110), Ui.Star);
        grid.Margin = new Thickness(0, 0, 0, 10);
        grid.Children.Add(Ui.Label(Localization.L(label), 13, Ui.Secondary, FontWeights.SemiBold).At(0));
        var text = Ui.Label(value, 13, Ui.Text);
        text.ToolTip = value;
        grid.Children.Add(text.At(1));
        return grid;
    }

    private static Grid Pair(UIElement left, UIElement right)
    {
        var grid = Ui.Columns(Ui.Star, Ui.Fixed(18), Ui.Star);
        grid.Children.Add(left.At(0));
        grid.Children.Add(right.At(2));
        return grid;
    }

    // ===================================== Rendering =====================================

    /// <summary>Redraws everything from the run state; cheap enough to do on every message.</summary>
    private void Render()
    {
        var running = _phase.IsRunning();
        var provider = DisplayedProvider;

        _runtimeDescription.Text = Localization.L(provider.RuntimeDescriptionKey());
        foreach (var button in _providerButtons.Children.OfType<Button>())
        {
            var selected = (SpeedTestProvider)button.Tag == SelectedProvider;
            button.SetResourceReference(BackgroundProperty, selected ? "PopoverAccentSoftBrush" : "PopoverCardBrush");
            button.SetResourceReference(ForegroundProperty, selected ? Ui.Accent : Ui.Text);
            button.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
            button.IsEnabled = !running;
        }

        _run.Content = Localization.L(_result is not null || _finishedAt is not null || _error is not null ? "Run Again" : "Run Test");
        _run.Visibility = running ? Visibility.Collapsed : Visibility.Visible;
        _run.IsEnabled = _ready;
        _cancel.Visibility = running ? Visibility.Visible : Visibility.Collapsed;

        _phaseTitle.Text = Localization.L(_phase.Title());
        _phaseDetail.Text = Localization.L(_detail);

        var server = ServerLine();
        _serverLine.Text = server ?? string.Empty;
        _serverRow.Visibility = server is null ? Visibility.Collapsed : Visibility.Visible;
        _timeLine.Text = _finishedAt is { } finished
            ? Localization.L("Finished {0}", Timestamp(finished))
            : _startedAt is { } started
                ? Localization.L("Started {0}", Timestamp(started))
                : string.Empty;

        _download.Text = RateFormatter.FormatMbps(_result?.DownloadMbps ?? _downloadMbps);
        _upload.Text = RateFormatter.FormatMbps(_result?.UploadMbps ?? _uploadMbps);
        _latency.Text = Latency(_result?.LatencyMs ?? _latencyMs);

        _progressFill.SetResourceReference(Border.BackgroundProperty, _phase switch
        {
            SpeedTestPhase.Completed => Ui.Green,
            SpeedTestPhase.Failed => Ui.Red,
            SpeedTestPhase.Cancelled => Ui.Secondary,
            SpeedTestPhase.TestingUpload => Ui.Upload,
            _ => Ui.Download,
        });
        UpdateProgress();

        _badge.Text = provider.DisplayName();
        _shortDescription.Text = Localization.L(provider.ShortDescriptionKey());

        RenderLower(provider, server);
    }

    private void UpdateProgress()
    {
        var fraction = _phase.Progress();
        _progressFill.Width = _progressTrack.ActualWidth * fraction;
        _progressFill.Visibility = fraction > 0 ? Visibility.Visible : Visibility.Hidden;
    }

    private void RenderLower(SpeedTestProvider provider, string? server)
    {
        _lower.Children.Clear();

        if (_awaitingConsent)
        {
            var text = Ui.Wrapping(Localization.L("M-Lab publishes measurement data publicly, including your public IP address. NetFluss needs your consent before running the first M-Lab speed test."), 14);
            var accept = Ui.TextButton(Localization.L("Continue with M-Lab"), AcceptConsent, accent: true);
            var policy = Ui.LinkButton(Localization.L("Review M-Lab privacy policy"), () => UpdateNotifier.Open(new Uri("https://www.measurementlab.net/privacy/")));
            var buttons = Ui.Row(accept, policy.Margin(14, 0, 0, 0));
            buttons.Margin = new Thickness(0, 14, 0, 0);
            _lower.Children.Add(InfoCard("M-Lab Consent", Glyph.Shield, Ui.Orange, Ui.Column(text, buttons), fixedHeight: false));
            return;
        }

        var details = Ui.Column(
            DetailRow("Provider", provider.DisplayName()),
            DetailRow("Server", server ?? Localization.L("Waiting for a server selection")),
            DetailRow("Started", _startedAt is { } s ? Timestamp(s) : Localization.L("Not started")),
            DetailRow("Finished", _finishedAt is { } f ? Timestamp(f) : Localization.L("In progress")));

        var notes = Ui.Column(
            Ui.Wrapping(Localization.L(provider.RuntimeDescriptionKey()), 13),
            Spaced(Ui.Wrapping(Localization.L(provider == SpeedTestProvider.MLab
                ? "M-Lab keeps results public, so NetFluss stores your consent once before the first test."
                : "Cloudflare measures against nearby Cloudflare edge locations, so results can differ from broader Internet-path tests."), 12), 10));

        _lower.Children.Add(Pair(
            InfoCard("Connection Details", Glyph.Network, Ui.Accent, details),
            InfoCard("Notes", Glyph.Info, Ui.Orange, notes)));

        if (_error is not null)
        {
            var retry = Ui.TextButton(Localization.L("Try Again"), () => Start(SelectedProvider, bypassConsent: false), accent: true);
            retry.HorizontalAlignment = HorizontalAlignment.Left;
            var error = InfoCard("Error", Glyph.Warning, Ui.Red, Ui.Column(Ui.Wrapping(_error, 13), retry.Margin(0, 10, 0, 0)), fixedHeight: false);
            _lower.Children.Add(Spaced(error, 18));
        }
        else if (_result is { } result)
        {
            var final = Ui.Column(
                DetailRow("Download", RateFormatter.FormatMbps(result.DownloadMbps)),
                DetailRow("Upload", RateFormatter.FormatMbps(result.UploadMbps)),
                DetailRow("Latency", Latency(result.LatencyMs)),
                DetailRow("Jitter", Latency(result.JitterMs)));

            var remember = Ui.Column(Ui.Wrapping(Localization.L("Add a short note so you can remember exactly where you took this measurement later."), 13));
            if (CurrentNote(result) is { } note)
            {
                var noteText = Ui.Wrapping(note, 13, Ui.Text);
                noteText.MaxHeight = 54;
                remember.Children.Add(Spaced(noteText, 10));
            }

            var edit = Ui.TextButton(Localization.L(CurrentNote(result) is null ? "Add Note" : "Edit Note"), () => EditNote(result), accent: false);
            edit.HorizontalAlignment = HorizontalAlignment.Left;
            remember.Children.Add(Spaced(edit, 10));

            _lower.Children.Add(Spaced(Pair(
                InfoCard("Final Result", Glyph.Speed, _phase == SpeedTestPhase.Completed ? Ui.Green : Ui.Download, final),
                InfoCard("Remember This Test", Glyph.Edit, Ui.Green, remember)), 18));
        }
    }

    private string? ServerLine()
    {
        var name = _result?.ServerName ?? _serverName;

        // Translated on display, not when stored: the Cloudflare page reports a fixed English
        // label, while real M-Lab locations have no key and pass through unchanged.
        var location = (_result?.ServerLocation ?? _serverLocation) is { } raw ? Localization.L(raw) : null;
        return (string.IsNullOrEmpty(name), string.IsNullOrEmpty(location)) switch
        {
            (false, false) => $"{name} • {location}",
            (false, true) => name,
            (true, false) => location,
            _ => null,
        };
    }

    private string? CurrentNote(SpeedTestResult result)
        => _history.Results.FirstOrDefault(r => r.Id == result.Id)?.Note ?? result.Note;

    private static string Latency(double? milliseconds) => milliseconds switch
    {
        null => "—",
        < 10 => string.Format(CultureInfo.InvariantCulture, "{0:F1} ms", milliseconds),
        _ => string.Format(CultureInfo.InvariantCulture, "{0:F0} ms", milliseconds),
    };

    /// <summary>The Mac's medium date with short time, in the app's language.</summary>
    private static string Timestamp(DateTimeOffset date)
    {
        var local = date.LocalDateTime;
        var culture = Localization.Culture;
        return local.ToString("d MMM yyyy", culture) + ", " + local.ToString("t", culture);
    }

    private static string CompactTimestamp(DateTimeOffset date)
    {
        var local = date.LocalDateTime;
        var culture = Localization.Culture;
        return local.ToString("d", culture) + ", " + local.ToString("t", culture);
    }

    // ===================================== Engine =====================================

    private async Task InitialiseAsync()
    {
        try
        {
            // Its own user-data folder under LOCALAPPDATA: the default sits beside the exe,
            // which fails outright when the app is installed to Program Files.
            //
            // The engine is never shown, so Chromium treats its page as hidden and throttles its
            // timers: setTimeout runs about once a second, and after five minutes once a minute.
            // The M-Lab upload is driven by a setTimeout pump, so it sent a message a second and
            // measured about 1 Mbit/s whatever the link; the download and the Cloudflare test
            // are event-driven and were not affected. A measurement page must run at full speed.
            var environment = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "NetFluss",
                    "WebView2"),
                options: new CoreWebView2EnvironmentOptions
                {
                    AdditionalBrowserArguments = string.Join(' ',
                        "--disable-background-timer-throttling",
                        "--disable-renderer-backgrounding",
                        "--disable-backgrounding-occluded-windows",
                        "--disable-features=IntensiveWakeUpThrottling"),
                });

            await _engine.EnsureCoreWebView2Async(environment);

            var core = _engine.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;

            var assets = Path.Combine(AppContext.BaseDirectory, "SpeedTest");
            core.SetVirtualHostNameToFolderMapping(VirtualHost, assets, CoreWebView2HostResourceAccessKind.Allow);

            // The shim, and the whole of the port: the page asks for a WKWebView message
            // handler, so give it one that forwards to WebView2.
            await core.AddScriptToExecuteOnDocumentCreatedAsync(
                """
                window.webkit = window.webkit || {};
                window.webkit.messageHandlers = window.webkit.messageHandlers || {};
                window.webkit.messageHandlers.speedTestBridge = {
                    postMessage: function (message) { window.chrome.webview.postMessage(message); }
                };
                """);

            core.WebMessageReceived += OnWebMessage;
            _ready = true;
        }
        catch (Exception e) when (e is WebView2RuntimeNotFoundException or DllNotFoundException)
        {
            // The Evergreen runtime is present on Windows 11 and usually on 10, but not
            // always. Say so plainly rather than leaving a dead Run button.
            _engineProblem = Localization.L("The speed test needs Microsoft Edge WebView2, which is not installed. Everything else in NetFluss works without it.");
        }
        catch (Exception e)
        {
            _engineProblem = Localization.L("The speed test engine could not start: {0}", e.Message);
        }

        if (_engineProblem is not null)
        {
            _phase = SpeedTestPhase.Failed;
            _detail = _engineProblem;
            _error = _engineProblem;
        }

        Render();
    }

    private void Start(SpeedTestProvider provider, bool bypassConsent)
    {
        if (!_ready || _engine.CoreWebView2 is not { } core)
        {
            return;
        }

        _activeProvider = provider;
        _error = null;
        _result = null;
        _downloadMbps = _uploadMbps = _latencyMs = _jitterMs = null;
        _serverName = _serverLocation = null;
        _startedAt = _finishedAt = null;

        if (provider == SpeedTestProvider.MLab && !bypassConsent && !_store.Settings.SpeedTestMLabConsent)
        {
            _awaitingConsent = true;
            _phase = SpeedTestPhase.ConsentRequired;
            _detail = "M-Lab publishes measurement data publicly, so NetFluss asks for consent before the first test.";
            Render();
            return;
        }

        _awaitingConsent = false;
        _phase = SpeedTestPhase.Preparing;
        _detail = provider == SpeedTestProvider.MLab ? "Preparing the M-Lab test..." : "Preparing the Cloudflare test...";
        _startedAt = DateTimeOffset.Now;
        var runId = ++_runId;
        Render();

        void OnNavigated(object? sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            core.NavigationCompleted -= OnNavigated;
            if (runId != _runId)
            {
                return;
            }

            if (!e.IsSuccess)
            {
                Fail(Localization.L("Could not load the speed test page: {0}", e.WebErrorStatus.ToString()));
                return;
            }

            var payload = JsonSerializer.Serialize(new
            {
                runId,
                provider = provider.Id(),
                clientName = "NetFluss",
                clientVersion = UpdateNotifier.CurrentVersion,
            });

            _ = Launch(core, payload, provider);
        }

        core.NavigationCompleted += OnNavigated;
        core.Navigate($"https://{VirtualHost}/{(provider == SpeedTestProvider.MLab ? "mlab.html" : "cloudflare.html")}");
    }

    private async Task Launch(CoreWebView2 core, string payload, SpeedTestProvider provider)
    {
        try
        {
            await core.ExecuteScriptAsync($"window.NetFlussSpeedTest.start({payload}); true;");
        }
        catch (Exception e)
        {
            Fail(Localization.L("Could not start the {0} speed test: {1}", provider.DisplayName(), e.Message));
        }
    }

    private void AcceptConsent()
    {
        _store.Settings.SpeedTestMLabConsent = true;
        Start(SpeedTestProvider.MLab, bypassConsent: true);
    }

    private void Cancel()
    {
        var wasRunning = _phase.IsRunning() || _awaitingConsent;
        _runId++;
        LoadBlankPage();
        _awaitingConsent = false;
        if (wasRunning)
        {
            _phase = SpeedTestPhase.Cancelled;
            _detail = "Speed test stopped.";
            _finishedAt = DateTimeOffset.Now;
        }

        Render();
    }

    private void LoadBlankPage()
    {
        // Stops whatever the page was measuring; a hidden engine left running would keep
        // saturating the link after the window says the test is over.
        try
        {
            _engine.CoreWebView2?.Navigate("about:blank");
        }
        catch (InvalidOperationException)
        {
            // Already torn down.
        }
    }

    /// <summary>
    /// Handles one message from the engine. The shapes are the macOS app's, unchanged —
    /// phase, progress, result, error — each tagged with the run it belongs to.
    /// </summary>
    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonElement message;
        try
        {
            message = JsonSerializer.Deserialize<JsonElement>(e.WebMessageAsJson);
        }
        catch (JsonException)
        {
            return;
        }

        if (message.ValueKind != JsonValueKind.Object ||
            Number(message, "runId") is not { } runId ||
            (int)runId != _runId)
        {
            return;
        }

        switch (Text(message, "type"))
        {
            case "phase":
                UpdateServer(message);
                ApplyPhase(Text(message, "phase"), Text(message, "detail"));
                break;

            case "progress":
                UpdateServer(message);
                UpdateMetrics(message);
                ApplyPhase(Text(message, "phase"), Text(message, "detail"));
                break;

            case "result":
                HandleResult(message);
                return;

            case "error":
                Fail(Text(message, "message") ?? "The speed test failed.");
                return;

            default:
                return;
        }

        Render();
    }

    private void UpdateServer(JsonElement payload)
    {
        if (Text(payload, "serverName") is { Length: > 0 } name)
        {
            _serverName = name;
        }

        if (Text(payload, "serverLocation") is { Length: > 0 } location)
        {
            _serverLocation = location;
        }
    }

    private void UpdateMetrics(JsonElement payload)
    {
        _downloadMbps = Number(payload, "downloadMbps") ?? _downloadMbps;
        _uploadMbps = Number(payload, "uploadMbps") ?? _uploadMbps;
        _latencyMs = Number(payload, "latencyMs") ?? _latencyMs;
        _jitterMs = Number(payload, "jitterMs") ?? _jitterMs;
    }

    private void ApplyPhase(string? phase, string? detail)
    {
        _phase = phase switch
        {
            "discoveringServer" => SpeedTestPhase.DiscoveringServer,
            "latency" => SpeedTestPhase.TestingLatency,
            "download" => SpeedTestPhase.TestingDownload,
            "upload" => SpeedTestPhase.TestingUpload,
            "finalizing" => SpeedTestPhase.Finalizing,
            _ => _phase,
        };

        if (!string.IsNullOrEmpty(detail))
        {
            _detail = detail;
        }
    }

    private void HandleResult(JsonElement payload)
    {
        UpdateServer(payload);
        UpdateMetrics(payload);

        var provider = Text(payload, "provider") is { } id ? SpeedTestProviders.FromId(id) : _activeProvider;
        var finished = DateTimeOffset.Now;
        _finishedAt = finished;
        _phase = SpeedTestPhase.Completed;
        _detail = Localization.L("{0} speed test complete.", provider.DisplayName());
        _error = null;

        _result = new SpeedTestResult
        {
            Provider = provider,
            StartedAt = _startedAt ?? finished,
            FinishedAt = finished,
            DownloadMbps = _downloadMbps,
            UploadMbps = _uploadMbps,
            LatencyMs = _latencyMs,
            JitterMs = _jitterMs,
            ServerName = _serverName,
            ServerLocation = _serverLocation,
        };
        _history.Add(_result);

        _runId++;
        LoadBlankPage();
        Render();
    }

    private void Fail(string message)
    {
        // Translated at the source: covers this file's own literals and the bundled pages'
        // English messages; text that is already translated passes through as is.
        var localized = Localization.L(message);
        _finishedAt = DateTimeOffset.Now;
        _phase = SpeedTestPhase.Failed;
        _detail = localized;
        _error = localized;
        _awaitingConsent = false;
        _runId++;
        LoadBlankPage();
        Render();
    }

    private static string? Text(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static double? Number(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble()
            : null;

    // ===================================== Sheets =====================================

    private void ShowHistory()
    {
        var title = Ui.Label(Localization.L("Speed Test History"), 22, Ui.Text, FontWeights.Bold);
        var subtitle = Ui.Wrapping(Localization.L("Recent results saved on this PC. Add notes to remember the exact place."), 13).Margin(0, 4, 0, 0);
        var done = Ui.TextButton(Localization.L("Done"), CloseHistory, accent: true);
        done.VerticalAlignment = VerticalAlignment.Top;

        var head = Ui.Columns(Ui.Star, Ui.Auto);
        head.Margin = new Thickness(24, 18, 24, 18);
        head.Children.Add(Ui.Column(title, subtitle).At(0));
        head.Children.Add(done.At(1));

        var body = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        body.Children.Add(head);
        var divider = Ui.Divider();
        DockPanel.SetDock(divider, Dock.Top);
        body.Children.Add(divider);

        if (_history.Results.Count == 0)
        {
            var empty = Ui.Column(
                Ui.Icon(Glyph.Speed, 28, Ui.Secondary),
                Ui.Label(Localization.L("No speed tests yet"), 18, Ui.Text, FontWeights.SemiBold).Margin(0, 12, 0, 0),
                Ui.Wrapping(Localization.L("Run a speed test when you want and NetFluss will keep the recent results here."), 13).Margin(0, 8, 0, 0));
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            empty.VerticalAlignment = VerticalAlignment.Center;
            foreach (var child in empty.Children.OfType<FrameworkElement>())
            {
                child.HorizontalAlignment = HorizontalAlignment.Center;
            }

            body.Children.Add(empty);
        }
        else
        {
            var columns = HistoryColumns();
            columns.Margin = new Thickness(24, 12, 24, 12);
            string[] headings = ["When", "Provider", "Download", "Upload", "Latency", "Note"];
            for (var i = 0; i < headings.Length; i++)
            {
                var label = Ui.Label(Localization.L(headings[i]), 12, Ui.Secondary, FontWeights.SemiBold);
                if (i is >= 2 and <= 4)
                {
                    label.HorizontalAlignment = HorizontalAlignment.Right;
                }

                columns.Children.Add(label.At(i * 2));
            }

            DockPanel.SetDock(columns, Dock.Top);
            body.Children.Add(columns);
            var rule = Ui.Divider();
            DockPanel.SetDock(rule, Dock.Top);
            body.Children.Add(rule);

            var rows = new StackPanel();
            foreach (var result in _history.Results)
            {
                rows.Children.Add(HistoryRow(result));
                rows.Children.Add(Ui.Divider());
            }

            body.Children.Add(new ScrollViewer
            {
                Content = rows,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            });
        }

        ShowSheet(_sheetLayer, body, 980, 420);
    }

    private static Grid HistoryColumns()
        => Ui.Columns(Ui.Fixed(150), Ui.Fixed(12), Ui.Fixed(96), Ui.Fixed(12), Ui.Fixed(110), Ui.Fixed(12), Ui.Fixed(110), Ui.Fixed(12), Ui.Fixed(78), Ui.Fixed(12), Ui.Star);

    private FrameworkElement HistoryRow(SpeedTestResult result)
    {
        var grid = HistoryColumns();
        grid.Margin = new Thickness(24, 8, 24, 8);

        var mono = new FontFamily("Cascadia Mono, Consolas");
        TextBlock Cell(string text, bool right)
        {
            var cell = Ui.Number(text, 13);
            cell.FontFamily = mono;
            if (right)
            {
                cell.HorizontalAlignment = HorizontalAlignment.Right;
            }

            return cell;
        }

        grid.Children.Add(Cell(CompactTimestamp(result.FinishedAt), false).At(0));
        grid.Children.Add(Ui.Label(result.Provider.DisplayName(), 13).At(2));
        grid.Children.Add(Cell(RateFormatter.FormatMbps(result.DownloadMbps), true).At(4));
        grid.Children.Add(Cell(RateFormatter.FormatMbps(result.UploadMbps), true).At(6));
        grid.Children.Add(Cell(Latency(result.LatencyMs), true).At(8));

        var note = result.Note;
        var noteText = Ui.Label(note ?? Localization.L("Add note"), 13, note is null ? Ui.Secondary : Ui.Text);
        noteText.ToolTip = note;
        var edit = Ui.RowButton(Ui.Row(Ui.Icon(Glyph.Edit, 12, Ui.Secondary).Margin(0, 0, 8, 0), noteText), () => EditNote(result));
        edit.HorizontalContentAlignment = HorizontalAlignment.Left;
        grid.Children.Add(edit.At(10));
        return grid;
    }

    private void CloseHistory()
    {
        _sheetLayer.Visibility = Visibility.Collapsed;
        _sheetLayer.Children.Clear();
    }

    private void EditNote(SpeedTestResult result)
    {
        var box = new TextBox { Text = CurrentNote(result) ?? string.Empty, MinHeight = 30, VerticalContentAlignment = VerticalAlignment.Center };
        box.SetResourceReference(StyleProperty, "NfInput");
        box.SetResourceReference(TextBox.CaretBrushProperty, Ui.Text);
        box.FontSize = 13;

        var placeholder = Ui.Label(Localization.L("Cafe X, back room, hotel Wi-Fi, coworking desk 4…"), 13, Ui.Tertiary);
        placeholder.IsHitTestVisible = false;
        placeholder.Margin = new Thickness(9, 0, 0, 0);
        void UpdatePlaceholder() => placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) => UpdatePlaceholder();
        UpdatePlaceholder();
        var field = new Grid();
        field.Children.Add(box);
        field.Children.Add(placeholder);

        void Save(string? note)
        {
            _history.SetNote(result.Id, note);
            if (_result?.Id == result.Id)
            {
                _result = _result with { Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim() };
            }

            CloseNote();
            Render();
            if (_sheetLayer.Visibility == Visibility.Visible)
            {
                ShowHistory();
            }
        }

        var clear = Ui.TextButton(Localization.L("Clear"), () => Save(null), accent: false);
        clear.IsEnabled = box.Text.Trim().Length > 0;
        box.TextChanged += (_, _) => clear.IsEnabled = box.Text.Trim().Length > 0;
        var cancel = Ui.TextButton(Localization.L("Cancel"), CloseNote, accent: false);
        var save = Ui.TextButton(Localization.L("Save"), () => Save(box.Text), accent: true);
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                Save(box.Text);
            }
        };

        var buttons = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto, Ui.Auto);
        buttons.Margin = new Thickness(0, 16, 0, 0);
        buttons.Children.Add(clear.At(0));
        buttons.Children.Add(cancel.At(2));
        buttons.Children.Add(save.Margin(10, 0, 0, 0).At(3));

        var heading = Ui.Label(Localization.L("Speed Test Note"), 20, Ui.Text, FontWeights.Bold);
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        var context = Ui.Label($"{result.Provider.DisplayName()} • {CompactTimestamp(result.FinishedAt)}", 12, Ui.Secondary);
        context.HorizontalAlignment = HorizontalAlignment.Center;

        var body = Ui.Column(heading, context.Margin(0, 8, 0, 16), field, buttons);
        body.Margin = new Thickness(24);
        ShowSheet(_noteLayer, body, 420, double.NaN);
        box.Loaded += (_, _) =>
        {
            box.Focus();
            box.CaretIndex = box.Text.Length;
        };
    }

    private void CloseNote()
    {
        _noteLayer.Visibility = Visibility.Collapsed;
        _noteLayer.Children.Clear();
    }

    /// <summary>A sheet over a dimmed window, the Windows reading of a macOS sheet.</summary>
    private static void ShowSheet(Grid layer, UIElement content, double width, double height)
    {
        layer.Children.Clear();
        layer.Background = new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0));

        var card = new Border
        {
            Width = width,
            Height = height,
            MaxWidth = double.PositiveInfinity,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(24),
            Child = content,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, Opacity = 0.35, ShadowDepth = 4 },
        };
        card.SetResourceReference(Border.BackgroundProperty, "PopoverBackgroundBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "PopoverDividerBrush");
        layer.Children.Add(card);
        layer.Visibility = Visibility.Visible;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape)
        {
            return;
        }

        if (_noteLayer.Visibility == Visibility.Visible)
        {
            CloseNote();
            e.Handled = true;
        }
        else if (_sheetLayer.Visibility == Visibility.Visible)
        {
            CloseHistory();
            e.Handled = true;
        }
    }

    // ===================================== Previews =====================================

    /// <summary>
    /// Puts the window into a representative state for the off-screen snapshot harness:
    /// "result", "running", "consent", "error", "history" or "note". Never used in normal runs.
    /// </summary>
    internal void Preview(string state)
    {
        var finished = DateTimeOffset.Now.AddMinutes(-3);
        var sample = new SpeedTestResult
        {
            Provider = SpeedTestProvider.MLab,
            StartedAt = finished.AddSeconds(-22),
            FinishedAt = finished,
            DownloadMbps = 912.4,
            UploadMbps = 48.7,
            LatencyMs = 8.4,
            JitterMs = 1.9,
            ServerName = "mlab1-fra07",
            ServerLocation = "Frankfurt, DE",
            Note = state == "note" ? "Office, desk by the window" : null,
        };

        _activeProvider = SpeedTestProvider.MLab;
        _startedAt = sample.StartedAt;
        _serverName = sample.ServerName;
        _serverLocation = sample.ServerLocation;

        switch (state)
        {
            case "running":
                _phase = SpeedTestPhase.TestingDownload;
                _detail = "Measuring download throughput...";
                _downloadMbps = 734;
                _latencyMs = 8.4;
                break;
            case "consent":
                _startedAt = null;
                _serverName = _serverLocation = null;
                _awaitingConsent = true;
                _phase = SpeedTestPhase.ConsentRequired;
                _detail = "M-Lab publishes measurement data publicly, so NetFluss asks for consent before the first test.";
                break;
            case "error":
                _finishedAt = finished;
                _phase = SpeedTestPhase.Failed;
                _error = _detail = Localization.L("The speed test failed.");
                break;
            default:
                _result = sample;
                _finishedAt = finished;
                _phase = SpeedTestPhase.Completed;
                _detail = Localization.L("{0} speed test complete.", "M-Lab");
                if (_history.Results.Count == 0)
                {
                    for (var i = 4; i >= 1; i--)
                    {
                        _history.Add(sample with { Id = Guid.NewGuid(), FinishedAt = finished.AddDays(-i).AddHours(i), DownloadMbps = 880 + (i * 9), Provider = i % 2 == 0 ? SpeedTestProvider.Cloudflare : SpeedTestProvider.MLab, Note = i == 2 ? "Hotel Wi-Fi, room 412" : null });
                    }

                    _history.Add(sample);
                }

                break;
        }

        Render();
        if (state == "history")
        {
            ShowHistory();
        }
        else if (state == "note")
        {
            EditNote(sample);
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        // The engine keeps a browser process alive; leaving one per open would accumulate.
        _runId++;
        _engine.Dispose();
        base.OnClosed(e);
    }
}

/// <summary>Where a run is — the macOS <c>SpeedTestPhase</c>.</summary>
internal enum SpeedTestPhase
{
    Idle,
    ConsentRequired,
    Preparing,
    DiscoveringServer,
    TestingLatency,
    TestingDownload,
    TestingUpload,
    Finalizing,
    Completed,
    Cancelled,
    Failed,
}

internal static class SpeedTestPhases
{
    internal static bool IsRunning(this SpeedTestPhase phase)
        => phase is SpeedTestPhase.Preparing or SpeedTestPhase.DiscoveringServer or SpeedTestPhase.TestingLatency
            or SpeedTestPhase.TestingDownload or SpeedTestPhase.TestingUpload or SpeedTestPhase.Finalizing;

    /// <summary>Localization keys, as on macOS.</summary>
    internal static string Title(this SpeedTestPhase phase) => phase switch
    {
        SpeedTestPhase.Idle => "Ready",
        SpeedTestPhase.ConsentRequired => "Consent required",
        SpeedTestPhase.Preparing => "Preparing",
        SpeedTestPhase.DiscoveringServer => "Finding server",
        SpeedTestPhase.TestingLatency => "Measuring latency",
        SpeedTestPhase.TestingDownload => "Testing download",
        SpeedTestPhase.TestingUpload => "Testing upload",
        SpeedTestPhase.Finalizing => "Finalizing",
        SpeedTestPhase.Completed => "Complete",
        SpeedTestPhase.Cancelled => "Cancelled",
        _ => "Failed",
    };

    internal static double Progress(this SpeedTestPhase phase) => phase switch
    {
        SpeedTestPhase.Preparing => 0.08,
        SpeedTestPhase.DiscoveringServer => 0.20,
        SpeedTestPhase.TestingLatency => 0.34,
        SpeedTestPhase.TestingDownload => 0.62,
        SpeedTestPhase.TestingUpload => 0.86,
        SpeedTestPhase.Finalizing => 0.96,
        SpeedTestPhase.Completed => 1,
        _ => 0,
    };
}
