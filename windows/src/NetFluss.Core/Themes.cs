// Copyright (C) 2026 Rana GmbH
//
// This file is part of NetFluss.
//
// NetFluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// NetFluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with NetFluss. If not, see <https://www.gnu.org/licenses/>.

using System.Globalization;

namespace NetFluss.Core;

/// <summary>
/// Platform-neutral RGB colour. Core deliberately does not reference WPF or System.Drawing
/// so it stays unit-testable off Windows; the app layer converts to the framework type.
/// </summary>
public readonly record struct ThemeColor(byte R, byte G, byte B)
{
    /// <summary>Port of the macOS <c>Color(hex:)</c> extension. Accepts "8be9fd" or "#8be9fd".</summary>
    public static ThemeColor FromHex(string hex)
        => TryFromHex(hex, out var color)
            ? color
            : throw new FormatException($"'{hex}' is not a six-digit RGB hex colour.");

    public static bool TryFromHex(string hex, out ThemeColor color)
    {
        color = default;

        // Mirrors the Swift trim of everything outside the alphanumeric set, which is how
        // the macOS side tolerates a leading '#'.
        Span<char> digits = stackalloc char[6];
        var count = 0;
        foreach (var c in hex)
        {
            if (!char.IsAsciiLetterOrDigit(c))
            {
                continue;
            }

            if (count == 6)
            {
                return false;
            }

            digits[count++] = c;
        }

        if (count != 6 || !uint.TryParse(digits, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
        {
            return false;
        }

        color = new ThemeColor((byte)((value >> 16) & 0xFF), (byte)((value >> 8) & 0xFF), (byte)(value & 0xFF));
        return true;
    }

    public string ToHex() => $"{R:X2}{G:X2}{B:X2}";
}

/// <summary>Port of the macOS <c>AppTheme</c> presets (Sources/Netfluss/Themes.swift).</summary>
public sealed record AppTheme
{
    public required string Id { get; init; }

    public required string DisplayName { get; init; }

    public required ThemeColor DownloadColor { get; init; }

    public required ThemeColor UploadColor { get; init; }

    /// <summary>Null means "follow the system" — the app layer substitutes the Fluent brush.</summary>
    public ThemeColor? BackgroundColor { get; init; }

    public ThemeColor? CardColor { get; init; }

    public ThemeColor? TextPrimary { get; init; }

    public ThemeColor? TextSecondary { get; init; }

    public required bool IsDark { get; init; }

    public static readonly AppTheme System = new()
    {
        Id = "system",
        DisplayName = "System",
        // Windows accent equivalents of macOS .blue / .green.
        DownloadColor = ThemeColor.FromHex("0078d4"),
        UploadColor = ThemeColor.FromHex("2ea043"),
        IsDark = false,
    };

    public static readonly AppTheme Dracula = new()
    {
        Id = "dracula",
        DisplayName = "Dracula",
        DownloadColor = ThemeColor.FromHex("8be9fd"),
        UploadColor = ThemeColor.FromHex("50fa7b"),
        BackgroundColor = ThemeColor.FromHex("282a36"),
        CardColor = ThemeColor.FromHex("44475a"),
        TextPrimary = ThemeColor.FromHex("ffffff"),
        TextSecondary = ThemeColor.FromHex("6272a4"),
        IsDark = true,
    };

    public static readonly AppTheme Nord = new()
    {
        Id = "nord",
        DisplayName = "Nord",
        DownloadColor = ThemeColor.FromHex("88c0d0"),
        UploadColor = ThemeColor.FromHex("a3be8c"),
        BackgroundColor = ThemeColor.FromHex("2e3440"),
        CardColor = ThemeColor.FromHex("3b4252"),
        TextPrimary = ThemeColor.FromHex("eceff4"),
        TextSecondary = ThemeColor.FromHex("4c566a"),
        IsDark = true,
    };

    public static readonly AppTheme Solarized = new()
    {
        Id = "solarized",
        DisplayName = "Solarized",
        DownloadColor = ThemeColor.FromHex("268bd2"),
        UploadColor = ThemeColor.FromHex("859900"),
        BackgroundColor = ThemeColor.FromHex("002b36"),
        CardColor = ThemeColor.FromHex("073642"),
        TextPrimary = ThemeColor.FromHex("839496"),
        TextSecondary = ThemeColor.FromHex("586e75"),
        IsDark = true,
    };

    public static readonly IReadOnlyList<AppTheme> All = [System, Dracula, Nord, Solarized];

    public static AppTheme Named(string id)
        => All.FirstOrDefault(theme => theme.Id == id) ?? System;

    /// <summary>
    /// True when this theme dictates its own colours rather than deferring to Windows.
    /// <see cref="System"/> is the only one that does not.
    /// </summary>
    public bool IsExplicit => Id != System.Id;

    /// <summary>
    /// The concrete colours for a themed window, with anything the theme leaves unset filled
    /// in from Windows' own light or dark palette.
    ///
    /// <para>Only <see cref="System"/> leaves them unset, and it leaves *all* of them unset —
    /// which is exactly what "follow Windows" has to mean for a window that would otherwise
    /// be a dark panel sitting on a light desktop.</para>
    /// </summary>
    public SurfacePalette Surface(bool systemIsLight)
    {
        if (!IsExplicit)
        {
            return systemIsLight
                ? new SurfacePalette(
                    ThemeColor.FromHex("FAFAFA"),
                    ThemeColor.FromHex("EFEFEF"),
                    ThemeColor.FromHex("1A1A1A"),
                    ThemeColor.FromHex("5D5D5D"),
                    IsDark: false)
                : new SurfacePalette(
                    ThemeColor.FromHex("202020"),
                    ThemeColor.FromHex("2E2E2E"),
                    ThemeColor.FromHex("FFFFFF"),
                    ThemeColor.FromHex("C5C5C5"),
                    IsDark: true);
        }

        return new SurfacePalette(
            BackgroundColor ?? ThemeColor.FromHex("202020"),
            CardColor ?? ThemeColor.FromHex("2E2E2E"),
            TextPrimary ?? ThemeColor.FromHex("FFFFFF"),
            TextSecondary ?? ThemeColor.FromHex("C5C5C5"),
            IsDark);
    }
}

/// <summary>Fully resolved window colours — no nulls left for the app layer to guess at.</summary>
public readonly record struct SurfacePalette(
    ThemeColor Background,
    ThemeColor Card,
    ThemeColor TextPrimary,
    ThemeColor TextSecondary,
    bool IsDark);

/// <summary>
/// Named accent choices offered in Preferences → Appearance, matching the macOS list.
/// "system" resolves at the app layer to the current Fluent text brush, so it stays
/// legible when the taskbar switches between light and dark.
/// </summary>
public static class AccentPalette
{
    private static readonly Dictionary<string, ThemeColor> Named = new(StringComparer.Ordinal)
    {
        ["green"] = ThemeColor.FromHex("2ea043"),
        ["blue"] = ThemeColor.FromHex("0078d4"),
        ["red"] = ThemeColor.FromHex("e81123"),
        ["orange"] = ThemeColor.FromHex("f7630c"),
        ["yellow"] = ThemeColor.FromHex("fce100"),
        ["teal"] = ThemeColor.FromHex("00b7c3"),
        ["purple"] = ThemeColor.FromHex("8764b8"),
        ["pink"] = ThemeColor.FromHex("e3008c"),
        ["white"] = ThemeColor.FromHex("ffffff"),
        ["black"] = ThemeColor.FromHex("000000"),
    };

    /// <summary>Returns null for "system", which only the app layer can resolve.</summary>
    public static ThemeColor? Resolve(string selection, string customHex, ThemeColor fallback)
    {
        if (selection == "custom")
        {
            return ThemeColor.TryFromHex(customHex, out var custom) ? custom : fallback;
        }

        if (selection == "system")
        {
            return null;
        }

        return Named.TryGetValue(selection, out var named) ? named : fallback;
    }
}
