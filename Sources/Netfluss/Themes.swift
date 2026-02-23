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
