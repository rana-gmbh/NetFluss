// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using NetFluss.Core;

namespace NetFluss.App.Settings;

/// <summary>A combo entry: the stored value plus the label the user reads.</summary>
internal sealed record Choice(object Value, string Label)
{
    public override string ToString() => Label;
}

/// <summary>
/// Builders for the Windows 11 Settings idiom: grouped cards, title and description on the
/// left, the control on the right.
///
/// <para>Controls bind two-way straight to <see cref="AppSettings"/>. Every property there
/// raises a change that the settings store persists and the app re-applies, so a page needs
/// no OK button and no code to copy values back — which is how both Windows Settings and the
/// macOS preferences window behave.</para>
/// </summary>
internal static class Kit
{
    internal static string L(string key) => Localization.L(key);

    internal static string L(string key, params object?[] args) => Localization.L(key, args);

    internal static TextBlock Header(string text)
    {
        var block = Text(text, 15, "TextBrush", FontWeights.SemiBold);
        block.Margin = new Thickness(2, 22, 0, 8);
        return block;
    }

    internal static TextBlock Text(string text, double size = 14, string brush = "TextBrush", FontWeight? weight = null)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };

        block.SetResourceReference(TextBlock.FontFamilyProperty, "SetFont");
        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    internal static TextBlock Caption(string text)
    {
        var block = Text(text, 12, "SecondaryTextBrush");
        block.Margin = new Thickness(0, 2, 0, 0);
        return block;
    }

    internal static TextBlock Icon(string glyph, double size = 16, string brush = "TextBrush")
    {
        var block = new TextBlock { Text = glyph, FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        block.SetResourceReference(TextBlock.FontFamilyProperty, "SetIconFont");
        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    /// <summary>A settings card: title and optional description, a control on the right, optional content below.</summary>
    internal static Border Card(string title, string? description, UIElement? control, UIElement? below = null)
    {
        var text = new StackPanel();
        text.Children.Add(Text(title));
        if (!string.IsNullOrEmpty(description))
        {
            text.Children.Add(Caption(description));
        }

        return Card(text, control, below);
    }

    /// <summary>A settings card with custom left-hand content — a title plus a live status line, say.</summary>
    internal static Border Card(FrameworkElement left, UIElement? control, UIElement? below = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        left.Margin = new Thickness(0, 0, 16, 0);
        left.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(left);

        if (control is not null)
        {
            Grid.SetColumn(control, 1);
            if (control is FrameworkElement element)
            {
                element.VerticalAlignment = VerticalAlignment.Center;
            }

            grid.Children.Add(control);
        }

        if (below is not null)
        {
            Grid.SetRow(below, 1);
            Grid.SetColumnSpan(below, 2);
            if (below is FrameworkElement element)
            {
                element.Margin = new Thickness(0, 12, 0, 0);
            }

            grid.Children.Add(below);
        }

        var card = new Border { Child = grid };
        card.SetResourceReference(FrameworkElement.StyleProperty, "SetCard");
        return card;
    }

    /// <summary>A card whose whole body is custom content — lists, editors, previews.</summary>
    internal static Border Panel(UIElement content)
    {
        var card = new Border { Child = content };
        card.SetResourceReference(FrameworkElement.StyleProperty, "SetCard");
        return card;
    }

    internal static Binding Bind(AppSettings settings, string property) => new(property)
    {
        Source = settings,
        Mode = BindingMode.TwoWay,
        UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged,
    };

    /// <summary>A toggle switch bound to a boolean setting.</summary>
    internal static CheckBox Switch(AppSettings settings, string property)
    {
        var box = new CheckBox();
        box.SetResourceReference(FrameworkElement.StyleProperty, "SetSwitch");
        box.SetBinding(ToggleButton.IsCheckedProperty, Bind(settings, property));
        return box;
    }

    /// <summary>A toggle switch with its own handlers, for state that does not live in the settings file.</summary>
    internal static CheckBox Switch(bool isOn, Action<bool> changed)
    {
        var box = new CheckBox { IsChecked = isOn };
        box.SetResourceReference(FrameworkElement.StyleProperty, "SetSwitch");
        box.Click += (_, _) => changed(box.IsChecked == true);
        return box;
    }

    /// <summary>A dropdown bound to a setting; choices pair stored values with their labels.</summary>
    internal static ComboBox Combo(AppSettings settings, string property, IEnumerable<Choice> choices, double minWidth = 180)
    {
        var combo = new ComboBox
        {
            ItemsSource = choices.ToList(),
            SelectedValuePath = nameof(Choice.Value),
            DisplayMemberPath = nameof(Choice.Label),
            MinWidth = minWidth,
        };

        combo.SetBinding(Selector.SelectedValueProperty, Bind(settings, property));
        return combo;
    }

    /// <summary>A dropdown with its own handler, for choices that do not live in the settings file.</summary>
    internal static ComboBox Combo(IEnumerable<Choice> choices, object? selected, Action<object> changed, double minWidth = 180)
    {
        var list = choices.ToList();
        var combo = new ComboBox
        {
            ItemsSource = list,
            SelectedValuePath = nameof(Choice.Value),
            DisplayMemberPath = nameof(Choice.Label),
            MinWidth = minWidth,
            SelectedValue = selected,
        };

        // Subscribed after the initial selection, so only the user's picks are reported.
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedValue is { } value)
            {
                changed(value);
            }
        };
        return combo;
    }

    internal static Button Button(string text, Action onClick, bool accent = false)
    {
        var button = new Button { Content = text };
        button.SetResourceReference(FrameworkElement.StyleProperty, accent ? "SetAccentButton" : "SetButton");
        button.Click += (_, _) => onClick();
        return button;
    }

    internal static Button IconButton(string glyph, string tooltip, Action onClick)
    {
        var button = new Button { Content = glyph, ToolTip = tooltip };
        button.SetResourceReference(FrameworkElement.StyleProperty, "SetIconButton");
        button.Click += (_, _) => onClick();
        return button;
    }

    internal static StackPanel Row(params UIElement[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var child in children)
        {
            row.Children.Add(child);
        }

        return row;
    }

    /// <summary>Greys a card out while the setting it depends on is off, as Settings does.</summary>
    internal static void EnableWhen(FrameworkElement element, AppSettings settings, string property)
        => element.SetBinding(UIElement.IsEnabledProperty, new Binding(property) { Source = settings, Mode = BindingMode.OneWay });

    /// <summary>The accent choices shared by every colour picker, matching the macOS list.</summary>
    internal static IEnumerable<Choice> Accents(bool withAutomatic = true)
    {
        if (withAutomatic)
        {
            yield return new Choice("system", L("Automatic"));
        }

        yield return new Choice("blue", L("Blue"));
        yield return new Choice("green", L("Green"));
        yield return new Choice("red", L("Red"));
        yield return new Choice("teal", L("Teal"));
        yield return new Choice("purple", L("Purple"));
        yield return new Choice("orange", L("Orange"));
        yield return new Choice("pink", L("Pink"));
        yield return new Choice("yellow", L("Yellow"));
        yield return new Choice("white", L("White"));
        yield return new Choice("black", L("Black"));
        yield return new Choice("custom", L("Custom color"));
    }

    /// <summary>
    /// An accent dropdown with a live swatch, and a hex field that appears for "Custom".
    /// </summary>
    internal static FrameworkElement ColorPicker(AppSettings settings, string selectionProperty, string hexProperty, Func<ThemeColor> resolve, bool withAutomatic = true)
    {
        var swatch = new Border
        {
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        swatch.SetResourceReference(Border.BorderBrushProperty, "CardBorderBrush");

        var combo = Combo(settings, selectionProperty, Accents(withAutomatic), 150);

        var hex = new TextBox { Width = 90, Margin = new Thickness(8, 0, 0, 0), MaxLength = 7, ToolTip = "RRGGBB" };
        hex.SetBinding(TextBox.TextProperty, new Binding(hexProperty)
        {
            Source = settings,
            Mode = BindingMode.TwoWay,
            UpdateSourceTrigger = UpdateSourceTrigger.LostFocus,
        });

        void Refresh()
        {
            var color = resolve();
            swatch.Background = new SolidColorBrush(Color.FromRgb(color.R, color.G, color.B));
            hex.Visibility = Equals(combo.SelectedValue, "custom") ? Visibility.Visible : Visibility.Collapsed;
        }

        combo.SelectionChanged += (_, _) => Refresh();
        hex.LostFocus += (_, _) => Refresh();

        var row = Row(swatch, combo, hex);
        Watch(row, settings, name =>
        {
            if (name is nameof(AppSettings.ThemeId) || name == selectionProperty || name == hexProperty)
            {
                Refresh();
            }
        });

        Refresh();
        return row;
    }

    /// <summary>
    /// Listens to setting changes only while <paramref name="owner"/> is on screen. The
    /// settings object lives as long as the app; a handler attached for good from a page
    /// would keep every Preferences window ever opened alive, and keep updating it.
    /// </summary>
    internal static void Watch(FrameworkElement owner, AppSettings settings, Action<string?> changed)
    {
        void Handler(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => changed(e.PropertyName);

        owner.Loaded += (_, _) => settings.PropertyChanged += Handler;
        owner.Unloaded += (_, _) => settings.PropertyChanged -= Handler;
    }
}
