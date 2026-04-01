// Copyright (C) 2026 Rana GmbH
//
// This file is part of Netfluss.
//
// Netfluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Netfluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Netfluss. If not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

// MARK: - Color(hex:) extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 else { return nil }

        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }

        self.init(
            red: CGFloat((int >> 16) & 0xFF) / 255,
            green: CGFloat((int >> 8) & 0xFF) / 255,
            blue: CGFloat(int & 0xFF) / 255,
            alpha: 1
        )
    }

    var rgbHexString: String? {
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

func resolvedAccentColor(selection: String, customHex: String, fallback: Color) -> Color {
    if selection == "custom", let custom = NSColor(hex: customHex) {
        return Color(nsColor: custom)
    }
    if let named = accentNSColor(named: selection) {
        return Color(nsColor: named)
    }
    return fallback
}

func resolvedAccentNSColor(selection: String, customHex: String, fallback: NSColor) -> NSColor {
    if selection == "custom", let custom = NSColor(hex: customHex) {
        return custom
    }
    return accentNSColor(named: selection) ?? fallback
}

func downloadAccentColor(for theme: AppTheme) -> Color {
    resolvedAccentColor(
        selection: UserDefaults.standard.string(forKey: "downloadColor") ?? "blue",
        customHex: UserDefaults.standard.string(forKey: "downloadColorHex") ?? "",
        fallback: theme.downloadColor
    )
}

func uploadAccentColor(for theme: AppTheme) -> Color {
    resolvedAccentColor(
        selection: UserDefaults.standard.string(forKey: "uploadColor") ?? "green",
        customHex: UserDefaults.standard.string(forKey: "uploadColorHex") ?? "",
        fallback: theme.uploadColor
    )
}

private func accentNSColor(named name: String) -> NSColor? {
    switch name {
    case "green":  return .systemGreen
    case "blue":   return .systemBlue
    case "orange": return .systemOrange
    case "yellow": return .systemYellow
    case "teal":   return .systemTeal
    case "purple": return .systemPurple
    case "pink":   return .systemPink
    case "white":  return .white
    case "black":  return .black
    default:       return nil
    }
}

// MARK: - AppTheme

struct AppTheme: Identifiable, Equatable {
    let id: String
    let displayName: String
    let downloadColor: Color
    let uploadColor: Color
    let backgroundColor: Color?
    let cardColor: Color?
    let textPrimary: Color?
    let textSecondary: Color?
    let isDark: Bool

    static let system = AppTheme(
        id: "system",
        displayName: "System",
        downloadColor: .blue,
        uploadColor: .green,
        backgroundColor: nil,
        cardColor: nil,
        textPrimary: nil,
        textSecondary: nil,
        isDark: false
    )

    static let dracula = AppTheme(
        id: "dracula",
        displayName: "Dracula",
        downloadColor: Color(hex: "8be9fd"),
        uploadColor: Color(hex: "50fa7b"),
        backgroundColor: Color(hex: "282a36"),
        cardColor: Color(hex: "44475a"),
        textPrimary: .white,
        textSecondary: Color(hex: "6272a4"),
        isDark: true
    )

    static let nord = AppTheme(
        id: "nord",
        displayName: "Nord",
        downloadColor: Color(hex: "88c0d0"),
        uploadColor: Color(hex: "a3be8c"),
        backgroundColor: Color(hex: "2e3440"),
        cardColor: Color(hex: "3b4252"),
        textPrimary: Color(hex: "eceff4"),
        textSecondary: Color(hex: "4c566a"),
        isDark: true
    )

    static let solarized = AppTheme(
        id: "solarized",
        displayName: "Solarized",
        downloadColor: Color(hex: "268bd2"),
        uploadColor: Color(hex: "859900"),
        backgroundColor: Color(hex: "002b36"),
        cardColor: Color(hex: "073642"),
        textPrimary: Color(hex: "839496"),
        textSecondary: Color(hex: "586e75"),
        isDark: true
    )

    static let all: [AppTheme] = [.system, .dracula, .nord, .solarized]

    static func named(_ id: String) -> AppTheme {
        all.first { $0.id == id } ?? .system
    }
}

// MARK: - Environment key

struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .system
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
