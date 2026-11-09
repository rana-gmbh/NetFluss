// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// Bandwidth Statistics — port of the macOS <c>StatisticsView</c>: preset and custom ranges,
/// download and upload timelines with totals, peak and average, the busiest adapters, and
/// the top ten apps each way.
/// </summary>
internal sealed class StatisticsWindow : Window
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(30);

    private readonly StatisticsService _statistics;
    private readonly SettingsStore _store;
    private readonly Action _openPreferences;
    private readonly DispatcherTimer _refresh;
    private readonly StackPanel _rangeButtons = new() { Orientation = Orientation.Horizontal };
    private readonly Button _customButton;
    private readonly TextBlock _customLabel;
    private readonly Popup _customPopup;
    private readonly DatePicker _from = new();
    private readonly DatePicker _to = new();
    private readonly TextBlock _subtitle;
    private readonly StackPanel _content = new() { Margin = new Thickness(24, 18, 24, 24) };
    private readonly Button? _demoButton;

    private StatisticsRange _range = StatisticsRange.Last24Hours;

    /// <summary>The range to open on; the Mac opens on 24H.</summary>
    internal StatisticsRange InitialRange
    {
        set => _range = value;
    }
    private (DateTime Start, DateTime End)? _custom;
    private int _generation;

    internal StatisticsWindow(StatisticsService statistics, SettingsStore store, SurfacePalette surface, ThemeColor download, ThemeColor upload, Action openPreferences)
    {
        _statistics = statistics;
        _store = store;
        _openPreferences = openPreferences;

        Title = Localization.L("Bandwidth Statistics");
        Width = 1000;
        Height = 760;
        MinWidth = 820;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Ui.UiFont;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/NetFluss;component/PopoverResources.xaml") });
        ThemeBrushes.Apply(Resources, surface, download, upload);
        SetResourceReference(BackgroundProperty, "PopoverBackgroundBrush");
        SourceInitialized += (_, _) => ThemeBrushes.ApplyFrame(this, surface.IsDark);

        var title = Ui.Label(Localization.L("Statistics"), 26, Ui.Text, FontWeights.Bold);
        _subtitle = Ui.Wrapping(string.Empty, 13);
        _subtitle.Margin = new Thickness(0, 4, 0, 0);
        _subtitle.MaxWidth = 520;
        _subtitle.HorizontalAlignment = HorizontalAlignment.Left;

        foreach (var range in Enum.GetValues<StatisticsRange>())
        {
            var button = new Button { Content = range.Code(), Tag = range, MinWidth = 52, Padding = new Thickness(10, 5, 10, 5) };
            button.SetResourceReference(StyleProperty, "NfRowButton");
            button.Click += (_, _) =>
            {
                _range = range;
                _custom = null;
                Load();
            };

            _rangeButtons.Children.Add(button);
        }

        var segmented = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(3),
            Child = _rangeButtons,
        };
        segmented.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");

        _customLabel = Ui.Label(Localization.L("Custom date range"), 13, Ui.Text);
        var calendar = Ui.Icon("", 13).Margin(0, 0, 8, 0);
        _customButton = new Button
        {
            Content = Ui.Row(calendar, _customLabel),
            Padding = new Thickness(12, 6, 12, 6),
            Margin = new Thickness(0, 8, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
        };
        _customButton.SetResourceReference(StyleProperty, "NfRowButton");
        _customButton.SetResourceReference(Control.BackgroundProperty, "PopoverCardBrush");
        _customButton.Click += (_, _) => OpenCustomRange();

        _customPopup = new Popup
        {
            PlacementTarget = _customButton,
            Placement = PlacementMode.Bottom,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = CustomRangeCard(),
        };

        var refresh = Ui.IconButton(Glyph.Refresh, Localization.L("Refresh"), Load, 13);
        refresh.Margin = new Thickness(0, 0, 8, 0);

        var controls = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        if (StatisticsService.DemoAvailable)
        {
            _demoButton = Ui.TextButton(string.Empty, ToggleDemo, accent: false);
            _demoButton.Margin = new Thickness(0, 0, 12, 0);
            _demoButton.VerticalAlignment = VerticalAlignment.Top;
            controls.Children.Add(_demoButton);
        }

        controls.Children.Add(refresh);
        controls.Children.Add(Ui.Column(segmented, _customButton, _customPopup));

        var header = Ui.Columns(Ui.Star, Ui.Auto);
        header.Margin = new Thickness(24, 18, 24, 16);
        header.Children.Add(Ui.Column(title, _subtitle).At(0));
        header.Children.Add(controls.At(1));

        var scroller = new ScrollViewer
        {
            Content = _content,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        var divider = Ui.Divider();
        DockPanel.SetDock(divider, Dock.Top);
        root.Children.Add(divider);
        root.Children.Add(scroller);
        Content = root;

        _refresh = new DispatcherTimer { Interval = RefreshInterval };
        _refresh.Tick += (_, _) => Load();
        Loaded += (_, _) =>
        {
            Load();
            _refresh.Start();
        };
        Closed += (_, _) => _refresh.Stop();
    }

    private void ToggleDemo()
    {
        _statistics.SetDemo(!_statistics.IsShowingDemo);
        Load();
    }

    private async void Load()
    {
        var generation = ++_generation;
        UpdateControls();

        var report = _custom is { } custom
            ? await _statistics.ReportAsync(custom.Start, custom.End)
            : await _statistics.ReportAsync(_range);

        // A slower, older load must not overwrite a newer one the user asked for since.
        if (generation != _generation)
        {
            return;
        }

        Render(report);
    }

    private void UpdateControls()
    {
        foreach (var button in _rangeButtons.Children.OfType<Button>())
        {
            var selected = _custom is null && (StatisticsRange)button.Tag == _range;
            button.SetResourceReference(Control.BackgroundProperty, selected ? "PopoverAccentSoftBrush" : "PopoverCardBrush");
            button.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
            button.SetResourceReference(Control.ForegroundProperty, selected ? Ui.Accent : Ui.Text);
        }

        _customLabel.Text = _custom is { } custom
            ? string.Create(Localization.Culture, $"{custom.Start:d} – {custom.End:d}")
            : Localization.L("Custom date range");
        _customButton.SetResourceReference(Control.BackgroundProperty, _custom is null ? "PopoverCardBrush" : "PopoverAccentSoftBrush");

        if (_demoButton is not null)
        {
            _demoButton.Content = Localization.L(_statistics.IsShowingDemo ? "Live Data" : "Load Sample Data");
        }

        var settings = _store.Settings;
        _subtitle.Text = _statistics.IsShowingDemo
            ? Localization.L("Previewing generated sample statistics for the last year. Live collection continues with your current preferences.")
            : !settings.CollectStatistics
                ? Localization.L("Statistics collection is disabled in Preferences.")
                : settings.CollectAppStatistics
                    ? Localization.L("Adapter statistics are collected continuously while NetFluss runs. App statistics come from Windows' own data usage records.")
                    : Localization.L("Adapter statistics are being collected. App statistics are currently disabled.");
    }

    private void Render(StatisticsReport report)
    {
        _content.Children.Clear();
        var settings = _store.Settings;

        if (!report.HasAdapterData && !report.HasAppData)
        {
            _content.Children.Add(EmptyState(settings.CollectStatistics));
            return;
        }

        if (_statistics.IsShowingDemo)
        {
            _content.Children.Add(Banner(
                Glyph.Star,
                Ui.Orange,
                Localization.L("Sample history loaded"),
                Localization.L("This is generated demo traffic so you can review the charts, adapter ranking, and top-app lists across all ranges."),
                action: null));
        }
        else if (settings.CollectStatistics && !settings.CollectAppStatistics)
        {
            _content.Children.Add(Banner(
                Glyph.EyeHide,
                Ui.Secondary,
                Localization.L("App statistics are disabled"),
                Localization.L("Turn them on in Preferences if you want top download and upload apps in this view."),
                action: (Localization.L("Preferences"), _openPreferences)));
        }

        _content.Children.Add(SummaryCard(report));

        var lower = Ui.Columns(Ui.Star, Ui.Fixed(18), Ui.Star);
        lower.Margin = new Thickness(0, 18, 0, 0);
        lower.Children.Add(AdaptersCard(report).At(0));

        var appsSubtitleDown = settings.CollectAppStatistics || _statistics.IsShowingDemo
            ? Localization.L("Top 10 apps by received data.")
            : Localization.L("App statistics collection is currently off.");
        var appsSubtitleUp = settings.CollectAppStatistics || _statistics.IsShowingDemo
            ? Localization.L("Top 10 apps by sent data.")
            : Localization.L("App statistics collection is currently off.");

        var apps = Ui.Column(
            AppCard(Localization.L("Top Downloads"), appsSubtitleDown, report.TopDownloadApps, Ui.Download),
            AppCard(Localization.L("Top Uploads"), appsSubtitleUp, report.TopUploadApps, Ui.Upload).Margin(0, 18, 0, 0));
        lower.Children.Add(apps.At(2));

        _content.Children.Add(lower);

        if (settings.CollectProxyNodeStatistics || report.Nodes.Count > 0)
        {
            _content.Children.Add(NodesCard(report).Margin(0, 18, 0, 0));
        }
    }

    /// <summary>
    /// Per-proxy-node usage from the Clash API (macOS 2.7). Deliberately not a top ten: it
    /// exists so a metered subscription can be reconciled, and a truncated list would not add up.
    /// </summary>
    private FrameworkElement NodesCard(StatisticsReport report)
    {
        var body = new StackPanel();
        body.Children.Add(Ui.Label(Localization.L("Proxy nodes"), 22, Ui.Text, FontWeights.Bold));
        body.Children.Add(Ui.Wrapping(Localization.L("Traffic per outbound node for the selected range, read from the proxy controller."), 13).Margin(0, 4, 0, 12));

        if (_statistics.ProxyNodeError is { } error && !_statistics.IsShowingDemo)
        {
            body.Children.Add(Ui.Row(
                Ui.Icon(Glyph.Warning, 12, Ui.Secondary).Margin(0, 0, 8, 0),
                Ui.Label(error, 12, Ui.Secondary)).Margin(0, 0, 0, 10));
        }

        if (report.Nodes.Count == 0)
        {
            body.Children.Add(Ui.Label(Localization.L("No node traffic recorded yet."), 13, Ui.Secondary));
            return Card(body);
        }

        var peak = Math.Max(1, report.Nodes.Max(n => n.TotalBytes));
        foreach (var row in report.Nodes)
        {
            var name = Ui.Label(NodeName(row.Name), 15, Ui.Text, FontWeights.SemiBold);
            var totalText = Ui.Number(Bytes(row.TotalBytes), 13, Ui.Secondary, FontWeights.SemiBold);
            var line = Ui.Columns(Ui.Star, Ui.Auto);
            line.Children.Add(name.At(0));
            line.Children.Add(totalText.At(1));

            var split = Ui.Row(
                Ui.Icon(Glyph.Down, 10, Ui.Download).Margin(0, 0, 4, 0),
                Ui.Number(Bytes(row.DownloadBytes), 12, Ui.Download),
                Ui.Icon(Glyph.Up, 10, Ui.Upload).Margin(12, 0, 4, 0),
                Ui.Number(Bytes(row.UploadBytes), 12, Ui.Upload));
            split.Margin = new Thickness(0, 4, 0, 6);

            var (track, fill) = Ui.Bar(Ui.Download);
            track.Height = 8;
            ((Border)track.Children[0]).CornerRadius = new CornerRadius(4);
            fill.CornerRadius = new CornerRadius(4);
            var fraction = row.TotalBytes / (double)peak;
            track.SizeChanged += (_, _) => fill.Width = Math.Max(8, track.ActualWidth * fraction);

            body.Children.Add(Ui.Column(line, split, track).Margin(0, 4, 0, 10));
        }

        if (report.Nodes.Any(n => n.Name == ClashNodeAccumulator.UnattributedKey))
        {
            body.Children.Add(Ui.Wrapping(
                Localization.L("Unattributed covers traffic the controller counted but could not pin to a node — mostly connections that opened and closed between two reads, plus DNS."),
                11).Margin(0, 2, 0, 0));
        }

        return Card(body);
    }

    /// <summary>The accumulator's bucket keys are storage keys, not display strings.</summary>
    private static string NodeName(string name) => name switch
    {
        ClashNodeAccumulator.UnattributedKey => Localization.L("Unattributed"),
        ClashApi.UnknownNodeKey => Localization.L("Unknown node"),
        _ => name,
    };

    private FrameworkElement SummaryCard(StatisticsReport report)
    {
        var culture = Localization.Culture;

        var caption = Ui.Label(Localization.L(report.Title).ToUpper(culture), 12, Ui.Secondary, FontWeights.SemiBold);
        var description = Ui.Label(Localization.L("Download and upload history for the selected range."), 13, Ui.Secondary, FontWeights.Medium);
        description.Margin = new Thickness(0, 6, 0, 0);

        var meta = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        meta.Children.Add(Ui.Label(Localization.L(report.BucketTitle), 13, Ui.Secondary, FontWeights.SemiBold));
        if (report.CoverageStart is { } since)
        {
            meta.Children.Add(Ui.Label(Localization.L("Collecting since {0}", since.ToString("d", culture)), 12, Ui.Secondary).Margin(0, 4, 0, 0));
        }

        if (report.LastAdapterSampleAt is { } last)
        {
            meta.Children.Add(Ui.Label(Localization.L("Last adapter update {0}", last.LocalDateTime.ToString("t", culture)), 12, Ui.Secondary).Margin(0, 2, 0, 0));
        }

        var top = Ui.Columns(Ui.Star, Ui.Auto);
        top.Children.Add(Ui.Column(caption, description).At(0));
        top.Children.Add(meta.At(1));

        var panels = Ui.Columns(Ui.Star, Ui.Fixed(37), Ui.Star);
        panels.Margin = new Thickness(0, 18, 0, 0);
        panels.Children.Add(TrafficPanel(report, download: true).At(0));
        var rule = new Border { Width = 1, HorizontalAlignment = HorizontalAlignment.Center };
        rule.SetResourceReference(Border.BackgroundProperty, "PopoverDividerBrush");
        panels.Children.Add(rule.At(1));
        panels.Children.Add(TrafficPanel(report, download: false).At(2));

        return Card(Ui.Column(top, panels));
    }

    private FrameworkElement TrafficPanel(StatisticsReport report, bool download)
    {
        var points = report.Timeline.Select(p => (p.Date, (double)(download ? p.DownloadBytes : p.UploadBytes))).ToList();
        var total = download ? report.TotalDownloadBytes : report.TotalUploadBytes;
        var peak = points.Count == 0 ? 0 : points.Max(p => p.Item2);
        var average = points.Count == 0 ? 0 : points.Average(p => p.Item2);
        var brush = download ? Ui.Download : Ui.Upload;

        var icon = Ui.Icon(download ? Glyph.Down : Glyph.Up, 14, brush).Margin(0, 0, 6, 0);
        var label = Ui.Label(Localization.L(download ? "Download" : "Upload"), 14, brush, FontWeights.SemiBold);
        var amount = Ui.Number(Bytes(total), 30, Ui.Text, FontWeights.Bold);
        amount.Margin = new Thickness(0, 6, 0, 0);

        var pills = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        pills.Children.Add(Pill(Localization.L("Peak"), Bytes((ulong)peak), brush));
        pills.Children.Add(Pill(Localization.L("Avg"), Bytes((ulong)average), brush).Margin(0, 6, 0, 0));

        var head = Ui.Columns(Ui.Star, Ui.Auto);
        head.Children.Add(Ui.Column(Ui.Row(icon, label), amount).At(0));
        head.Children.Add(pills.At(1));

        var chart = new TrafficChart { Margin = new Thickness(0, 14, 0, 0) };
        var color = ((SolidColorBrush)FindResource(brush)).Color;
        chart.SetData(points, report.Granularity, color);
        chart.SetInk(
            (Brush)FindResource(Ui.Secondary),
            (Brush)FindResource("PopoverDividerBrush"),
            (Brush)FindResource(Ui.Text),
            (Brush)FindResource("PopoverBackgroundBrush"));

        return Ui.Column(head, chart);
    }

    private FrameworkElement AdaptersCard(StatisticsReport report)
    {
        var body = new StackPanel();
        body.Children.Add(Ui.Label(Localization.L("Adapters"), 22, Ui.Text, FontWeights.Bold));
        body.Children.Add(Ui.Wrapping(Localization.L("Top adapters by transferred data for the selected range."), 13).Margin(0, 4, 0, 12));

        if (report.Adapters.Count == 0)
        {
            body.Children.Add(Ui.Label(Localization.L("No adapter history yet."), 13, Ui.Secondary));
            return Card(body);
        }

        var peak = Math.Max(1, report.Adapters.Max(a => a.TotalBytes));
        foreach (var row in report.Adapters)
        {
            var name = Ui.Label(row.Id == "other" ? Localization.L("Other") : row.Name, 15, Ui.Text, FontWeights.SemiBold);
            var totalText = Ui.Number(Bytes(row.TotalBytes), 13, Ui.Secondary, FontWeights.SemiBold);
            var line = Ui.Columns(Ui.Star, Ui.Auto);
            line.Children.Add(name.At(0));
            line.Children.Add(totalText.At(1));

            var split = Ui.Row(
                Ui.Icon(Glyph.Down, 10, Ui.Download).Margin(0, 0, 4, 0),
                Ui.Number(Bytes(row.DownloadBytes), 12, Ui.Download),
                Ui.Icon(Glyph.Up, 10, Ui.Upload).Margin(12, 0, 4, 0),
                Ui.Number(Bytes(row.UploadBytes), 12, Ui.Upload));
            split.Margin = new Thickness(0, 4, 0, 6);

            var (track, fill) = Ui.Bar(Ui.Download);
            track.Height = 8;
            ((Border)track.Children[0]).CornerRadius = new CornerRadius(4);
            fill.CornerRadius = new CornerRadius(4);
            var fraction = row.TotalBytes / (double)peak;
            track.SizeChanged += (_, _) => fill.Width = Math.Max(8, track.ActualWidth * fraction);

            body.Children.Add(Ui.Column(line, split, track).Margin(0, 4, 0, 10));
        }

        return Card(body);
    }

    private FrameworkElement AppCard(string title, string subtitle, IReadOnlyList<AppRow> rows, string brush)
    {
        var body = new StackPanel();
        body.Children.Add(Ui.Label(title, 22, Ui.Text, FontWeights.Bold));
        body.Children.Add(Ui.Wrapping(subtitle, 13).Margin(0, 4, 0, 12));

        if (rows.Count == 0)
        {
            var settings = _store.Settings;
            body.Children.Add(Ui.Wrapping(
                Localization.L(settings.CollectAppStatistics || _statistics.IsShowingDemo
                    ? "No app history yet."
                    : "Turn app statistics on in Preferences to populate this list."),
                13));
            return Card(body);
        }

        var tint = (SolidColorBrush)FindResource(brush);
        var soft = new SolidColorBrush(Color.FromArgb(0x1F, tint.Color.R, tint.Color.G, tint.Color.B));
        soft.Freeze();

        for (var i = 0; i < rows.Count; i++)
        {
            var rank = new Border
            {
                Width = 24,
                Height = 24,
                CornerRadius = new CornerRadius(12),
                Background = soft,
                Child = Ui.Label((i + 1).ToString(CultureInfo.CurrentCulture), 12, brush, FontWeights.SemiBold),
            };
            ((TextBlock)rank.Child).HorizontalAlignment = HorizontalAlignment.Center;

            var name = Ui.Label(rows[i].Name, 13, Ui.Text, FontWeights.Medium).Margin(8, 0, 8, 0);
            var amount = new Border
            {
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(10, 3, 10, 3),
                Background = soft,
                MinWidth = 82,
                Child = Ui.Number(Bytes(rows[i].Bytes), 12, Ui.Text, FontWeights.SemiBold),
            };
            ((TextBlock)amount.Child).HorizontalAlignment = HorizontalAlignment.Right;

            var line = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto);
            line.Margin = new Thickness(0, 4, 0, 4);
            line.Children.Add(rank.At(0));
            line.Children.Add(name.At(1));
            line.Children.Add(amount.At(2));
            body.Children.Add(line);
        }

        return Card(body);
    }

    private FrameworkElement EmptyState(bool collecting)
    {
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 90, 0, 0), MaxWidth = 440 };
        panel.Children.Add(Ui.Icon(collecting ? Glyph.BarChart : Glyph.Power, 34, Ui.Secondary));
        var headline = Ui.Label(Localization.L(collecting ? "Not enough statistics yet" : "Statistics collection is off"), 22, Ui.Text, FontWeights.Bold);
        headline.HorizontalAlignment = HorizontalAlignment.Center;
        headline.Margin = new Thickness(0, 14, 0, 8);
        panel.Children.Add(headline);

        var message = Ui.Wrapping(Localization.L(collecting
            ? "Keep NetFluss running for a while and this view will fill in with adapter and app history."
            : "Enable statistics in Preferences to start collecting preset and custom date range network history."), 14);
        message.TextAlignment = TextAlignment.Center;
        panel.Children.Add(message);

        if (!collecting)
        {
            var button = Ui.TextButton(Localization.L("Turn on statistics"), () =>
            {
                _store.Batch(settings => settings.CollectStatistics = true);
                Load();
            }, accent: true);
            button.HorizontalAlignment = HorizontalAlignment.Center;
            button.Margin = new Thickness(0, 18, 0, 0);
            panel.Children.Add(button);
        }

        return panel;
    }

    private FrameworkElement Banner(string glyph, string brush, string title, string text, (string Label, Action Action)? action)
    {
        var grid = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto);
        grid.Children.Add(Ui.Icon(glyph, 16, brush).Margin(0, 0, 12, 0).At(0));
        grid.Children.Add(Ui.Column(Ui.Label(title, 14, Ui.Text, FontWeights.SemiBold), Ui.Wrapping(text, 12)).At(1));
        if (action is { } a)
        {
            grid.Children.Add(Ui.LinkButton(a.Label, a.Action).At(2));
        }

        var border = new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16, 12, 16, 12),
            Margin = new Thickness(0, 0, 0, 18),
            Child = grid,
        };
        border.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        return border;
    }

    private FrameworkElement CustomRangeCard()
    {
        foreach (var picker in new[] { _from, _to })
        {
            picker.Width = 160;
            picker.SelectedDateFormat = DatePickerFormat.Short;
            picker.DisplayDateEnd = DateTime.Today;
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Ui.Auto });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition());
        grid.Children.Add(Ui.Label(Localization.L("From"), 13).At(0, 0));
        grid.Children.Add(_from.At(1, 0));
        grid.Children.Add(Ui.Label(Localization.L("To"), 13).At(0, 1));
        grid.Children.Add(_to.Margin(0, 8, 0, 0).At(1, 1));

        var cancel = Ui.TextButton(Localization.L("Cancel"), () => _customPopup.IsOpen = false, accent: false);
        var apply = Ui.TextButton(Localization.L("Apply"), ApplyCustomRange, accent: true).Margin(8, 0, 0, 0);
        var buttons = Ui.Row(cancel, apply);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 16, 0, 0);

        var body = Ui.Column(Ui.Label(Localization.L("Custom Date Range"), 15, Ui.Text, FontWeights.SemiBold).Margin(0, 0, 0, 12), grid, buttons);
        return Flyout.Frame(body, 290);
    }

    private void OpenCustomRange()
    {
        _from.SelectedDate = (_custom?.Start ?? DateTime.Today.AddDays(-7)).Date;
        _to.SelectedDate = (_custom?.End ?? DateTime.Today).Date;
        _customPopup.IsOpen = true;
    }

    /// <summary>Whole days, inclusive of the end day, never past now — the Mac's rule.</summary>
    private void ApplyCustomRange()
    {
        var a = _from.SelectedDate ?? DateTime.Today;
        var b = _to.SelectedDate ?? DateTime.Today;
        var start = (a < b ? a : b).Date;
        var endDay = (a < b ? b : a).Date;
        var end = endDay.AddDays(1).AddSeconds(-1);
        if (end > DateTime.Now)
        {
            end = DateTime.Now;
        }

        _custom = (start, end);
        _customPopup.IsOpen = false;
        Load();
    }

    private static Border Card(UIElement child)
    {
        var border = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(22), Child = child };
        border.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        return border;
    }

    private static FrameworkElement Pill(string title, string value, string brush)
    {
        var caption = Ui.Label(title.ToUpper(Localization.Culture), 10, Ui.Secondary, FontWeights.SemiBold);
        caption.HorizontalAlignment = HorizontalAlignment.Right;
        var amount = Ui.Number(value, 12, Ui.Text, FontWeights.SemiBold);
        amount.HorizontalAlignment = HorizontalAlignment.Right;

        var border = new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 5, 10, 5),
            Child = Ui.Column(caption, amount),
        };

        border.Loaded += (_, _) =>
        {
            if (border.TryFindResource(brush) is SolidColorBrush tint)
            {
                border.Background = new SolidColorBrush(Color.FromArgb(0x1F, tint.Color.R, tint.Color.G, tint.Color.B));
            }
        };

        return border;
    }

    private static string Bytes(ulong bytes) => RateFormatter.FormatBytes(bytes, Localization.Culture);
}
