// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// About NetFluss — port of the macOS <c>AboutView</c>: identity, author, support, licence,
/// and Check for Updates with the release notes inline when one is found.
/// </summary>
internal sealed class AboutWindow : Window
{
    private readonly UpdateNotifier _updates;
    private readonly StackPanel _updateArea = new() { HorizontalAlignment = HorizontalAlignment.Stretch };

    internal AboutWindow(UpdateNotifier updates, SurfacePalette surface, ThemeColor download, ThemeColor upload)
    {
        _updates = updates;

        Title = Localization.L("About NetFluss");
        Width = 340;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Ui.UiFont;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/NetFluss;component/PopoverResources.xaml") });
        ThemeBrushes.Apply(Resources, surface, download, upload);
        SetResourceReference(BackgroundProperty, "PopoverBackgroundBrush");
        SourceInitialized += (_, _) => ThemeBrushes.ApplyFrame(this, surface.IsDark);

        var version = UpdateNotifier.CurrentVersion;

        var icon = new Image
        {
            Source = new BitmapImage(new Uri("pack://application:,,,/NetFluss;component/Assets/NetFluss.png")),
            Width = 72,
            Height = 72,
            Margin = new Thickness(0, 26, 0, 10),
        };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);

        var name = Centered(Ui.Label("NetFluss", 20, Ui.Text, FontWeights.Bold));
        var versionLine = Ui.Row(
            Ui.Label(Localization.L("Version {0}", version), 13, Ui.Secondary),
            Ui.LinkButton(Localization.L("Release Notes") + " ↗", () => UpdateNotifier.Open(new Uri($"https://github.com/rana-gmbh/NetFluss/releases/tag/{UpdateLookup.TagPrefix}{version}"))).Margin(8, 0, 0, 0));
        versionLine.HorizontalAlignment = HorizontalAlignment.Center;
        versionLine.Margin = new Thickness(0, 4, 0, 18);

        var author = Ui.Column(
            Centered(Ui.Label(Localization.L("Made by Rana GmbH"), 13, Ui.Text)),
            Centered(Ui.LinkButton("www.ranagmbh.de", () => UpdateNotifier.Open(new Uri("https://www.ranagmbh.de")))));
        author.Margin = new Thickness(0, 14, 0, 14);

        var support = Ui.Column(
            Centered(Ui.Label(Localization.L("If you want to support this project,"), 12, Ui.Secondary)),
            Ui.Row(
                Ui.Label(Localization.L("please consider to "), 12, Ui.Secondary),
                Ui.LinkButton(Localization.L("Buy me a coffee") + " ↗", () => UpdateNotifier.Open(new Uri("https://buymeacoffee.com/robertrudolph")))));
        ((StackPanel)support.Children[1]).HorizontalAlignment = HorizontalAlignment.Center;
        support.Margin = new Thickness(0, 12, 0, 12);

        var licence = Ui.Column(
            Centered(Ui.Label(Localization.L("Released under the"), 12, Ui.Secondary)),
            Centered(Ui.LinkButton(Localization.L("GNU General Public License v3.0") + " ↗", () => UpdateNotifier.Open(new Uri("https://www.gnu.org/licenses/gpl-3.0.html")))));
        licence.Margin = new Thickness(0, 12, 0, 12);

        _updateArea.Margin = new Thickness(20, 16, 20, 20);
        ShowIdle();

        Content = Ui.Column(
            Centered(icon),
            name,
            versionLine,
            Ui.Divider(),
            author,
            Ui.Divider(),
            support,
            Ui.Divider(),
            licence,
            Ui.Divider(),
            _updateArea);

        if (updates.Available is { } known)
        {
            ShowAvailable(known);
        }
    }

    private void ShowIdle()
    {
        _updateArea.Children.Clear();
        var button = Ui.TextButton(Localization.L("Check for Updates"), Check, accent: true);
        button.HorizontalAlignment = HorizontalAlignment.Center;
        _updateArea.Children.Add(button);
    }

    private async void Check()
    {
        _updateArea.Children.Clear();
        _updateArea.Children.Add(Centered(Ui.Label(Localization.L("Checking for updates…"), 13, Ui.Secondary)));

        try
        {
            var update = await _updates.CheckNowAsync();
            if (update is null)
            {
                ShowUpToDate();
            }
            else
            {
                ShowAvailable(update);
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            _updateArea.Children.Clear();
            _updateArea.Children.Add(Centered(Ui.Wrapping(Localization.L("Could not check for updates: {0}", e.Message), 12)));
            var retry = Ui.LinkButton(Localization.L("Try Again"), Check);
            retry.HorizontalAlignment = HorizontalAlignment.Center;
            _updateArea.Children.Add(retry);
        }
    }

    private void ShowUpToDate()
    {
        _updateArea.Children.Clear();
        var check = Ui.Icon(Glyph.CheckCircle, 14, Ui.Green).Margin(0, 0, 6, 0);
        var row = Ui.Row(check, Ui.Label(Localization.L("You're up to date"), 13, Ui.Green, FontWeights.SemiBold));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        _updateArea.Children.Add(row);

        var again = Ui.LinkButton(Localization.L("Check Again"), Check);
        again.HorizontalAlignment = HorizontalAlignment.Center;
        again.Margin = new Thickness(0, 6, 0, 0);
        _updateArea.Children.Add(again);
    }

    private void ShowAvailable(AvailableUpdate update)
    {
        _updateArea.Children.Clear();
        _updateArea.Children.Add(Centered(Ui.Label(Localization.L("NetFluss {0} is available!", update.Version), 13, Ui.Accent, FontWeights.SemiBold)));

        if (!string.IsNullOrWhiteSpace(update.ReleaseNotes))
        {
            var notes = new ScrollViewer
            {
                MaxHeight = 120,
                Margin = new Thickness(0, 10, 0, 0),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = Ui.Wrapping(update.ReleaseNotes.Trim(), 12),
            };

            var frame = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(8), Child = notes };
            frame.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
            _updateArea.Children.Add(frame);
        }

        var page = Ui.LinkButton(Localization.L("Release Page") + " ↗", () => UpdateNotifier.Open(update.ReleasePage));
        var buttons = Ui.Columns(Ui.Star, Ui.Auto);
        buttons.Margin = new Thickness(0, 12, 0, 0);
        buttons.Children.Add(page.At(0));

        // An installed copy updates itself, as Sparkle does on macOS; a portable copy, or a
        // release without a verifiable installer, gets the download instead.
        if (UpdateInstaller.CanInstall(update))
        {
            var status = Ui.Wrapping(string.Empty, 12);
            status.HorizontalAlignment = HorizontalAlignment.Center;
            status.Margin = new Thickness(0, 8, 0, 0);
            status.Visibility = Visibility.Collapsed;

            Button? install = null;
            install = Ui.TextButton(Localization.L("Install and Relaunch"), async () =>
            {
                install!.IsEnabled = false;
                status.Visibility = Visibility.Visible;
                status.Text = Localization.L("Downloading…");
                var progress = new Progress<double>(fraction =>
                    status.Text = Localization.L("Downloading… {0}", fraction.ToString("P0", Localization.Culture)));

                // Reuses a setup already fetched in the background; on success NetFluss quits
                // cleanly and the setup, which waits for that, relaunches it.
                var error = await _updates.InstallAsync(update, progress);
                if (error is null)
                {
                    status.Text = Localization.L("Installing…");
                    return;
                }

                status.Text = error;
                status.SetResourceReference(TextBlock.ForegroundProperty, Ui.Red);
                install.IsEnabled = true;
            }, accent: true);

            buttons.Children.Add(install.At(1));
            _updateArea.Children.Add(buttons);
            _updateArea.Children.Add(status);
            return;
        }

        var download = Ui.TextButton(Localization.L("Download"), () => UpdateNotifier.Open(update.Download ?? update.ReleasePage), accent: true);
        buttons.Children.Add(download.At(1));
        _updateArea.Children.Add(buttons);
    }

    private static T Centered<T>(T element)
        where T : FrameworkElement
    {
        element.HorizontalAlignment = HorizontalAlignment.Center;
        return element;
    }
}
