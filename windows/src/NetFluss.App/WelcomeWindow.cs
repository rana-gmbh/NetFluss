// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// A short welcome for a new install — port of the macOS 2.7.2 <c>WelcomeView</c>: where the
/// meter went, the two choices worth making up front, and how the helper is asked for.
/// Shown once, on the first launch with no settings file.
/// </summary>
internal sealed class WelcomeWindow : Window
{
    internal WelcomeWindow(SettingsStore store, SurfacePalette surface, ThemeColor download, ThemeColor upload, Action openPreferences)
    {
        var settings = store.Settings;

        Title = Localization.L("Welcome to NetFluss");
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Ui.UiFont;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/NetFluss;component/PopoverResources.xaml") });
        ThemeBrushes.Apply(Resources, surface, download, upload);
        SetResourceReference(BackgroundProperty, "PopoverBackgroundBrush");
        SourceInitialized += (_, _) => ThemeBrushes.ApplyFrame(this, surface.IsDark);

        var heading = Ui.Label(Localization.L("Welcome to NetFluss"), 20, Ui.Text, FontWeights.SemiBold);

        var where = settings.MeterSurface == MeterSurface.Tray
            ? Localization.L("Your live network speed is now in the notification area. Click it for the details; the More button there opens Preferences, Statistics, Speed Test and more.")
            : Localization.L("Your live network speed is now on the taskbar, next to the clock. Click it for the details; the More button there opens Preferences, Statistics, Speed Test and more.");
        var intro = Ui.Wrapping(where, 13, Ui.Text).Margin(0, 10, 0, 14);

        CheckBox Choice(string label, bool value, Action<bool> changed)
        {
            var box = new CheckBox
            {
                Content = Localization.L(label),
                IsChecked = value,
                Margin = new Thickness(0, 0, 0, 8),
                FontSize = 13,
            };
            box.SetResourceReference(ForegroundProperty, Ui.Text);
            box.Click += (_, _) => changed(box.IsChecked == true);
            return box;
        }

        var statistics = Choice("Collect historical statistics", settings.CollectStatistics, on => settings.CollectStatistics = on);
        var topApps = Choice("Show top apps by network usage", settings.ShowTopApps, on => settings.ShowTopApps = on);

        var helper = Ui.Wrapping(
            Localization.L("DNS switching and OpenVPN or WireGuard use the optional NetFluss helper (Preferences → General → System access). Without it, each DNS change asks for administrator approval."),
            12).Margin(0, 6, 0, 18);

        var preferences = new Button { Content = Localization.L("Preferences…"), Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 0) };
        preferences.SetResourceReference(StyleProperty, "NfSubtleButton");
        preferences.Click += (_, _) =>
        {
            Close();
            openPreferences();
        };

        var done = new Button { Content = Localization.L("Done"), Padding = new Thickness(18, 6, 18, 6), IsDefault = true };
        done.SetResourceReference(StyleProperty, "NfAccentButton");
        done.Click += (_, _) => Close();

        var buttons = Ui.Row(preferences, done);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;

        // A fixed text width with the window sized around it, so the explanations wrap the
        // same way at every scale instead of running past the edge.
        var body = Ui.Column(heading, intro, statistics, topApps, helper, buttons);
        body.Width = 372;
        Content = new Border { Padding = new Thickness(24, 22, 24, 22), Child = body };
        Loaded += (_, _) => done.Focus();
    }
}
