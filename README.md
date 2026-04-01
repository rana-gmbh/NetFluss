# NetFluss

[![GitHub release](https://img.shields.io/github/v/release/rana-gmbh/NetFluss)](https://github.com/rana-gmbh/NetFluss/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/rana-gmbh/NetFluss/total)](https://github.com/rana-gmbh/NetFluss/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A minimal macOS menubar app showing real-time upload and download rates across all active network adapters. Now with Fritz!Box, UniFi, and OpenWRT router bandwidth monitoring.

Latest release: **NetFluss 1.12**

<p align="center">
  <img src="screenshot.png" width="420" alt="NetFluss screenshot">
</p>

## Features

### Menubar
- Live upload ↑ and download ↓ rates displayed in the menu bar
- Four menu bar icon styles: Standard, Unified pill, Dashboard, and Icon
- Separate color choices for upload arrow, download arrow, upload number, and download number
- Monospaced digits for stable layout
- Configurable font size (8–16 pt) and font style (Monospaced / System / Rounded)
- **Pinned unit** — lock the display to KB/s, MB/s, or GB/s (bits or bytes) instead of auto-scaling
- **Decimal places** — choose 0, 1, 2, or 3 fixed decimals, or auto
- **Icon mode** — switch to a single symbol in the menu bar and choose between multiple icon options
- **Launch at login** — toggle in Preferences → Launch

### Popover
- **Header** — total Download and Upload rates shown prominently at the top
- **Adapter cards** — each active network interface as a card with:
  - SF Symbol icon for Wi-Fi, Ethernet, or other adapters
  - Link speed badge (Wi-Fi TX rate or Ethernet speed)
  - Per-card DL/UL rates with coloured arrows
  - Wi-Fi frequency band (2.4 GHz / 5 GHz / 6 GHz) or "Ethernet"
  - ↺ reconnect button — cycles the adapter off and back on (Wi-Fi: no password needed; Ethernet: macOS admin dialog)
  - ℹ️ **Wi-Fi detail popover** — click the (i) button on any Wi-Fi card to see: Standard (e.g. Wi-Fi 6 / 802.11ax), Security (WPA3 Personal, etc.), Channel & Width, RSSI, Noise, SNR, ESSID, BSSID (with copy), and Tx Rate
- **IP addresses** — two display modes:
  - **List view** — External, Internal, and Router IP, each with a one-click copy button
  - **Connection flow view** — visual network path from your Mac through the router (and VPN, if active) to the internet, with country flag for VPN exit nodes
- **DNS Switcher** — switch between DNS providers directly from the popover (enable in Preferences):
  - Built-in presets: System Default, Cloudflare, Google, Quad9, OpenDNS
  - Add your own custom DNS presets
  - Shows the currently active DNS with a green checkmark
  - One-click switching with **Touch ID** authentication (falls back to admin password when Touch ID is unavailable)
- **Fritz!Box Bandwidth** *(Experimental)* — shows total WAN download/upload rates from your Fritz!Box router via TR-064 API, with progress bars relative to your line speed (enable in Preferences)
- **UniFi Bandwidth** *(Experimental)* — shows WAN download/upload rates from UniFi gateways (UDM, USG, UXG) via the UniFi OS REST API; credentials stored in macOS Keychain (enable in Preferences)
- **OpenWRT Bandwidth** *(Experimental)* — shows WAN download/upload rates from OpenWRT routers via the ubus JSON-RPC API; credentials stored in macOS Keychain (enable in Preferences)
- **Scrollable popover** — the popover is now scrollable and resizable for smaller screens, preventing overflow when many adapters or sections are active
- **Top Apps** — optional section listing the top 5 processes by current network traffic, with a relative usage bar per app (enable in Preferences)
  - **App filtering** — hide noisy background processes (e.g. mDNSResponder) from the list via Preferences or hover to hide directly
- **Footer** — quick access to Preferences, About, and Quit

### Preferences
- Refresh interval (0.5 – 5 seconds)
- Optional automatic GitHub update checks once per day, with the manual About check still available
- Show/hide inactive adapters
- Show/hide other adapters (VPN, virtual interfaces)
- **Adapter grace period** — keep adapters visible for 3 s, 5 s, or 10 s after they go idle, so brief inactivity doesn't make cards flicker
- Per-adapter visibility toggles, custom names (pencil button), and drag-to-reorder (≡ handle) — order and names are reflected in the popover
- Adapter list scrolls when more than 6 interfaces are shown
- Option to exclude hidden adapters from the total bandwidth shown in the header and menu bar
- Display rates in bits or bytes
- Upload / Download arrow colours plus separate upload / download number colours
- **Menu bar icon style** — Standard, Unified pill, Dashboard, or Icon
- Menu bar font size (8–16 pt stepper) and font style (Monospaced / System / Rounded)
- **Pinned unit** — lock menu bar rates to KB/s, MB/s, or GB/s instead of auto-scaling
- **Decimal places** — choose 0, 1, 2, or 3 fixed decimals for menu bar rates
- **Connection status mode** — choose between the classic IP list or the new connection flow view
- Top Apps toggle
- **Top Apps grace period** — keep apps visible for 3 s, 5 s, or 10 s after their traffic stops, preventing the list from constantly reshuffling
- **App filtering** — hide specific apps from the Top Apps list; "Apps to Hide" shows all recently active processes for easy selection
- **DNS Switcher** — toggle to show the DNS picker in the popover; includes built-in presets (System Default, Cloudflare, Google, Quad9, OpenDNS) plus custom presets with edit support; visibility toggles, drag-to-reorder, and delete for each preset
- **Fritz!Box Bandwidth** *(Experimental)* — toggle to show total WAN bandwidth from your Fritz!Box router; configurable router address (auto-detected from gateway, fallback: fritz.box); queries TR-064 API on port 49000 (no authentication required)
- **UniFi Bandwidth** *(Experimental)* — toggle to show WAN bandwidth from UniFi gateways; configurable host; credentials stored securely in macOS Keychain; supports UniFi OS (UDM) and legacy controller
- **OpenWRT Bandwidth** *(Experimental)* — toggle to show WAN bandwidth from OpenWRT routers; configurable host; credentials stored securely in macOS Keychain; uses ubus JSON-RPC API with automatic session management
- **Touch ID** — use Touch ID for DNS changes and Ethernet reconnects (enabled by default, configurable in DNS Switcher section)
- **Resizable preferences window** — drag edges to resize for smaller screens (note: resize cursor may not be visible due to a macOS/SwiftUI limitation)
- **Launch at login** toggle

### About
- Version number with link to release notes on GitHub
- Made by Rana GmbH — www.ranagmbh.de
- If you want to support this project directly, please use https://buymeacoffee.com/robertrudolph
- Check for Updates — queries GitHub Releases, shows release notes and a Download button when a newer version is found
- Optional daily background update checks with a direct link to the newest release page

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ or Swift 5.9+ toolchain (to build from source)

## Install

Download `NetFluss-1.12.zip` from the [latest release](https://github.com/rana-gmbh/NetFluss/releases/latest), unzip, and move `NetFluss.app` to `/Applications`.

NetFluss is notarized and signed with a Developer ID — Gatekeeper will clear it automatically on first launch.

You can also use Homebrew to install NetFluss: 
```bash
brew install --cask rana-gmbh/netfluss/netfluss  
```

## Build from source

```bash
swift build -c release
```

Or open `Package.swift` in Xcode and run the executable scheme.

## Notes

- Wi-Fi SSID and band use CoreWLAN. macOS may prompt for Location Services permission to expose SSID details.
- Ethernet link speed is read from `ifi_baudrate` and may show `—` when unavailable.
- External IP is fetched from `ipwho.is` (with `api.ipify.org` as fallback) and cached for 60 seconds.
- Top Apps reads per-connection byte counts from `netstat -n -b -v` and correlates them with process names via `proc_pidpath`. Only processes with active TCP/UDP connections appear in the list.

## Buy me a coffee

If you enjoy using NetFluss please consider supporting the project via this link: https://buymeacoffee.com/robertrudolph

## License

NetFluss is released under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 Rana GmbH
