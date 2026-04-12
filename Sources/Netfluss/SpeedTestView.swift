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
import WebKit

struct SpeedTestView: View {
    static let minimumWindowWidth: CGFloat = 860
    static let preferredWindowWidth: CGFloat = 1040
    static let preferredWindowHeight: CGFloat = 760
    static let minimumWindowHeight: CGFloat = 560
    private static let headerActionButtonWidth: CGFloat = 120

    @EnvironmentObject private var manager: SpeedTestManager
    @AppStorage("speedTestProvider") private var speedTestProviderRaw: String = SpeedTestProvider.mlab.rawValue
    @State private var editingNoteResult: SpeedTestResult?

    private let uniformInfoCardHeight: CGFloat = 188

    private var selectedProvider: SpeedTestProvider {
        SpeedTestProvider(rawValue: speedTestProviderRaw) ?? .mlab
    }

    private var displayedProvider: SpeedTestProvider {
        if manager.startedAt != nil || manager.phase != .idle || manager.result != nil || manager.lastErrorMessage != nil || manager.isAwaitingMLabConsent {
            return manager.activeProvider
        }
        return selectedProvider
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ViewThatFits(in: .vertical) {
                mainContent
                ScrollView {
                    mainContent
                }
            }
        }
        .background(AppTheme.system.backgroundColor ?? Color(NSColor.windowBackgroundColor))
        .frame(minWidth: Self.minimumWindowWidth)
        .sheet(
            isPresented: Binding(
                get: { manager.isHistoryPresented },
                set: { isPresented in
                    if isPresented {
                        manager.presentHistory()
                    } else {
                        manager.dismissHistory()
                    }
                }
            )
        ) {
            SpeedTestHistorySheet()
                .environmentObject(manager)
        }
        .sheet(item: $editingNoteResult) { result in
            SpeedTestNoteEditorSheet(
                result: result,
                currentNote: manager.note(for: result.id),
                onSave: { note in
                    manager.updateNote(note, for: result.id)
                    editingNoteResult = nil
                },
                onCancel: {
                    editingNoteResult = nil
                }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if manager.phase.isRunning {
                SpeedTestRuntimeHost(webView: manager.runtimeWebView)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 18) {
            heroCard
            if manager.isAwaitingMLabConsent {
                consentCard
            } else {
                resultCards
            }
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speed Test")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(displayedProvider.runtimeDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            Spacer()

            HStack(alignment: .top, spacing: 12) {
                Picker("Provider", selection: $speedTestProviderRaw) {
                    ForEach(SpeedTestProvider.allCases) { provider in
                        Text(provider.preferenceLabel)
                            .tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 210)
                .disabled(manager.phase.isRunning)

                VStack(alignment: .trailing, spacing: 8) {
                    if manager.phase.isRunning {
                        Button("Cancel") {
                            manager.cancel()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(runButtonTitle) {
                            manager.startWithSelectedProvider()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(width: Self.headerActionButtonWidth)
                    }

                    Button("History") {
                        manager.presentHistory()
                    }
                    .buttonStyle(.bordered)
                    .frame(width: Self.headerActionButtonWidth)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.phase.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(manager.phaseDetail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if let serverLine = serverLine {
                        Label(serverLine, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let finishedAt = manager.finishedAt {
                        Text("Finished \(timestamp(finishedAt))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if let startedAt = manager.startedAt {
                        Text("Started \(timestamp(startedAt))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 14) {
                liveMetricCard(
                    title: "Download",
                    value: speedLabel(manager.result?.downloadMbps ?? manager.currentDownloadMbps),
                    color: statisticsDownloadColor
                )
                liveMetricCard(
                    title: "Upload",
                    value: speedLabel(manager.result?.uploadMbps ?? manager.currentUploadMbps),
                    color: statisticsUploadColor
                )
                liveMetricCard(
                    title: "Latency",
                    value: latencyLabel(manager.result?.latencyMs ?? manager.currentLatencyMs),
                    color: .secondary
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progressValue)
                    .tint(progressColor)
                HStack {
                    providerBadge(displayedProvider)
                    Spacer()
                    Text(displayedProvider.shortDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            statisticsDownloadColor.opacity(0.10),
                            statisticsUploadColor.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var resultCards: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                infoCard(
                    title: "Connection Details",
                    icon: "network.badge.shield.half.filled",
                    tint: .accentColor,
                    fixedHeight: uniformInfoCardHeight
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        detailRow("Provider", displayedProvider.displayName)
                        if let serverLine {
                            detailRow("Server", serverLine)
                        } else {
                            detailRow("Server", "Waiting for a server selection")
                        }
                        detailRow("Started", manager.startedAt.map(timestamp) ?? "Not started")
                        detailRow("Finished", manager.finishedAt.map(timestamp) ?? "In progress")
                    }
                }

                infoCard(
                    title: "Notes",
                    icon: "text.bubble",
                    tint: .orange,
                    fixedHeight: uniformInfoCardHeight
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayedProvider.runtimeDescription)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        if displayedProvider == .mlab {
                            Text("M-Lab keeps results public, so NetFluss stores your consent once before the first test.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Cloudflare measures against nearby Cloudflare edge locations, so results can differ from broader Internet-path tests.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error = manager.lastErrorMessage {
                infoCard(
                    title: "Error",
                    icon: "exclamationmark.triangle.fill",
                    tint: .red
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            manager.startWithSelectedProvider()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else if let result = manager.result {
                HStack(alignment: .top, spacing: 18) {
                    infoCard(
                        title: "Final Result",
                        icon: "gauge.with.needle",
                        tint: progressColor,
                        fixedHeight: uniformInfoCardHeight
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            detailRow("Download", speedLabel(result.downloadMbps))
                            detailRow("Upload", speedLabel(result.uploadMbps))
                            detailRow("Latency", latencyLabel(result.latencyMs))
                            detailRow("Jitter", latencyLabel(result.jitterMs))
                        }
                    }

                    infoCard(
                        title: "Remember This Test",
                        icon: "square.and.pencil",
                        tint: .green,
                        fixedHeight: uniformInfoCardHeight
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add a short note so you can remember exactly where you took this measurement later.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            if let note = noteSummary(for: result), !note.isEmpty {
                                Text(note)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                            }
                            Button(result.note?.isEmpty == false ? "Edit Note" : "Add Note") {
                                editingNoteResult = result
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } else if !manager.isAwaitingMLabConsent {
                Color.clear
                    .frame(height: uniformInfoCardHeight)
            }
        }
    }

    private var consentCard: some View {
        infoCard(
            title: "M-Lab Consent",
            icon: "hand.raised.fill",
            tint: .orange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("M-Lab publishes measurement data publicly, including your public IP address. NetFluss needs your consent before running the first M-Lab speed test.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Continue with M-Lab") {
                        manager.acceptMLabPolicyAndStart()
                    }
                    .buttonStyle(.borderedProminent)

                    Link("Review M-Lab privacy policy", destination: URL(string: "https://www.measurementlab.net/privacy/")!)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
    }

    private func providerBadge(_ provider: SpeedTestProvider) -> some View {
        Text(provider.displayName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
    }

    private func liveMetricCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    @ViewBuilder
    private func infoCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        fixedHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let fixedHeight {
            cardShell(title: title, icon: icon, tint: tint, content: content)
                .frame(maxWidth: .infinity, minHeight: fixedHeight, maxHeight: fixedHeight, alignment: .topLeading)
                .background(cardBackground)
                .overlay(cardOverlay)
        } else {
            cardShell(title: title, icon: icon, tint: tint, content: content)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(cardBackground)
                .overlay(cardOverlay)
        }
    }

    private func cardShell<Content: View>(title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.primary.opacity(0.04))
    }

    private var cardOverlay: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var serverLine: String? {
        let liveName = manager.result?.serverName ?? manager.serverName
        let liveLocation = manager.result?.serverLocation ?? manager.serverLocation

        switch (liveName, liveLocation) {
        case let (name?, location?) where !name.isEmpty && !location.isEmpty:
            return "\(name) • \(location)"
        case let (name?, _) where !name.isEmpty:
            return name
        case let (_, location?) where !location.isEmpty:
            return location
        default:
            return nil
        }
    }

    private var progressValue: Double {
        switch manager.phase {
        case .idle, .consentRequired, .cancelled, .failed:
            return 0
        case .preparing:
            return 0.08
        case .discoveringServer:
            return 0.20
        case .testingLatency:
            return 0.34
        case .testingDownload:
            return 0.62
        case .testingUpload:
            return 0.86
        case .finalizing:
            return 0.96
        case .completed:
            return 1
        }
    }

    private var progressColor: Color {
        switch manager.phase {
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case .testingUpload:
            return statisticsUploadColor
        default:
            return statisticsDownloadColor
        }
    }

    private func speedLabel(_ value: Double?) -> String {
        RateFormatter.formatMbps(value)
    }

    private func latencyLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 10 {
            return String(format: "%.1f ms", value)
        }
        return String(format: "%.0f ms", value)
    }

    private var runButtonTitle: String {
        if manager.result != nil || manager.finishedAt != nil || manager.lastErrorMessage != nil {
            return "Run Again"
        }
        return "Run Test"
    }

    private func noteSummary(for result: SpeedTestResult) -> String? {
        let note = manager.note(for: result.id).trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var statisticsDownloadColor: Color {
        statisticsAccentColor(
            selectionKey: "downloadColor",
            customHexKey: "downloadColorHex",
            defaultSelection: "blue",
            fallback: .systemBlue
        )
    }

    private var statisticsUploadColor: Color {
        statisticsAccentColor(
            selectionKey: "uploadColor",
            customHexKey: "uploadColorHex",
            defaultSelection: "green",
            fallback: .systemOrange
        )
    }

    private func statisticsAccentColor(
        selectionKey: String,
        customHexKey: String,
        defaultSelection: String,
        fallback: NSColor
    ) -> Color {
        let selection = UserDefaults.standard.string(forKey: selectionKey) ?? defaultSelection
        let customHex = UserDefaults.standard.string(forKey: customHexKey) ?? ""
        let resolved = resolvedAccentNSColor(selection: selection, customHex: customHex, fallback: fallback)
        guard let rgb = resolved.usingColorSpace(.deviceRGB) else {
            return Color(nsColor: fallback)
        }

        let luminance = (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
        if luminance > 0.92 {
            return Color(nsColor: fallback)
        }

        return Color(nsColor: resolved)
    }
}

private struct SpeedTestRuntimeHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        attachWebView(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachWebView(to: nsView)
        webView.frame = nsView.bounds
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        if let window = nsView.window, window.firstResponder === nsView.subviews.first {
            window.makeFirstResponder(nil)
        }
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attachWebView(to container: NSView) {
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }
}

private struct SpeedTestHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var manager: SpeedTestManager
    @State private var editingNoteResult: SpeedTestResult?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speed Test History")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Recent results saved on this Mac. Add notes to remember the exact place.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            if manager.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No speed tests yet")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Run a speed test when you want and NetFluss will keep the recent results here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    historyHeader
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(manager.history) { result in
                                SpeedTestHistoryRow(result: result) {
                                    editingNoteResult = result
                                }
                                .environmentObject(manager)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 980, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(item: $editingNoteResult) { result in
            SpeedTestNoteEditorSheet(
                result: result,
                currentNote: manager.note(for: result.id),
                onSave: { note in
                    manager.updateNote(note, for: result.id)
                    editingNoteResult = nil
                },
                onCancel: {
                    editingNoteResult = nil
                }
            )
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 12) {
            Text("When")
                .frame(width: 150, alignment: .leading)
            Text("Provider")
                .frame(width: 96, alignment: .leading)
            Text("Download")
                .frame(width: 110, alignment: .trailing)
            Text("Upload")
                .frame(width: 110, alignment: .trailing)
            Text("Latency")
                .frame(width: 78, alignment: .trailing)
            Text("Note")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

private struct SpeedTestNoteEditorSheet: View {
    let result: SpeedTestResult
    let currentNote: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var noteText: String = ""
    @FocusState private var isNoteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Speed Test Note")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(contextLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Cafe X, back room, hotel Wi-Fi, coworking desk 4…", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .focused($isNoteFieldFocused)
                .onSubmit {
                    onSave(noteText)
                }
            HStack(spacing: 12) {
                Button("Clear") {
                    onSave("")
                }
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(noteText)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            noteText = currentNote
            DispatchQueue.main.async {
                isNoteFieldFocused = true
            }
        }
    }

    private var contextLine: String {
        let when = result.finishedAt.formatted(date: .numeric, time: .shortened)
        return "\(result.provider.displayName) • \(when)"
    }
}

private struct SpeedTestHistoryRow: View {
    @EnvironmentObject private var manager: SpeedTestManager

    let result: SpeedTestResult
    let onEditNote: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(compactTimestamp(result.finishedAt))
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(result.provider.displayName)
                .font(.system(size: 13))
                .frame(width: 96, alignment: .leading)
            Text(RateFormatter.formatMbps(result.downloadMbps))
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            Text(RateFormatter.formatMbps(result.uploadMbps))
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            Text(latencyLabel(result.latencyMs))
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 78, alignment: .trailing)
            Button {
                onEditNote()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.secondary)
                    Text(noteSummary ?? "Add note")
                        .font(.system(size: 13))
                        .foregroundStyle(noteSummary == nil ? .secondary : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private func latencyLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 10 {
            return String(format: "%.1f ms", value)
        }
        return String(format: "%.0f ms", value)
    }

    private func compactTimestamp(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }

    private var noteSummary: String? {
        let note = manager.note(for: result.id).trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }
}
