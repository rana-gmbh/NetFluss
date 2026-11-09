// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using NetFluss.App.Popover;
using NetFluss.App.Settings;
using NetFluss.Core;
using NetFluss.Tray;

namespace NetFluss.App;

/// <summary>Everything a Preferences page may read or act on.</summary>
internal sealed class PreferencesContext
{
    internal required SettingsStore Store { get; init; }

    internal required NetworkMonitorService Monitor { get; init; }

    internal required HelperClient Helper { get; init; }

    internal required PrivilegedActions Privileged { get; init; }

    internal required StatisticsService Statistics { get; init; }

    internal required TrafficService Traffic { get; init; }

    internal required RouterService Routers { get; init; }

    internal required Vpn.VpnManager Vpn { get; init; }

    internal required AppCommands Commands { get; init; }

    internal required DnsSwitcher Dns { get; init; }

    internal required DnsAutoSwitcher AutoDns { get; init; }

    internal AppSettings Settings => Store.Settings;
}

/// <summary>
/// Preferences, in the shape of Windows 11 Settings: a navigation pane of the macOS panes —
/// General, Taskbar, Appearance, Adapters, Statistics, Top Apps, DNS, Wi-Fi — and on the
/// right one scrolling column of grouped cards per pane.
///
/// <para>Changes apply and persist immediately, with no OK button, which is both what
/// Settings does and what the macOS preferences window does.</para>
///
/// <para>Deliberately on the Windows light/dark palette rather than the app theme: it is
/// styled to sit beside real Windows Settings, and a Dracula Settings clone would read as a
/// rendering fault rather than a preference.</para>
/// </summary>
internal sealed class PreferencesWindow : Window
{
    private readonly PreferencesContext _context;
    private readonly ListBox _nav = new();
    private readonly ContentControl _page = new();
    private readonly TextBlock _title;
    private readonly ScrollViewer _scroller;
    private readonly TextBox _search = new();
    private readonly TextBlock _searchHint;
    private string _current = "general";

    /// <summary>Every text on every page, by page — built on the first search, dropped on a language change.</summary>
    private List<(string Text, string Key)>? _index;

    private const int MaxSearchResults = 40;

    private static readonly (string Key, string Glyph, string Label)[] Pages =
    [
        ("general", Glyph.Settings, "General"),
        ("taskbar", "", "Taskbar"),
        ("appearance", "", "Appearance"),
        ("adapters", Glyph.Ethernet, "Adapters"),
        ("statistics", Glyph.Chart, "Statistics"),
        ("topapps", "", "Top Apps"),
        ("dns", Glyph.Globe, "DNS"),
        ("wifi", Glyph.Wifi, "Wi-Fi"),
        ("vpn", Glyph.Lock, "VPN"),
        ("router", Glyph.Router, "Router"),
    ];

    internal PreferencesWindow(PreferencesContext context)
    {
        _context = context;

        Width = 980;
        Height = 780;
        MinWidth = 720;
        MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/NetFluss;component/SettingsResources.xaml") });
        ApplyPalette();
        SetResourceReference(BackgroundProperty, "PageBrush");

        _nav.BorderThickness = new Thickness(0);
        _nav.Background = Brushes.Transparent;
        _nav.Margin = new Thickness(12, 8, 8, 12);
        _nav.SetResourceReference(ItemsControl.ItemContainerStyleProperty, "SetNavItem");
        ScrollViewer.SetHorizontalScrollBarVisibility(_nav, ScrollBarVisibility.Disabled);
        _nav.SelectionChanged += (_, _) =>
        {
            if (_nav.SelectedItem is ListBoxItem { Tag: string key } && key != _current)
            {
                Show(key);
            }
        };

        _title = Kit.Text(string.Empty, 28, "TextBrush", FontWeights.SemiBold);
        _title.Margin = new Thickness(36, 20, 36, 4);

        _scroller = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(36, 4, 36, 28),
            Content = _page,
        };

        var right = new DockPanel();
        DockPanel.SetDock(_title, Dock.Top);
        right.Children.Add(_title);
        right.Children.Add(_scroller);

        // "Search settings" above the navigation, where Windows Settings has its own (macOS 2.7.2).
        _searchHint = Kit.Text(Kit.L("Search settings"), 14, "SecondaryTextBrush");
        _searchHint.IsHitTestVisible = false;
        _searchHint.Margin = new Thickness(10, 0, 0, 0);
        _search.VerticalContentAlignment = VerticalAlignment.Center;
        _search.Height = 34;
        System.Windows.Automation.AutomationProperties.SetName(_search, Kit.L("Search settings"));
        _search.TextChanged += (_, _) => Search(_search.Text);
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape && _search.Text.Length > 0)
            {
                _search.Clear();
                e.Handled = true;
            }
        };
        var searchBox = new Grid { Margin = new Thickness(24, 20, 20, 0) };
        searchBox.Children.Add(_search);
        searchBox.Children.Add(_searchHint);

        var left = new DockPanel();
        DockPanel.SetDock(searchBox, Dock.Top);
        left.Children.Add(searchBox);
        left.Children.Add(_nav);

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(right, 1);
        root.Children.Add(left);
        root.Children.Add(right);
        Content = root;

        // Ctrl+F, as in every Windows window with a search box.
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.F && System.Windows.Input.Keyboard.Modifiers == System.Windows.Input.ModifierKeys.Control)
            {
                _search.Focus();
                _search.SelectAll();
                e.Handled = true;
            }
        };

        BuildNav();
        Show(_current);

        // A language change rebuilds the whole window so it reads in the new language at
        // once — the user just chose it, and half a window in the old one looks broken.
        Kit.Watch(root, context.Settings, name =>
        {
            if (name == nameof(AppSettings.Language))
            {
                Dispatcher.BeginInvoke(() =>
                {
                    _index = null;
                    _searchHint.Text = Kit.L("Search settings");
                    _search.Clear();
                    BuildNav();
                    Show(_current);
                });
            }
        });

        SourceInitialized += (_, _) =>
        {
            ApplyMicaBackdrop();
            FitToWorkArea();
        };
    }

    /// <summary>Opens on a pane by key ("dns", "adapters", …), for deep links and the harness.</summary>
    /// <summary>For the snapshot harness: shows the end of a long page.</summary>
    internal void ScrollToEnd() => _scroller.ScrollToEnd();

    /// <summary>For the snapshot harness: shows the results for a query.</summary>
    internal void SetSearchText(string text) => _search.Text = text;

    internal void SelectTab(string key)
    {
        key = key.ToLowerInvariant();
        if (Pages.Any(p => p.Key == key))
        {
            Show(key);
        }
    }

    internal static TrayMeterLayout ToLayout(MeterStyle style) => style switch
    {
        MeterStyle.DownloadOnly => TrayMeterLayout.DownloadOnly,
        MeterStyle.UploadOnly => TrayMeterLayout.UploadOnly,
        MeterStyle.Icon => TrayMeterLayout.Icon,
        _ => TrayMeterLayout.TwoLine,
    };

    private void BuildNav()
    {
        Title = Kit.L("NetFluss Preferences");
        _nav.Items.Clear();

        var header = Kit.Text(Kit.L("Preferences"), 13, "SecondaryTextBrush", FontWeights.SemiBold);
        header.Margin = new Thickness(12, 18, 0, 10);
        _nav.Items.Add(new ListBoxItem { Content = header, IsEnabled = false, Focusable = false, Template = new ControlTemplate(typeof(ListBoxItem)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) } });

        foreach (var (key, glyph, label) in Pages)
        {
            var icon = Kit.Icon(glyph, 16);
            icon.Width = 22;
            icon.Margin = new Thickness(0, 0, 12, 0);

            _nav.Items.Add(new ListBoxItem
            {
                Tag = key,
                Content = Kit.Row(icon, Kit.Text(Kit.L(label), 14)),
                IsSelected = key == _current,
            });
        }
    }

    private void Show(string key)
    {
        _current = key;
        foreach (var item in _nav.Items.OfType<ListBoxItem>())
        {
            item.IsSelected = Equals(item.Tag, key);
        }

        var label = Pages.First(p => p.Key == key).Label;
        _title.Text = Kit.L(label);

        _page.Content = key switch
        {
            "general" => GeneralPage.Build(_context, this),
            "taskbar" => TaskbarPage.Build(_context),
            "appearance" => AppearancePage.Build(_context),
            "adapters" => AdaptersPage.Build(_context),
            "statistics" => StatisticsPage.Build(_context),
            "topapps" => TopAppsPage.Build(_context),
            "dns" => DnsPage.Build(_context),
            "wifi" => WifiPage.Build(_context),
            "vpn" => VpnPage.Build(_context),
            "router" => RouterPage.Build(_context),
            _ => null,
        };

        _scroller.ScrollToTop();
    }

    // ===================================== Search =====================================

    /// <summary>
    /// Finds a setting by what it says on screen, across every page. The pages are built in
    /// code, so instead of the hand-kept list the Mac needs, each page is built once, unshown,
    /// and its text read off — a new setting is searchable the day it is added. Building is
    /// free of side effects: pages only subscribe to anything once they are loaded.
    /// </summary>
    private void Search(string query)
    {
        _searchHint.Visibility = query.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var words = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0)
        {
            Show(_current);
            return;
        }

        _index ??= BuildIndex();
        var compare = Localization.Culture.CompareInfo;
        const System.Globalization.CompareOptions options =
            System.Globalization.CompareOptions.IgnoreCase | System.Globalization.CompareOptions.IgnoreNonSpace | System.Globalization.CompareOptions.IgnoreWidth;

        // Labels ahead of the longer explanations, as on macOS.
        var results = _index
            .Where(entry => words.All(word => compare.IndexOf(entry.Text, word, options) >= 0))
            .OrderBy(entry => entry.Text.Length)
            .Take(MaxSearchResults)
            .ToList();

        foreach (var item in _nav.Items.OfType<ListBoxItem>())
        {
            item.IsSelected = false;
        }

        _title.Text = Kit.L("Search settings");
        var list = new StackPanel();
        if (results.Count == 0)
        {
            list.Children.Add(Kit.Caption(Kit.L("No matching settings")));
        }

        foreach (var (text, key) in results)
        {
            var label = Kit.Text(text, 14);
            label.TextTrimming = TextTrimming.CharacterEllipsis;
            label.MaxHeight = 40;
            var page = Kit.Text(Kit.L(Pages.First(p => p.Key == key).Label), 12, "SecondaryTextBrush");
            page.Margin = new Thickness(16, 0, 0, 0);

            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(page, 1);
            row.Children.Add(label);
            row.Children.Add(page);

            var button = new Button { Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 0, 0, 6) };
            button.SetResourceReference(StyleProperty, "SetButton");
            System.Windows.Automation.AutomationProperties.SetName(button, text);
            button.Click += (_, _) => Reveal(key, text);
            list.Children.Add(button);
        }

        _page.Content = list;
        _scroller.ScrollToTop();
    }

    /// <summary>Opens the page and scrolls the matching text into view.</summary>
    private void Reveal(string key, string text)
    {
        // Clearing the box would show the page the search started from; show the hit's instead.
        _current = key;
        _search.Text = string.Empty;

        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () =>
        {
            if (Texts(_page.Content as DependencyObject).FirstOrDefault(t => t.Block.Text == text).Block is { } target)
            {
                target.BringIntoView();
            }
        });
    }

    private List<(string Text, string Key)> BuildIndex()
    {
        var index = new List<(string Text, string Key)>();
        var seen = new HashSet<(string, string)>();
        foreach (var (key, _, label) in Pages)
        {
            FrameworkElement? page;
            try
            {
                page = key switch
                {
                    "general" => GeneralPage.Build(_context, this),
                    "taskbar" => TaskbarPage.Build(_context),
                    "appearance" => AppearancePage.Build(_context),
                    "adapters" => AdaptersPage.Build(_context),
                    "statistics" => StatisticsPage.Build(_context),
                    "topapps" => TopAppsPage.Build(_context),
                    "dns" => DnsPage.Build(_context),
                    "wifi" => WifiPage.Build(_context),
                    "vpn" => VpnPage.Build(_context),
                    "router" => RouterPage.Build(_context),
                    _ => null,
                };
            }
            catch (Exception e)
            {
                // A page that cannot be built just goes unsearched; Preferences still works.
                CrashLog.Write("preferences search " + key, e);
                continue;
            }

            foreach (var text in Texts(page).Select(t => t.Block.Text.Trim()).Prepend(Kit.L(label)))
            {
                if (text.Length > 1 && seen.Add((text, key)))
                {
                    index.Add((text, key));
                }
            }
        }

        return index;
    }

    /// <summary>Every text block under <paramref name="root"/>, through the logical tree — the page need not be shown.</summary>
    private static IEnumerable<(TextBlock Block, int Depth)> Texts(DependencyObject? root)
    {
        if (root is null)
        {
            yield break;
        }

        var stack = new Stack<(DependencyObject Node, int Depth)>();
        stack.Push((root, 0));
        while (stack.Count > 0)
        {
            var (node, depth) = stack.Pop();
            if (node is TextBlock { Text.Length: > 0 } block)
            {
                yield return (block, depth);
            }

            foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>().Reverse())
            {
                stack.Push((child, depth + 1));
            }
        }
    }

    /// <summary>Windows 11 Settings' own values for each surface, so it sits beside real Settings.</summary>
    private void ApplyPalette()
    {
        var light = SystemTheme.IsAppLight();

        void Brush(string key, string hex)
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            brush.Freeze();
            Resources[key] = brush;
        }

        Brush("PageBrush", light ? "#F3F3F3" : "#202020");
        Brush("CardBrush", light ? "#FBFBFB" : "#2B2B2B");
        Brush("CardBorderBrush", light ? "#E5E5E5" : "#333333");
        Brush("MenuBrush", light ? "#F9F9F9" : "#2C2C2C");
        Brush("TextBrush", light ? "#1A1A1A" : "#FFFFFF");
        Brush("SecondaryTextBrush", light ? "#5D5D5D" : "#C5C5C5");
        Brush("ButtonBrush", light ? "#FBFBFB" : "#2D2D2D");
        Brush("ButtonHoverBrush", light ? "#F0F0F0" : "#353535");
        Brush("InputBrush", light ? "#FFFFFF" : "#1F1F1F");
        Brush("NavHoverBrush", light ? "#0A000000" : "#0FFFFFFF");
        Brush("NavSelectedBrush", light ? "#0F000000" : "#15FFFFFF");
        Brush("SwitchOffBrush", "#00000000");
        Brush("SwitchBorderBrush", light ? "#8A8A8A" : "#9A9A9A");
        Brush("SwitchKnobBrush", light ? "#5A5A5A" : "#CFCFCF");
        Brush("SwitchKnobOnBrush", light ? "#FFFFFF" : "#000000");
        Brush("OnAccentBrush", light ? "#FFFFFF" : "#000000");
        Brush("NoticeBrush", light ? "#FFF4CE" : "#433519");
        Brush("ActiveBrush", light ? "#0F7B0F" : "#6CCB5F");
        Brush("WarningBrush", light ? "#9D5D00" : "#FCB75D");

        // The Windows accent, as Settings uses it: the darker shade on light, the lighter on dark.
        var accent = SystemParameters.WindowGlassColor.A == 0
            ? (Color)ColorConverter.ConvertFromString(light ? "#005FB8" : "#4CC2FF")
            : SystemParameters.WindowGlassColor;
        Resources["AccentBrush"] = new SolidColorBrush(accent);
    }

    /// <summary>Windows switched between light and dark, or changed its accent: repaint to match.</summary>
    internal void ApplySystemTheme()
    {
        ApplyPalette();
        ThemeBrushes.ApplyFrame(this, !SystemTheme.IsAppLight());
    }

    /// <summary>
    /// Windows 11 22H2+ Mica. Silently skipped elsewhere — the solid page brush underneath is
    /// a complete look on its own, so this is polish, never a requirement.
    /// </summary>
    private void ApplyMicaBackdrop()
    {
        ThemeBrushes.ApplyFrame(this, !SystemTheme.IsAppLight());
        try
        {
            var handle = new WindowInteropHelper(this).Handle;
            var backdrop = 2;
            _ = DwmSetWindowAttribute(handle, 38, ref backdrop, sizeof(int));
        }
        catch (DllNotFoundException)
        {
        }
    }

    /// <summary>
    /// Shrinks the window to whatever the display has room for. The XAML size is a
    /// preference, not a promise: 780 units is taller than the work area of a 1366×768
    /// laptop, and a Preferences window whose last card cannot be scrolled to is worse than
    /// a cramped one. Measured on the monitor under the window, at that window's own DPI.
    /// </summary>
    private void FitToWorkArea()
    {
        const double Margin = 48;
        var handle = new WindowInteropHelper(this).Handle;
        if (Screens.MonitorOfWindow(handle) is not { } monitor)
        {
            return;
        }

        var scale = Screens.DpiScale(handle);
        var availableWidth = (monitor.Work.Width / scale) - Margin;
        var availableHeight = (monitor.Work.Height / scale) - Margin;

        Width = Math.Max(MinWidth, Math.Min(Width, availableWidth));
        Height = Math.Max(MinHeight, Math.Min(Height, availableHeight));
        Left = (monitor.Work.Left / scale) + ((availableWidth + Margin - Width) / 2);
        Top = (monitor.Work.Top / scale) + ((availableHeight + Margin - Height) / 2);
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
