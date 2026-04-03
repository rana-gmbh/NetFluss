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

import SwiftUI
import AppKit

struct AboutView: View {
    @StateObject private var checker = UpdateChecker()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.12.1"
    }

    private var releaseNotesURL: URL {
        URL(string: "https://github.com/rana-gmbh/NetFluss/releases/tag/v\(version)")!
    }

    var body: some View {
        VStack(spacing: 0) {

            // App identity
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                Text("NetFluss")
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Text("Version \(version)")
                        .foregroundStyle(.secondary)
                    Button("Release Notes ↗") {
                        NSWorkspace.shared.open(releaseNotesURL)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Author
            VStack(spacing: 4) {
                Text("Made by Rana GmbH")
                    .font(.callout)
                Button("www.ranagmbh.de") {
                    NSWorkspace.shared.open(URL(string: "https://www.ranagmbh.de")!)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.callout)
            }
            .padding(.vertical, 16)

            Divider()

            // Support
            VStack(spacing: 4) {
                Text("If you want to support this project,")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text("please consider to ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Buy me a coffee ↗") {
                        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/robertrudolph")!)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                }
            }
            .padding(.vertical, 12)

            Divider()

            // License
            VStack(spacing: 4) {
                Text("Released under the")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("GNU General Public License v3.0 ↗") {
                    NSWorkspace.shared.open(URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.caption)
            }
            .padding(.vertical, 12)

            Divider()

            // Update section — fills remaining space so it stays centered in
            // idle state and has room for release notes when an update is found
            updateSection
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 300, height: 520)
    }

    @ViewBuilder
    private var updateSection: some View {
        switch checker.state {
        case .idle:
            Button("Check for Updates") {
                checker.check()
            }
            .buttonStyle(.borderedProminent)

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

        case .upToDate:
            VStack(spacing: 8) {
                Label("You're up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Button("Check Again") {
                    checker.check()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }

        case .available(let update):
            VStack(alignment: .leading, spacing: 10) {
                Label("NetFluss \(update.version) is available!", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity, alignment: .center)

                if !update.releaseNotes.isEmpty {
                    ScrollView {
                        Group {
                            if let attr = try? AttributedString(
                                markdown: update.releaseNotes,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            ) {
                                Text(attr)
                            } else {
                                Text(update.releaseNotes)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(2)
                    }
                    .frame(height: 80)
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    Button("Release Page ↗") {
                        NSWorkspace.shared.open(update.releasePageURL)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .font(.caption)

                    Spacer()

                    Button("Download") {
                        NSWorkspace.shared.open(update.downloadURL ?? update.releasePageURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

        case .failed(let message):
            VStack(spacing: 8) {
                Label("Could not check for updates", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    checker.check()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}
