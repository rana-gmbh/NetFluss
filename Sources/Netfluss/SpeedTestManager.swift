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
import WebKit

@MainActor
final class SpeedTestManager: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var activeProvider: SpeedTestProvider = .mlab
    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var phaseDetail = "Choose a provider and run a speed test when you want."
    @Published private(set) var currentDownloadMbps: Double?
    @Published private(set) var currentUploadMbps: Double?
    @Published private(set) var currentLatencyMs: Double?
    @Published private(set) var currentJitterMs: Double?
    @Published private(set) var serverName: String?
    @Published private(set) var serverLocation: String?
    @Published private(set) var result: SpeedTestResult?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isAwaitingMLabConsent = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var history: [SpeedTestResult]
    @Published var isHistoryPresented = false

    private struct PendingRun {
        let runID: Int
        let provider: SpeedTestProvider
        let pageURL: URL
        let launchScript: String
    }

    private enum BridgeMessage: String {
        case phase
        case progress
        case result
        case error
    }

    private let monitor: NetworkMonitor
    private let webView: WKWebView
    private let resourceServer: SpeedTestResourceServer?
    private var pendingRun: PendingRun?
    private var activeRunID = 0
    private let bridgeName = "speedTestBridge"
    private let maxHistoryCount = 30

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        self.history = Self.loadHistory(from: .standard, key: Self.historyKey)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.resourceServer = Self.resourcesBaseURL().map(SpeedTestResourceServer.init)

        super.init()

        userContentController.add(self, name: bridgeName)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    var monitoredNetwork: NetworkMonitor { monitor }
    var runtimeWebView: WKWebView { webView }
    var selectedProvider: SpeedTestProvider {
        SpeedTestProvider(rawValue: UserDefaults.standard.string(forKey: "speedTestProvider") ?? "") ?? .mlab
    }

    func startWithSelectedProvider() {
        isHistoryPresented = false
        start(provider: selectedProvider, bypassConsent: false)
    }

    func presentHistory() {
        isHistoryPresented = true
    }

    func dismissHistory() {
        isHistoryPresented = false
    }

    func note(for resultID: UUID) -> String {
        history.first(where: { $0.id == resultID })?.note ?? ""
    }

    func updateNote(_ note: String, for resultID: UUID) {
        guard let index = history.firstIndex(where: { $0.id == resultID }) else { return }

        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        guard history[index].note != normalizedNote else { return }

        history[index].note = normalizedNote
        if result?.id == resultID {
            result?.note = normalizedNote
        }
        persistHistory()
    }

    func acceptMLabPolicyAndStart() {
        UserDefaults.standard.set(true, forKey: "speedTestMLabConsentAccepted")
        start(provider: .mlab, bypassConsent: true)
    }

    func cancel() {
        let wasRunning = phase.isRunning || isAwaitingMLabConsent || pendingRun != nil
        pendingRun = nil
        activeRunID += 1
        loadBlankPage()

        guard wasRunning else { return }

        isAwaitingMLabConsent = false
        phase = .cancelled
        phaseDetail = "Speed test stopped."
        finishedAt = Date()
    }

    private func start(provider: SpeedTestProvider, bypassConsent: Bool) {
        activeProvider = provider
        lastErrorMessage = nil
        result = nil
        currentDownloadMbps = nil
        currentUploadMbps = nil
        currentLatencyMs = nil
        currentJitterMs = nil
        serverName = nil
        serverLocation = nil
        startedAt = nil
        finishedAt = nil

        if provider == .mlab && !bypassConsent && !UserDefaults.standard.bool(forKey: "speedTestMLabConsentAccepted") {
            isAwaitingMLabConsent = true
            phase = .consentRequired
            phaseDetail = "M-Lab publishes measurement data publicly, so NetFluss asks for consent before the first test."
            return
        }

        isAwaitingMLabConsent = false
        phase = .preparing
        phaseDetail = provider == .mlab ? "Preparing the M-Lab test..." : "Preparing the Cloudflare test..."
        startedAt = Date()
        finishedAt = nil
        activeRunID += 1

        let requestURL: URL
        do {
            requestURL = try pageURL(for: provider)
        } catch {
            finishWithError(error.localizedDescription)
            return
        }

        guard let launchScript = makeLaunchScript(runID: activeRunID) else {
            finishWithError("Could not prepare the speed test runtime.")
            return
        }

        pendingRun = PendingRun(
            runID: activeRunID,
            provider: provider,
            pageURL: requestURL,
            launchScript: launchScript
        )

        webView.stopLoading()
        webView.load(URLRequest(url: requestURL))
    }

    private func makeLaunchScript(runID: Int) -> String? {
        let payload: [String: Any] = [
            "runId": runID,
            "provider": activeProvider.rawValue,
            "clientName": "NetFluss",
            "clientVersion": Self.clientVersion
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return "window.NetFlussSpeedTest.start(\(json)); true;"
    }

    private func loadBlankPage() {
        webView.stopLoading()
        webView.loadHTMLString("<!DOCTYPE html><html><body></body></html>", baseURL: nil)
    }

    private func updateServer(from payload: [String: Any]) {
        if let name = payload["serverName"] as? String, !name.isEmpty {
            serverName = name
        }
        if let location = payload["serverLocation"] as? String, !location.isEmpty {
            serverLocation = location
        }
    }

    private func updateMetrics(from payload: [String: Any]) {
        if let value = doubleValue(payload["downloadMbps"]) {
            currentDownloadMbps = value
        }
        if let value = doubleValue(payload["uploadMbps"]) {
            currentUploadMbps = value
        }
        if let value = doubleValue(payload["latencyMs"]) {
            currentLatencyMs = value
        }
        if let value = doubleValue(payload["jitterMs"]) {
            currentJitterMs = value
        }
    }

    private func applyPhase(_ rawValue: String?, detail: String?) {
        switch rawValue {
        case "discoveringServer":
            phase = .discoveringServer
        case "latency":
            phase = .testingLatency
        case "download":
            phase = .testingDownload
        case "upload":
            phase = .testingUpload
        case "finalizing":
            phase = .finalizing
        default:
            break
        }

        if let detail, !detail.isEmpty {
            phaseDetail = detail
        }
    }

    private func handleResult(_ payload: [String: Any]) {
        updateServer(from: payload)
        updateMetrics(from: payload)

        let provider = SpeedTestProvider(rawValue: payload["provider"] as? String ?? "") ?? activeProvider
        let finishedAt = Date()
        self.finishedAt = finishedAt
        phase = .completed
        phaseDetail = "\(provider.displayName) speed test complete."
        lastErrorMessage = nil
        pendingRun = nil

        let nextResult = SpeedTestResult(
            provider: provider,
            startedAt: startedAt ?? finishedAt,
            finishedAt: finishedAt,
            downloadMbps: currentDownloadMbps,
            uploadMbps: currentUploadMbps,
            latencyMs: currentLatencyMs,
            jitterMs: currentJitterMs,
            serverName: serverName,
            serverLocation: serverLocation
        )
        result = nextResult
        appendToHistory(nextResult)

        activeRunID += 1
        loadBlankPage()
    }

    private func finishWithError(_ message: String) {
        pendingRun = nil
        finishedAt = Date()
        phase = .failed
        phaseDetail = message
        lastErrorMessage = message
        isAwaitingMLabConsent = false
        activeRunID += 1
        loadBlankPage()
    }

    private func pageURL(for provider: SpeedTestProvider) throws -> URL {
        let fileName = provider.rawValue == "mlab" ? "mlab.html" : "cloudflare.html"
        guard let resourceServer else {
            throw NSError(
                domain: "SpeedTestManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speed test resources are missing from the app bundle."]
            )
        }
        return try resourceServer.url(forRelativePath: fileName)
    }

    // Release builds load from the app bundle; `swift run` falls back to the checked-out repository.
    private static func resourcesBaseURL() -> URL? {
        let rootFromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packaging/Resources/SpeedTest", isDirectory: true)
        let rootFromCWD = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Packaging/Resources/SpeedTest", isDirectory: true)

        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("SpeedTest", isDirectory: true),
            rootFromCWD,
            rootFromSource
        ]

        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var clientVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
            return version
        }
        return "dev"
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func appendToHistory(_ result: SpeedTestResult) {
        history.insert(result, at: 0)
        if history.count > maxHistoryCount {
            history.removeLast(history.count - maxHistoryCount)
        }
        persistHistory()
    }

    private func persistHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    private static func loadHistory(from defaults: UserDefaults, key: String) -> [SpeedTestResult] {
        guard let data = defaults.data(forKey: key) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let history = try? decoder.decode([SpeedTestResult].self, from: data) else {
            return []
        }

        return history.sorted { $0.finishedAt > $1.finishedAt }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == bridgeName,
            let payload = message.body as? [String: Any],
            let runID = doubleValue(payload["runId"]).map(Int.init),
            runID == activeRunID,
            let messageType = BridgeMessage(rawValue: payload["type"] as? String ?? "")
        else {
            return
        }

        switch messageType {
        case .phase:
            updateServer(from: payload)
            applyPhase(payload["phase"] as? String, detail: payload["detail"] as? String)
        case .progress:
            updateServer(from: payload)
            updateMetrics(from: payload)
            applyPhase(payload["phase"] as? String, detail: payload["detail"] as? String)
        case .result:
            handleResult(payload)
        case .error:
            finishWithError(payload["message"] as? String ?? "The speed test failed.")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pendingRun else { return }

        webView.evaluateJavaScript(pendingRun.launchScript) { [weak self] _, error in
            guard let self else { return }
            guard pendingRun.runID == self.activeRunID else { return }

            if let error {
                self.finishWithError("Could not start the \(pendingRun.provider.displayName) speed test: \(error.localizedDescription)")
                return
            }

            self.pendingRun = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard pendingRun != nil else { return }
        finishWithError("Could not load the speed test page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard pendingRun != nil else { return }
        finishWithError("Could not load the speed test page: \(error.localizedDescription)")
    }

    private static let historyKey = "speedTestHistory"
}
