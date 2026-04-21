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

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .system:
            return "System Default"
        case .english:
            return "English"
        case .german:
            return "Deutsch"
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english, .german, .simplifiedChinese, .traditionalChinese:
            return Locale(identifier: rawValue)
        }
    }

    var bundle: Bundle {
        switch self {
        case .system:
            return .main
        case .english, .german, .simplifiedChinese, .traditionalChinese:
            guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path)
            else { return .main }
            return bundle
        }
    }

    static func current(from rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }

    static var selected: AppLanguage {
        current(from: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue)
    }
}

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: AppLanguage.selected.bundle, comment: "")
    }
}

struct LocalizedRoot<Content: View>: View {
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.system.rawValue
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let language = AppLanguage.current(from: appLanguage)
        content
            .environment(\.locale, language.locale)
            .id(appLanguage)
    }
}
