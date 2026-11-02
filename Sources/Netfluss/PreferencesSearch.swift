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

/// Finds a setting across the Preferences panes, by what it says on screen.
enum PreferenceSearch {
    struct Entry: Identifiable, Equatable {
        let key: String
        let pane: PreferencePane

        init(_ key: String, _ pane: PreferencePane) {
            self.key = key
            self.pane = pane
        }

        var id: String { "\(pane.rawValue)|\(key)" }
    }

    static let maxResults = 40

    /// Every label and explanation in Preferences, by pane. Written out rather
    /// than collected from the views because a pane's views don't exist until it
    /// is opened. `PreferenceSearchTests` fails when a new setting is missing here.
    static let entries: [Entry] = [
        Entry("Launch", .general),
        Entry("System access", .general),
        Entry("Language", .general),
        Entry("System Default follows the language selected in macOS.", .general),
        Entry("Display rates in bits per second", .general),
        Entry("Units", .general),
        Entry("Refresh interval", .general),
        Entry("Refresh", .general),
        Entry("Check for updates automatically", .general),
        Entry("Once a day, NetFluss looks for a new version on GitHub and asks whether to download and install it. You can also check any time from the menu bar icon's right-click menu or in About.", .general),
        Entry("Update", .general),
        Entry("Look up public IP addresses and countries", .general),
        Entry("Asks ipify and ipwho.is for your public IP address and its country, and api.country.is for the countries in Network Slice. With this off, NetFluss shows no external IP, country or flag.", .general),
        Entry("Privacy", .general),
        Entry("Launch at login", .general),
        Entry("macOS is waiting for you to allow NetFluss under System Settings → General → Login Items & Extensions.", .general),
        Entry("Open Login Items…", .general),
        Entry("macOS only opens NetFluss at login when it runs from the Applications folder. Move it there and open it again.", .general),
        Entry("Required to list nearby Wi-Fi networks. macOS uses the same gate for its own Wi-Fi menu.", .general),
        Entry("Used to change DNS servers and to persist new Wi-Fi credentials into macOS's Known Networks. macOS may show a \"Background Items Added\" approval prompt the first time.", .general),
        Entry("Show inactive adapters", .adapters),
        Entry("Show other adapters (VPN, virtual)", .adapters),
        Entry("Hide adapters after inactivity", .adapters),
        Entry("Hide after", .adapters),
        Entry("Adapter Visibility", .adapters),
        Entry("No adapters match current filters.", .adapters),
        Entry("Only include visible adapters in totals", .adapters),
        Entry("Exclude VPN/tunnel adapters from totals", .adapters),
        Entry("When enabled, the Download/Upload summary and menu bar use only adapters that are visible here.", .adapters),
        Entry("When enabled, VPN/tunnel adapters (utun, tun, tap, ipsec, ppp) are excluded from totals. Loopback and AirDrop are always excluded, since they never carry internet traffic. All adapters remain visible in the adapter list.", .adapters),
        Entry("Adapters", .adapters),
        Entry("Collect historical statistics", .statistics),
        Entry("Disabled by default to avoid extra background work and energy use. When enabled, NetFluss keeps hourly and daily rollups for adapters and optional app traffic analysis.", .statistics),
        Entry("Display usage summary on popover", .statistics),
        Entry("Shows today's and this month's upload, download, and total data in the popover. Requires historical statistics collection.", .statistics),
        Entry("Collect app statistics", .statistics),
        Entry("App statistics are on by default and may increase energy consumption because NetFluss periodically samples per-app network usage in the background.", .statistics),
        Entry("Collect proxy node statistics", .statistics),
        Entry("Records how much traffic each outbound node carried, for clients that expose the Clash API — sing-box, mihomo, Clash Verge and others. Useful with a metered subscription.", .statistics),
        Entry("Statistics", .statistics),
        Entry("(default)", .statistics),
        Entry("Controller address", .statistics),
        Entry("Configured", .statistics),
        Entry("None", .statistics),
        Entry("Controller secret", .statistics),
        Entry("Test connection", .statistics),
        Entry("The Clash API is off unless your client sets external-controller. In sing-box that is experimental.clash_api.external_controller in the config; most GUI clients enable it on 127.0.0.1:9090 already.", .statistics),
        Entry("Upload arrow ↑", .appearance),
        Entry("Download arrow ↓", .appearance),
        Entry("Upload number ↑", .appearance),
        Entry("Download number ↓", .appearance),
        Entry("Standard", .appearance),
        Entry("Unified pill", .appearance),
        Entry("Dashboard", .appearance),
        Entry("Dashboard (basic)", .appearance),
        Entry("Icon", .appearance),
        Entry("Menu bar icon style", .appearance),
        Entry("Menu bar icon", .appearance),
        Entry("Menu bar size", .appearance),
        Entry("Monospaced", .appearance),
        Entry("System", .appearance),
        Entry("Rounded", .appearance),
        Entry("Menu bar font", .appearance),
        Entry("Centered", .appearance),
        Entry("Left", .appearance),
        Entry("Right", .appearance),
        Entry("Rate alignment", .appearance),
        Entry("Left and Right keep the arrows in place while the numbers change. Right also lines the numbers up like a column.", .appearance),
        Entry("Auto", .appearance),
        Entry("Menu bar unit", .appearance),
        Entry("Decimals", .appearance),
        Entry("Off", .appearance),
        Entry("Dot", .appearance),
        Entry("Shield", .appearance),
        Entry("VPN indicator", .appearance),
        Entry("VPN indicator color", .appearance),
        Entry("Show when VPN is off", .appearance),
        Entry("Link indicator", .appearance),
        Entry("A Wi-Fi or cable symbol right of the rates, in the colour of the connection's state: connected, connected without internet, or not connected. The symbol follows whichever interface carries the traffic.", .appearance),
        Entry("Indicator size", .appearance),
        Entry("Resolver name colour", .appearance),
        Entry("Country flag", .appearance),
        Entry("Show flag only while a VPN is active", .appearance),
        Entry("Shown to the right of the rates. The VPN indicator also detects VPNs started by other apps. The country flag shows where your public IP is located (looked up via ipify.org and ipwho.is).", .appearance),
        Entry("Dashboard uses router-wide traffic when Fritz!Box, UniFi, OpenWRT, or OPNsense bandwidth is enabled and available.", .appearance),
        Entry("Appearance", .appearance),
        Entry("List", .appearance),
        Entry("Flow", .appearance),
        Entry("None", .appearance),
        Entry("IP display", .appearance),
        Entry("External IP", .appearance),
        Entry("IP addresses", .appearance),
        Entry("Drag to reorder sections in the popover. Toggling a row mirrors the corresponding pref in DNS, Wi-Fi, Router, or Top Apps panels.", .appearance),
        Entry("Popover sections", .appearance),
        Entry("Connected", .appearance),
        Entry("No internet", .appearance),
        Entry("Not connected", .appearance),
        Entry("Check internet access", .appearance),
        Entry("Without this check the symbol only reports whether the interface is up. With it, NetFluss asks Apple's captive-portal address — the one macOS itself uses — often enough to notice a hotel login page or a dead upstream, and rarely enough to cost nothing.", .appearance),
        Entry("Check address", .appearance),
        Entry("Show top apps by network usage", .topApps),
        Entry("Shows the top 5 processes ranked by current network traffic.", .topApps),
        Entry("Keep apps visible after traffic stops", .topApps),
        Entry("Visible for", .topApps),
        Entry("Top Apps", .topApps),
        Entry("Show DNS switcher in popover", .dns),
        Entry("DNS changes and Ethernet reconnects install a privileged helper the first time. macOS may ask for administrator approval and, on some systems, additional approval in System Settings.", .dns),
        Entry("DNS Switcher", .dns),
        Entry("Switch DNS automatically by network", .dns),
        Entry("Picks a resolver from the Wi-Fi network you join — one for home, another for public networks. Needs the privileged helper, otherwise every switch would ask for your password.", .dns),
        Entry("Automatic DNS", .dns),
        Entry("Add current network", .dns),
        Entry("No Wi-Fi network name is available. Join a Wi-Fi network, or allow Location access below — macOS withholds the network name without it.", .dns),
        Entry("Leave unchanged", .dns),
        Entry("Any other network", .dns),
        Entry("Applied on networks without a rule of their own, including wired ones. This is what stops a public resolver following you home.", .dns),
        Entry("Show active resolver in menu bar", .dns),
        Entry("Appears only while the resolver is not the system default, so the menu bar stays quiet on a network you have not overridden.", .dns),
        Entry("Show Wi-Fi networks in popover", .wifi),
        Entry("Lists nearby Wi-Fi networks from the system's cached scan. Tap a row to join — saved networks reconnect immediately, new secured networks prompt for a password.", .wifi),
        Entry("Only show the strongest networks", .wifi),
        Entry("Maximum networks shown", .wifi),
        Entry("Pinned networks and the currently-connected network always appear regardless of this limit.", .wifi),
        Entry("Wi-Fi Switcher", .wifi),
        Entry("Show VPN in popover", .vpn),
        Entry("Import OpenVPN profile…", .vpn),
        Entry("Import WireGuard profile…", .vpn),
        Entry("Import a single config file, or a folder or .zip of them (e.g. a provider's router profiles). Each config becomes a selectable server.", .vpn),
        Entry("VPN", .vpn),
        Entry("No system VPNs found. Configure one in System Settings → VPN, or install a provider configuration profile below.", .vpn),
        Entry("Add system VPN…", .vpn),
        Entry("Add IKEv2 VPN…", .vpn),
        Entry("Install configuration profile (.mobileconfig)…", .vpn),
        Entry("Refresh system VPNs", .vpn),
        Entry("System VPN (IKEv2 / IPsec / L2TP)", .vpn),
        Entry("Copy VPN diagnostics", .vpn),
        Entry("Reveal VPN log in Finder", .vpn),
        Entry("Clear VPN log", .vpn),
        Entry("Copied to clipboard.", .vpn),
        Entry("If a VPN connection fails, copy this log and send it — it records the bundled tools, their architecture, and the connection tool's full output.", .vpn),
        Entry("VPN Diagnostics", .vpn),
        Entry("Profiles", .vpn),
        Entry("Show Fritz!Box bandwidth in popover", .router),
        Entry("(auto)", .router),
        Entry("Router address", .router),
        Entry("Queries your Fritz!Box via TR-064 (no authentication needed for bandwidth data). Auto uses the current default gateway. Set a fixed address if your Fritz!Box is reachable at a different IP. Port 49000 must be reachable.", .router),
        Entry("Fritz!Box Bandwidth", .router),
        Entry("Show UniFi bandwidth in popover", .router),
        Entry("Local admin", .router),
        Entry("API key", .router),
        Entry("Authentication", .router),
        Entry("Configured", .router),
        Entry("Not set", .router),
        Entry("Queries your UniFi gateway via its local API (HTTPS) using a Network API key. Create one in the UniFi Network app under Settings → Control Plane → Integrations. API keys work with 2FA enabled and never expire.", .router),
        Entry("Queries your UniFi gateway via its local API (HTTPS). Requires a local admin account on the UniFi controller. If the account has 2FA enabled, use an API key instead — password login cannot complete a 2FA challenge.", .router),
        Entry("UniFi Bandwidth", .router),
        Entry("Show OpenWRT bandwidth in popover", .router),
        Entry("Credentials", .router),
        Entry("Queries your OpenWRT router via ubus JSON-RPC over HTTPS. Auto uses the current default gateway, which may be the wrong router on dual-router setups. Set a fixed OpenWRT IP or URL if needed — for plain HTTP, enter http://<IP>. Requires the router's admin credentials and the uhttpd-mod-ubus package.", .router),
        Entry("OpenWRT Bandwidth", .router),
        Entry("Show OPNsense bandwidth in popover", .router),
        Entry("API Credentials", .router),
        Entry("Queries your OPNsense router via its REST API over HTTPS. Auto uses the current default gateway. If the web interface uses plain HTTP or a different port, enter the full URL (e.g. http://192.168.1.1 or https://192.168.1.1:8443). Requires an API key and secret configured in OPNsense.", .router),
        Entry("OPNsense Bandwidth", .router),
    ]

    /// Entries containing every word of `query`, in either the current language
    /// or English, labels ahead of the longer explanations.
    static func matches(
        for query: String,
        in entries: [Entry] = entries,
        localized: (String) -> String = L10n.text
    ) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        func contains(_ text: String, _ word: String) -> Bool {
            text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        let found = entries.compactMap { entry -> (entry: Entry, length: Int)? in
            let text = localized(entry.key)
            guard words.allSatisfy({ contains(text, $0) || contains(entry.key, $0) }) else { return nil }
            return (entry, text.count)
        }
        return Array(found.sorted { $0.length < $1.length }.prefix(maxResults).map(\.entry))
    }
}

/// Covers the current pane while a search is running.
struct PreferenceSearchResults: View {
    let query: String
    let onSelect: (PreferencePane) -> Void

    var body: some View {
        let results = PreferenceSearch.matches(for: query)
        Group {
            if results.isEmpty {
                LText("No matching settings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { entry in
                    Button {
                        onSelect(entry.pane)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(L10n.text(entry.key))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(L10n.text(entry.pane.title))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
