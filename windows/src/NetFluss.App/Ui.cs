// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// Segoe Fluent Icons code points, named for what NetFluss uses them for. Each was checked
/// by rendering it — the font has no glyph names worth trusting, and a wrong code point
/// draws a plausible but unrelated icon rather than failing.
/// </summary>
internal static class Glyph
{
    internal const string Down = "";
    internal const string Up = "";
    internal const string Wifi = "";
    internal const string Ethernet = "";
    internal const string Network = "";
    internal const string Globe = "";
    internal const string Laptop = "";
    internal const string Router = "";
    internal const string Shield = "";
    /// <summary>Windows' own VPN glyph, as its quick settings draw it.</summary>
    internal const string Vpn = "";
    internal const string Lock = "";
    internal const string Copy = "";
    internal const string Edit = "";
    internal const string Home = "";
    internal const string Tag = "";
    internal const string Apps = "";
    internal const string Bolt = "";
    internal const string Back = "";
    internal const string Pulse = "";
    internal const string ChevronDown = "";
    internal const string ChevronUp = "";
    internal const string Delete = "";
    internal const string Add = "";
    internal const string Play = "";
    internal const string Pause = "";
    internal const string Check = "";
    internal const string CheckCircle = "";
    internal const string Circle = "";
    internal const string Pin = "";
    internal const string Unpin = "";
    internal const string Pinned = "";
    internal const string Info = "";
    internal const string Refresh = "";
    internal const string Settings = "";
    internal const string Chart = "";
    internal const string BarChart = "";
    internal const string Speed = "";
    internal const string Close = "";
    internal const string Warning = "";
    internal const string Star = "";
    internal const string ChevronRight = "";
    internal const string Signal1 = "";
    internal const string Signal2 = "";
    internal const string Signal3 = "";
    internal const string Signal4 = "";
    internal const string EyeHide = "";
    internal const string Power = "";
    internal const string More = "";

    internal static string ForAdapter(AdapterType type) => type switch
    {
        AdapterType.WiFi => Wifi,
        AdapterType.Ethernet => Ethernet,
        _ => Network,
    };

    internal static string ForSignal(int bars) => bars switch
    {
        <= 1 => Signal1,
        2 => Signal2,
        3 => Signal3,
        _ => Signal4,
    };
}

/// <summary>The frame for a detail flyout opened from a popover row: card colour, hairline, shadow.</summary>
internal static class Flyout
{
    internal static FrameworkElement Frame(UIElement content, double width)
    {
        var border = new Border
        {
            Width = width,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(8),
            Child = content,
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                BlurRadius = 16,
                ShadowDepth = 3,
                Opacity = 0.35,
                Direction = 270,
            },
        };

        border.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        border.SetResourceReference(Border.BorderBrushProperty, "PopoverDividerBrush");
        return border;
    }
}

/// <summary>
/// Element factories for the code-built popover sections. Every colour is bound with
/// <see cref="FrameworkElement.SetResourceReference"/> so a theme change repaints in place.
/// </summary>
internal static class Ui
{
    internal static readonly FontFamily UiFont = new("Segoe UI Variable Text, Segoe UI");
    internal static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    internal const string Text = "PopoverTextBrush";
    internal const string Secondary = "PopoverSecondaryBrush";
    internal const string Tertiary = "PopoverTertiaryBrush";
    internal const string Download = "PopoverDownloadBrush";
    internal const string Upload = "PopoverUploadBrush";
    internal const string Accent = "PopoverAccentBrush";
    internal const string Green = "PopoverGreenBrush";
    internal const string Orange = "PopoverOrangeBrush";
    internal const string Red = "PopoverRedBrush";

    internal static TextBlock Label(string text, double size = 12, string brush = Text, FontWeight? weight = null)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = UiFont,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };

        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    /// <summary>A label whose digits keep a fixed width, so a ticking rate does not jitter.</summary>
    internal static TextBlock Number(string text, double size = 12, string brush = Text, FontWeight? weight = null)
    {
        var block = Label(text, size, brush, weight);
        Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
        return block;
    }

    internal static TextBlock Wrapping(string text, double size = 12, string brush = Secondary)
    {
        var block = Label(text, size, brush);
        block.TextWrapping = TextWrapping.Wrap;
        block.TextTrimming = TextTrimming.None;
        return block;
    }

    internal static TextBlock Icon(string glyph, double size = 12, string brush = Text)
    {
        var block = new TextBlock
        {
            Text = glyph,
            FontFamily = IconFont,
            FontSize = size,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };

        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    /// <summary>A section's small heading — the 10 pt semibold secondary label on macOS.</summary>
    internal static TextBlock SectionTitle(string text)
    {
        var block = Label(text, 11, Secondary, FontWeights.SemiBold);
        block.Margin = new Thickness(14, 10, 14, 6);
        return block;
    }

    internal static Button IconButton(string glyph, string tooltip, Action onClick, double size = 12)
    {
        var button = new Button
        {
            Content = glyph,
            FontSize = size,
            ToolTip = tooltip,
        };

        button.SetResourceReference(FrameworkElement.StyleProperty, "NfIconButton");
        button.Click += (_, e) =>
        {
            e.Handled = true;
            onClick();
        };

        return button;
    }

    internal static Button RowButton(UIElement content, Action onClick)
    {
        var button = new Button { Content = content };
        button.SetResourceReference(FrameworkElement.StyleProperty, "NfRowButton");
        button.Click += (_, e) =>
        {
            e.Handled = true;
            onClick();
        };

        return button;
    }

    internal static Button LinkButton(string text, Action onClick)
    {
        var button = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Left };
        button.SetResourceReference(FrameworkElement.StyleProperty, "NfLinkButton");
        button.Click += (_, e) =>
        {
            e.Handled = true;
            onClick();
        };

        return button;
    }

    internal static Button TextButton(string text, Action onClick, bool accent)
    {
        var button = new Button { Content = text };
        button.SetResourceReference(FrameworkElement.StyleProperty, accent ? "NfAccentButton" : "NfSubtleButton");
        button.Click += (_, e) =>
        {
            e.Handled = true;
            onClick();
        };

        return button;
    }

    /// <summary>The rounded card behind an adapter — the macOS quinary fill.</summary>
    internal static Border Card(UIElement child, Thickness? padding = null)
    {
        var border = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = padding ?? new Thickness(10, 8, 10, 8),
            Child = child,
        };

        border.SetResourceReference(Border.BackgroundProperty, "PopoverCardBrush");
        return border;
    }

    internal static Border Divider()
    {
        var line = new Border { Height = 1, Margin = new Thickness(0) };
        line.SetResourceReference(Border.BackgroundProperty, "PopoverDividerBrush");
        return line;
    }

    /// <summary>A pill badge — link speed on an adapter card, a country code on the VPN node.</summary>
    internal static Border Badge(TextBlock text)
    {
        var border = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 1, 6, 1),
            Child = text,
            VerticalAlignment = VerticalAlignment.Center,
        };

        border.SetResourceReference(Border.BackgroundProperty, "PopoverTrackBrush");
        return border;
    }

    /// <summary>A thin proportional bar, used for Top Apps and router utilisation.</summary>
    internal static (Grid Track, Border Fill) Bar(string fillBrush)
    {
        var track = new Grid { Height = 3, Margin = new Thickness(0, 4, 0, 0) };
        var background = new Border { CornerRadius = new CornerRadius(1.5) };
        background.SetResourceReference(Border.BackgroundProperty, "PopoverTrackBrush");

        var fill = new Border
        {
            CornerRadius = new CornerRadius(1.5),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0,
            Opacity = 0.7,
        };

        fill.SetResourceReference(Border.BackgroundProperty, fillBrush);
        track.Children.Add(background);
        track.Children.Add(fill);
        return (track, fill);
    }

    /// <summary>Sizes a <see cref="Bar"/> fill to a 0–1 fraction of its track.</summary>
    internal static void SetFraction(Grid track, Border fill, double fraction)
    {
        var width = track.ActualWidth;
        fill.Width = width > 0 ? Math.Clamp(fraction, 0, 1) * width : 0;
    }

    internal static Grid Columns(params GridLength[] widths)
    {
        var grid = new Grid();
        foreach (var width in widths)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }

        return grid;
    }

    internal static T At<T>(this T element, int column, int row = 0)
        where T : UIElement
    {
        Grid.SetColumn(element, column);
        Grid.SetRow(element, row);
        return element;
    }

    internal static T Margin<T>(this T element, double left, double top, double right, double bottom)
        where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    internal static StackPanel Row(params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var child in children)
        {
            panel.Children.Add(child);
        }

        return panel;
    }

    internal static StackPanel Column(params UIElement[] children)
    {
        var panel = new StackPanel();
        foreach (var child in children)
        {
            panel.Children.Add(child);
        }

        return panel;
    }

    internal static readonly GridLength Auto = GridLength.Auto;
    internal static readonly GridLength Star = new(1, GridUnitType.Star);

    internal static GridLength Fixed(double width) => new(width);

    /// <summary>
    /// Copies text and shows a check on the button for a moment, the macOS copy feedback.
    /// The clipboard can be held open by another process, which throws rather than waits.
    /// </summary>
    internal static void CopyWithFeedback(string text, Button button, string restoreGlyph)
    {
        if (!Copy(text))
        {
            return;
        }

        button.Content = Glyph.Check;
        button.SetResourceReference(Control.ForegroundProperty, Green);

        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            button.Content = restoreGlyph;
            button.ClearValue(Control.ForegroundProperty);
        };

        timer.Start();
    }

    /// <summary>Puts text on the clipboard; false when another process is holding it open.</summary>
    internal static bool Copy(string text)
    {
        try
        {
            Clipboard.SetText(text);
            return true;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return false;
        }
    }
}
