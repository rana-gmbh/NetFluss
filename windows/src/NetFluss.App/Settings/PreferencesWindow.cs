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
    private string _current = "general";

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

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(right, 1);
        root.Children.Add(_nav);
        root.Children.Add(right);
        Content = root;

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
