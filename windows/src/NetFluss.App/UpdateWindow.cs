// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// "A new version of NetFluss is available!" — the Windows take on Sparkle's update alert:
/// the release notes, Install Update, Remind Me Later and Skip This Version, and the choice
/// to let future updates install themselves.
/// </summary>
internal sealed partial class UpdateWindow : Window
{
    private readonly UpdateNotifier _updates;
    private readonly AvailableUpdate _update;
    private readonly TextBlock _status;
    private readonly Button _install;
    private readonly Button _later;
    private readonly Button _skip;

    internal UpdateWindow(UpdateNotifier updates, AvailableUpdate update, SettingsStore store, SurfacePalette surface, ThemeColor download, ThemeColor upload)
    {
        _updates = updates;
        _update = update;

        Title = Localization.L("Software Update");
        Width = 560;
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

        var icon = new Image
        {
            Source = new BitmapImage(new Uri("pack://application:,,,/NetFluss;component/Assets/NetFluss.png")),
            Width = 64,
            Height = 64,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 0, 18, 0),
        };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);

        var canInstall = UpdateInstaller.CanInstall(update);
        var heading = Ui.Wrapping(Localization.L("A new version of NetFluss is available!"), 15, Ui.Text);
        heading.FontWeight = FontWeights.Bold;
        var question = Ui.Wrapping(
            canInstall
                ? Localization.L("NetFluss {0} is now available — you have {1}. Would you like to install it now?", update.Version, UpdateNotifier.CurrentVersion)
                : Localization.L("NetFluss {0} is now available — you have {1}. Would you like to download it now?", update.Version, UpdateNotifier.CurrentVersion),
            12,
            Ui.Text).Margin(0, 6, 0, 14);

        var notesTitle = Ui.Label(Localization.L("Release Notes:"), 12, Ui.Text, FontWeights.SemiBold).Margin(0, 0, 0, 6);
        var notesText = PlainNotes(update.ReleaseNotes);
        var notes = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 8, 10, 8),
            Child = new ScrollViewer
            {
                Height = 220,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = Ui.Wrapping(notesText.Length > 0 ? notesText : Localization.L("No release notes."), 12, Ui.Text),
            },
        };
        notes.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");

        var details = Ui.Column(heading, question, notesTitle, notes);

        if (canInstall)
        {
            var automatic = new CheckBox
            {
                IsChecked = store.Settings.AutomaticallyInstallUpdates,
                Margin = new Thickness(0, 12, 0, 0),
                VerticalContentAlignment = VerticalAlignment.Center,
                Content = Ui.Label(Localization.L("Automatically download and install updates in the future"), 12, Ui.Text),
            };
            automatic.Click += (_, _) => store.Batch(s => s.AutomaticallyInstallUpdates = automatic.IsChecked == true);
            details.Children.Add(automatic);
        }

        _status = Ui.Wrapping(string.Empty, 12).Margin(0, 10, 0, 0);
        _status.Visibility = Visibility.Collapsed;
        details.Children.Add(_status);

        var top = Ui.Columns(Ui.Auto, Ui.Star);
        top.Children.Add(icon.At(0));
        top.Children.Add(details.At(1));

        _skip = Ui.TextButton(Localization.L("Skip This Version"), () =>
        {
            _updates.Skip(_update);
            Close();
        }, accent: false);

        _later = Ui.TextButton(Localization.L("Remind Me Later"), Close, accent: false).Margin(0, 0, 8, 0);
        _install = canInstall
            ? Ui.TextButton(Localization.L("Install Update"), Install, accent: true)
            : Ui.TextButton(Localization.L("Download"), () =>
            {
                UpdateNotifier.Open(update.Download ?? update.ReleasePage);
                Close();
            }, accent: true);
        _install.IsDefault = true;

        var buttons = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto, Ui.Auto);
        buttons.Margin = new Thickness(82, 18, 0, 0);
        buttons.Children.Add(_skip.At(0));
        buttons.Children.Add(_later.At(2));
        buttons.Children.Add(_install.At(3));

        Content = new Border
        {
            Padding = new Thickness(22, 22, 22, 20),
            Child = Ui.Column(top, buttons),
        };

        // Windows does not let a background app take the foreground, so a scheduled find
        // would open behind whatever the user is doing. Raised once, without taking focus.
        ContentRendered += (_, _) =>
        {
            Topmost = true;
            Topmost = false;
        };
    }

    /// <summary>Whether this window is about <paramref name="update"/>.</summary>
    internal bool Shows(AvailableUpdate update) => _update.Version == update.Version;

    private async void Install()
    {
        _install.IsEnabled = _later.IsEnabled = _skip.IsEnabled = false;
        _status.Visibility = Visibility.Visible;
        _status.SetResourceReference(TextBlock.ForegroundProperty, Ui.Secondary);
        _status.Text = Localization.L("Downloading…");
        var progress = new Progress<double>(fraction =>
            _status.Text = Localization.L("Downloading… {0}", fraction.ToString("P0", Localization.Culture)));

        var (setup, error) = await _updates.PrepareAsync(_update, progress);
        if (setup is not null)
        {
            _status.Text = Localization.L("Installing…");
            error = await _updates.InstallAsync(_update, progress: null);
            if (error is null)
            {
                return;
            }
        }

        _status.Text = error ?? Localization.L("The update could not be installed.");
        _status.SetResourceReference(TextBlock.ForegroundProperty, Ui.Red);
        _install.IsEnabled = _later.IsEnabled = _skip.IsEnabled = true;
    }

    /// <summary>
    /// GitHub release notes are Markdown; shown as text, the markup should not get in the way:
    /// headings, quotes and emphasis lose their markers, list items get bullets, links keep
    /// their text, rules disappear and table rows become "cell — cell".
    /// </summary>
    internal static string PlainNotes(string markdown)
    {
        var lines = new List<string>();
        foreach (var raw in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.TrimEnd();
            if (Rule().IsMatch(line) || TableSeparator().IsMatch(line))
            {
                continue;
            }

            if (line.TrimStart().StartsWith('|'))
            {
                var cells = line.Trim().Trim('|').Split('|').Select(cell => cell.Trim()).Where(cell => cell.Length > 0);
                line = string.Join(" — ", cells);
            }

            line = Quote().Replace(line, string.Empty);
            line = Heading().Replace(line, string.Empty);
            line = Bullet().Replace(line, "$1• ");
            line = Link().Replace(line, "$1");
            line = line.Replace("**", string.Empty).Replace("__", string.Empty).Replace("`", string.Empty);
            lines.Add(line);
        }

        return Regex.Replace(string.Join('\n', lines).Trim(), "\n{3,}", "\n\n");
    }

    [GeneratedRegex(@"^\s{0,3}#{1,6}\s+")]
    private static partial Regex Heading();

    [GeneratedRegex(@"^(\s*)[-*+]\s+")]
    private static partial Regex Bullet();

    [GeneratedRegex(@"\[([^\]]+)\]\([^)]+\)")]
    private static partial Regex Link();

    [GeneratedRegex(@"^\s{0,3}([-*_])(\s*\1){2,}\s*$")]
    private static partial Regex Rule();

    [GeneratedRegex(@"^\s*\|?(\s*:?-{3,}:?\s*\|)+\s*(:?-{3,}:?\s*)?$")]
    private static partial Regex TableSeparator();

    [GeneratedRegex(@"^\s{0,3}>\s?")]
    private static partial Regex Quote();
}
