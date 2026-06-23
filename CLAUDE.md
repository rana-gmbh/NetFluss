# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
swift build -c release                                    # arm64 only (fast, for local testing)
swift build -c release --arch arm64 --arch x86_64        # universal binary (for releases)
```

No Xcode project — SPM only (`Package.swift`). Minimum platform: macOS 13.

## Run for testing

Open `.build/release/Netfluss` directly or `swift run` (debug build). The app is a `LSUIElement` (menu-bar-only, no Dock icon).

Important: text input and focus can behave differently when running the raw binary (`.build/.../Netfluss`) versus a real bundled `Netfluss.app`. If typing does not work in text fields during local testing, verify the issue with a packaged `.app` before changing UI code.

## Manual release build (notarized zip)

The CI workflow (`.github/workflows/release.yml`) handles this automatically on tag push. To build locally:

```bash
swift build -c release --arch arm64 --arch x86_64
mkdir -p NetFluss.app/Contents/{MacOS,Resources,Library/HelperTools,Library/LaunchDaemons}
cp .build/apple/Products/Release/Netfluss NetFluss.app/Contents/MacOS/NetFluss
cp .build/apple/Products/Release/NetflussPrivilegedHelper NetFluss.app/Contents/Library/HelperTools/NetflussPrivilegedHelper
cp Packaging/Info.plist NetFluss.app/Contents/Info.plist
cp Packaging/LaunchDaemons/com.local.netfluss.privilegedhelper.plist \
  NetFluss.app/Contents/Library/LaunchDaemons/com.local.netfluss.privilegedhelper.plist
cp Packaging/Resources/AppIcon.icns NetFluss.app/Contents/Resources/AppIcon.icns
cp Packaging/Resources/AppIconDark.icns NetFluss.app/Contents/Resources/AppIconDark.icns
cp -R Packaging/Resources/SpeedTest NetFluss.app/Contents/Resources/SpeedTest
cp -R Packaging/Resources/*.lproj NetFluss.app/Contents/Resources/   # REQUIRED — see note below
# Bundle the OpenVPN binary + dylib closure for the VPN client (needs `brew install openvpn`).
# Signs the VPN Mach-Os itself. Produces a universal set when an Intel Homebrew with
# openvpn is present at /usr/local; otherwise arm64-only (VPN won't run on Intel).
# Intel openvpn must be built on/for the oldest supported macOS (CI Intel runner) — a
# from-source build on Apple Silicon/macOS 26 targets macOS 26 and won't run on Intel.
./Packaging/VPN/bundle-openvpn.sh NetFluss.app/Contents/Library/VPN "Developer ID Application: Rana GmbH (D6P24X5377)"
# WireGuard tools (needs `brew install wireguard-go wireguard-tools`). Bundles
# wireguard-go + wg + wg-quick + bash (wg-quick needs bash 4+) and their dylibs.
./Packaging/VPN/bundle-wireguard.sh NetFluss.app/Contents/Library/VPN "Developer ID Application: Rana GmbH (D6P24X5377)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.x.x" NetFluss.app/Contents/Info.plist
xattr -cr NetFluss.app   # strip resource-fork/Finder xattrs or codesign fails with "resource fork ... not allowed"
codesign --force --sign "Developer ID Application: Rana GmbH (D6P24X5377)" \
  --options=runtime --timestamp NetFluss.app/Contents/Library/HelperTools/NetflussPrivilegedHelper
codesign --force --sign "Developer ID Application: Rana GmbH (D6P24X5377)" \
  --options=runtime --timestamp --entitlements Netfluss.entitlements NetFluss.app
ditto -c -k --sequesterRsrc --keepParent NetFluss.app Netfluss-1.x.x.zip
xcrun notarytool submit Netfluss-1.x.x.zip --apple-id <id> --password <pwd> --team-id D6P24X5377 --wait
xcrun stapler staple NetFluss.app
```

Signing identity: `Developer ID Application: Rana GmbH (D6P24X5377)`
Team ID: `D6P24X5377`
Bundle ID: `com.local.netfluss`

**Do not skip the `*.lproj` copy.** `AppLanguage.bundle(for:)` in `Localization.swift` looks up `Localizable.strings` in `Bundle.main`; if the `.lproj` folders are missing from `Contents/Resources/` it falls back to `Bundle.module`, which traps at launch (`resource_bundle_accessor.swift: Fatal error: unable to find bundle named NetFluss_Netfluss`) because the SPM resource bundle is not shipped inside the `.app`. The app crashes on startup with no visible UI. The CI workflow (`release.yml`) already does this copy; the manual steps must match.

## Architecture

Netfluss is a pure-SwiftPM macOS menu bar app with no third-party dependencies.

### Startup sequence (important)

`AppDelegate.applicationDidFinishLaunching` → creates `AppState` → which creates `NetworkMonitor` then `StatusBarController`. **`AppState` must not be initialised before `applicationDidFinishLaunching`** — doing so (e.g. as a SwiftUI `@StateObject`) causes an NSCGSPanic/EXC_BAD_INSTRUCTION crash on Intel Macs (macOS 13) because `NSStatusBar.system.statusItem()` is called before the window-server connection exists.

### Key objects and their roles

| File | Role |
|---|---|
| `Netfluss.swift` | `@main` entry, `AppDelegate` wiring |
| `AppState.swift` | Owns `NetworkMonitor` + `StatusBarController`; registers all `UserDefaults` defaults |
| `NetworkMonitor.swift` | `@MainActor ObservableObject`; drives a `DispatchSourceTimer`; publishes `adapters`, `totals`, `topApps`, IP addresses, DNS state |
| `StatusBarController.swift` | Owns `NSStatusItem` + `NSPopover`; subscribes to `monitor.$totals` via Combine; handles menu bar label vs icon mode |
| `MenuBarView.swift` | SwiftUI popover content (header totals, adapter cards in a ScrollView capped at 6, IP section, DNS switcher, Top Apps) |
| `PreferencesView.swift` | SwiftUI `Form` inside an `NSWindow` managed by `PreferencesWindowController` |
| `Models.swift` | Value types: `AdapterStatus`, `RateTotals`, `AppTraffic`, `InterfaceSample`, `DNSPreset` |
| `Themes.swift` | `AppTheme` struct + Dracula/Nord/Solarized presets; `Color(hex:)` extension |
| `Formatters.swift` | `RateFormatter.formatRate()` — bits vs bytes, auto-scaling |
| `UpdateChecker.swift` | Queries GitHub Releases API; used by `AboutView` |

### Data flow

`DispatchSourceTimer` (main queue) → `NetworkMonitor.refresh()` every N seconds →
- `InterfaceSampler` (BSD `getifaddrs` + CoreWLAN) → updates `adapters` and `totals`
- `ProcessNetworkSampler` (`netstat -n -b -v`, async Task) → updates `topApps`
- `InterfaceSampler` (SCDynamicStore + `api.ipify.org`) → updates IP addresses

`StatusBarController` subscribes to `monitor.$totals` via Combine and calls `updateLabel()` on every tick.

`MenuBarView` and `PreferencesView` observe `monitor` as `@EnvironmentObject`.

Preferences changes are propagated via `UserDefaults.didChangeNotification` → `StatusBarController.applyPreferences()` → restarts the timer if the interval changed.

### Top Apps — platform notes

`ProcessNetworkSampler.sample()` runs `netstat -n -b -v` and parses the output. **Two different column formats exist across macOS versions:**
- macOS 15 (Sequoia): PID is a standalone numeric column at index `rxIndex + 4`
- macOS 26+: PID appears as a `name:pid` token appended to each line

The parser tries the token format first and falls back to the column index. Top Apps requires two consecutive snapshots before rates appear — "Gathering data…" on first open is expected.

### Popover layout constraint

Adapter cards are in a `ScrollView` capped at 6 cards tall (`adapterScrollHeight` in `MenuBarView.swift`). IP addresses and Top Apps are always outside the scroll area. This prevents the popover from growing beyond screen height when many VPN/virtual interfaces are active.

### Adapter ordering and custom names

Stored in `UserDefaults`:
- `"adapterOrder"` — `[String]` of BSD names in user-defined order
- `"adapterCustomNames"` — JSON-encoded `[String: String]` BSD name → custom label

Both are read in `MenuBarView.filteredAdapters()` and `PreferencesView.sortedAdapterRows`.

## Releasing

1. Commit and push to `main`
2. `gh release create vX.Y.Z --title "Netfluss X.Y.Z" --latest --notes "..."`
   (this pushes the tag, triggering the workflow which builds, signs, notarizes, staples, and uploads the zip)
3. After the workflow completes, get the SHA256:
   `curl -sL https://github.com/rana-gmbh/netfluss/releases/download/vX.Y.Z/Netfluss-X.Y.Z.zip | shasum -a 256`
4. Update `Casks/netfluss.rb` in the `rana-gmbh/homebrew-netfluss` tap with the new version and SHA256

## Commit style

- Author: rana-gmbh — no `Co-Authored-By` lines
