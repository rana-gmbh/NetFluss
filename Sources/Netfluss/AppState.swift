import Foundation

@MainActor
final class AppState: ObservableObject {
    let monitor: NetworkMonitor
    let statusBar: StatusBarController

    init() {
        UserDefaults.standard.register(defaults: [
            "refreshInterval": 1.0,
            "showInactive": false,
            "showOtherAdapters": false,
            "useBits": false,
            "hiddenAdapters": [],
            "showTopApps": false,
            "uploadColor": "green",
            "downloadColor": "blue"
        ])
        let monitor = NetworkMonitor()
        self.monitor = monitor
        self.statusBar = StatusBarController(monitor: monitor)
    }
}
