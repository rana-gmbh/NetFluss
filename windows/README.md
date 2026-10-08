# NetFluss for Windows

Native Windows port of NetFluss, tracking the macOS app's feature set.
Design and rationale live in [../docs/WINDOWS-PORT-PLAN.md](../docs/WINDOWS-PORT-PLAN.md).

**Status: public beta (2.6.0-beta.2), at feature parity with NetFluss 2.6 for macOS.**
Every macOS feature has a Windows counterpart:

| Area | Windows |
|---|---|
| Live meter | Taskbar overlay, notification-area icon or floating widget; one line, two lines, total, **Dashboard** and **Dashboard Basic** styles; VPN indicator and exit-country badge |
| Popover | Totals, adapters (rename, reorder, hide, grace period), network flow / IP list, DNS switcher, router, Wi-Fi switcher, VPN, Top Apps, Data Usage, Traffic Timer — reorderable, pinnable, resizable |
| Windows | Preferences (Windows 11 Settings style), Bandwidth Statistics (1H–1Y, custom ranges), Speed Test (Cloudflare / M-Lab, history with notes), Network Slice, About |
| Routers | Fritz!Box (TR-064), UniFi (local admin or API key), OpenWRT (ubus), OPNsense (REST) — credentials in Credential Manager, TOFU certificate pinning |
| VPN client | OpenVPN and WireGuard profiles (file, folder or zip; one server per config) and Windows' own IKEv2 / L2TP connections; auto-reconnect, connect at launch, DNS preset while connected, diagnostics log |
| Helper | Optional LocalSystem service: per-app traffic (Top Apps, Network Slice), DNS changes without a UAC prompt each time, VPN tunnels |
| Languages | English, German, Simplified and Traditional Chinese |
| Updates | Installed copies update in place from GitHub releases: signed checksum list (ECDSA, like Sparkle's EdDSA), betas on their own channel |

## Install

Download from the [releases](https://github.com/rana-gmbh/NetFluss/releases) tagged
`win-v…`: **NetFluss-Setup-X.Y.Z-x64.exe** (or `-arm64`) installs per user, without
administrator rights, into `%LOCALAPPDATA%\Programs\NetFluss`. The `-portable.zip` runs from
any folder and is updated by hand. Windows 10 2004 (19041) or later; the builds are
self-contained, so no .NET runtime is needed.

Optional extras, each offered by the app where it is needed:

- **The NetFluss helper** (Preferences → General → System access). Windows only lets
  administrators watch per-app traffic, so Top Apps and the Network Slice need it; it also
  applies DNS changes and runs OpenVPN/WireGuard tunnels. Installing it asks for
  administrator approval once; the uninstaller removes it again.
- **OpenVPN Community** and **WireGuard for Windows**, for VPN profiles of those kinds. The
  macOS app bundles both tools; on Windows they need signed drivers, which only their own
  installers can provide, so NetFluss uses the installed copies.
- **WebView2**, for the speed test. It ships with Windows 11 and current Windows 10.

Command-line verbs, handy for shortcuts and scripts: `--popover`, `--preferences [page]`,
`--speedtest`, `--statistics`, `--slice`, `--about`, `--timer start|pause|reset`,
`--vpn connect [profile]|disconnect`, `--quit`.

## Build

```
dotnet build windows/NetFluss.sln -c Release
dotnet test windows/NetFluss.sln -c Release
dotnet run --project windows/src/NetFluss.App
```

Requires the .NET 10 SDK (LTS). There is no Visual Studio requirement — `NetFluss.sln`
opens in VS 2022 17.11+ but the CLI is sufficient.

## Release

```
pwsh windows/Packaging/build-release.ps1 -Version 1.0.0
```

builds both architectures into `windows/artifacts/release/`: the installer (needs Inno
Setup 6), a portable zip per architecture, `SHA256SUMS.txt`, and — with the private key in
`NETFLUSS_UPDATE_SIGNING_KEY` — its signature `SHA256SUMS.txt.sig`. The in-app updater
requires both: it installs nothing whose list does not carry a valid signature by the key
compiled into `NetFluss.Core/UpdateSignature.cs`, or whose installer the list does not
match. `windows/tools/UpdateSigning` signs, verifies and makes key pairs; the CI secret
of the same name holds the key, and a copy must be kept offline — without it, installed
copies can no longer update themselves. Set `NETFLUSS_SIGN_PFX` and
`NETFLUSS_SIGN_PASSWORD` to also Authenticode-sign the executables and installers.

Releases are cut by tag; `.github/workflows/windows-release.yml` does the rest:

```
gh release create win-v1.0.0 --title "NetFluss for Windows 1.0.0" --latest=false --notes "…"
```

**Betas** are tagged `win-vX.Y.Z-beta.N` (also `alpha`/`rc`) and published as GitHub
pre-releases, with `--prerelease`. Versions are ordered by semver (2.6.0-beta.1 <
2.6.0-beta.2 < 2.6.0). Only a pre-release build is offered pre-releases, so stable users
never see a beta and beta testers get the next beta and then the release, which returns
them to the stable channel. `NETFLUSS_UPDATE_PRERELEASES=1` opts any build into
pre-releases, for trying an update end to end on a throwaway pre-release first.
Release notes live in `windows/Packaging/release-notes/`. Each release's notes end with `release-notes/code-signing-policy.md`: SignPath Foundation, which signs the Windows builds, requires the code signing policy on every download page. Signing runs in the release workflow through SignPath in two rounds (executables, then installers), each approved by hand; the artifact configurations are in `windows/Packaging/signpath/`.

**`--latest=false` is not optional.** The macOS app's Sparkle feed is
`releases/latest/download/appcast.xml`, so a Windows release marked "latest" would cut every
Mac off from updates. The workflow moves "latest" back to the newest macOS release if it
finds it on a Windows one.

## Projects

| Project | Target | Role |
|---|---|---|
| `NetFluss.Core` | `net10.0` | Models, formatters, themes, localization, statistics, router and VPN logic. Platform-neutral **on purpose** so it builds and unit-tests off Windows. |
| `NetFluss.Native` | `net10.0-windows` | Win32 interop: the IP Helper interface table, Native Wifi, the Kernel-Network ETW trace, Remote Access (VPN), Credential Manager. |
| `NetFluss.Tray` | `net10.0-windows` | Notification-area meter rendering. No WPF, so it runs headless. |
| `NetFluss.TrayPreview` | `net10.0-windows` | Renders the tray contact sheet. CI runs this and uploads the PNG. |
| `NetFluss.App` | `net10.0-windows10.0.19041.0` | WPF shell — meter surfaces, popover, Preferences, Statistics, Speed Test, Network Slice, VPN client. |
| `NetFluss.Service` | `net10.0-windows` | The optional helper service (LocalSystem): ETW trace, DNS, adapter resets, VPN tunnels — over a named pipe. |
| `tools/StringsToResx` | | Generates the `.resx` files from the macOS and Windows string catalogues. |
| `*.Tests` | | xUnit. `Native.Tests` needs a real Windows host; `Tray.Tests` asserts on rendered pixels. |

## Three things that are easy to get wrong

**GDI handles.** `Bitmap.GetHicon()` returns an unmanaged icon nothing will free. The meter
repaints every second, so a leak here exhausts the 10,000-handle process limit within hours
and the app silently stops drawing. `TrayIconHost` assigns the new icon *then* destroys the
previous handle — never the current one, which the shell is still painting from.

**Small-icon legibility.** The macOS menu bar gives the meter a ~22 px strip as wide as it
likes. A Windows tray icon is a 16 px *square* at 100% DPI, and fitting "834K" across it
forces Segoe UI to ~6 px — below where TrueType hinting can hold a stem at one clean pixel.
`PixelFont` draws the digits from hand-built 3×5 and 4×7 grids as solid rectangles with
anti-aliasing off, integer-scaled only, so nothing is ever resampled. It is used exactly
where Segoe runs out of pixels (16 and 20 px) and nowhere else — at 24 and 32 px real
letterforms win, and an earlier revision that scored the two on ink height picked a doubled
3×5 face at 200%: taller, and visibly cruder.

The style is resolved **once per icon**, not per row. Two rows in different typefaces look
like a rendering fault, and sizing to whichever label Segoe measured widest clipped "118M"
to ".18M" at 16 px — the two fonts disagree about whether "118M" or "2.4M" is wider, because
the bitmap decimal point is one column and Segoe's is not. `EveryRow_FitsTheIcon` covers that.

**64-bit counters.** `System.Net.NetworkInformation` exposes 32-bit octet counters that wrap
every ~34 seconds on a saturated gigabit link. `NetFluss.Native` calls `GetIfTable2` for the
64-bit `InOctets`/`OutOctets` instead. `MIB_IF_ROW2` is hand-marshalled, and a wrong stride
does not throw — it yields a believable first row and garbage after it. `InterfaceTableTests`
walks every row and asserts each one is plausible, which is what catches that.

## Where the meter goes

macOS has one answer — a variable-width `NSStatusItem` — and Windows has none that is both
roomy and guaranteed, so NetFluss ships three surfaces and lets the user pick.

**The tray icon cannot be made bigger.** The shell draws it at `SM_CXSMICON` for the system
DPI (16 px at 100%, 20/24/32 at 125/150/200%), `Shell_NotifyIcon` hands over an `HICON` and
the shell scales anything larger down. There is no API to request a bigger cell, no way to
make it non-square, and no user setting. The size is not really what macOS has over us
either: `NSStatusItem.length` is *variable width*, which is what makes a full
`↓ 4.72 MB/s ↑ 834 KB/s` line possible. Windows had that in DeskBand and removed it in
Windows 11 with no replacement — which is what killed NetSpeedMonitor.

| Surface | Room | Risk |
|---|---|---|
| **Taskbar overlay** (default) | Full rate line, real hinted text | Best-effort: undocumented geometry |
| **Notification area** | 16–32 px square | None — it cannot break |
| **Floating widget** (optional extra) | Anything | None — it owns its window |

**The overlay** finds `Shell_TrayWnd` and `TrayNotifyWnd` and places a
`WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE` topmost window just before the notification area.
Those class names have been stable since Windows 95 and nothing promises to keep them, so
`TaskbarAnchor` returns null rather than guessing whenever the lookup fails, and null is not
an error — it is the signal to fall back. It re-anchors on `TaskbarCreated` (Explorer
restart), `WM_DISPLAYCHANGE`, `WM_DPICHANGED` and a one-second poll, because the shell sends
no notification for auto-hide sliding or for a tray icon appearing and shifting the free
space along. It hides itself while a fullscreen app is running, since a topmost meter over
someone's game is a defect report.

**Falling back is automatic.** Losing the anchor brings the tray icon straight back, and
Preferences says so rather than leaving a setting that appears to do nothing.

**Every surface carries the same menu**, built once in `SurfaceMenu`. Whichever placement a
user picked is, for them, the entire application, so each one has to offer Preferences *and*
Quit. The tray icon also stays visible by default even when the overlay carries the numbers —
it drops to a static glyph so the rates are not shown twice, but it remains, because it is
where Windows users look for a background app's menu. Hiding it is an explicit preference,
not a side effect of choosing a placement.

**A layered-window trap that cost the overlay every click.** `AllowsTransparency` makes the
overlay a layered window, and a layered window does not hit-test pixels with zero alpha, so a
`Transparent` background let every click sail through to the taskbar underneath. Both the
left-click popover and the right-click menu were silently dead — and with the tray icon
hidden that left no way into Preferences and no way to quit but Task Manager. The background
is now `#01000000`: one unit of alpha, invisible, and hit-testable everywhere.

**A DPI trap worth knowing about.** Window geometry is physical pixels; WPF lays its content
out in device-independent units. Passing a width computed in DIPs straight to `SetWindowPos`
gives a window half the size it needs at 200% scaling, which clips the left-hand rate clean
off the readout — the meter still looks plausible, just wrong. `TaskbarAnchor.Locate` takes
DIPs and scales by the taskbar's own DPI for exactly this reason.

## The popover

Opened by clicking any surface — the tray icon, the taskbar overlay or the floating widget —
so whichever one a user has kept behaves the same way. The widget tells a click from a drag
by whether the window actually moved: `DragMove` blocks until release, and Windows applies
its own drag threshold first, so a click with a pixel of hand-shake in it moves the mouse but
not the window and is still a click.

It is **resizable**, and the size persists. `WindowStyle="None"` means WPF reports every point
as client area, so `ResizeMode="CanResize"` alone gives a window that cannot be resized —
`ResizeHook` answers `WM_NCHITTEST` with the edge codes and hands the drag back to Windows,
which brings snapping and double-click-to-maximise along with it. The hit test works in
physical pixels throughout: converting the message's screen coordinates into WPF units to
compare against a device-pixel window rect is how a 6-unit grip silently becomes a 3-pixel one
at 200% scaling.

## Adapter visibility

Preferences lists every adapter with a checkbox. The list comes from
`NetworkMonitorService.AllAdapters`, deliberately *not* from the filtered `Adapters` the
popover binds to: a checklist built on the filtered set would drop each row the moment it was
unticked, leaving no way to ever tick it back. Loopback and the WFP/QoS filter
pseudo-interfaces stay out of both, since they mirror the adapter they sit on and would offer
the user four copies of their Ethernet card to choose between.

`HiddenAdapters` was another write-only setting — stored, round-trip tested, and never handed
to the monitor. `AppSettings.VisibilityOptions()` is now the one place the preferences are
assembled into the filter's input, so the popover, the totals and the checklist cannot
disagree about which adapters count. Note `SetAdapterHidden` replaces the list rather than
mutating it: `Set<T>` compares a `List` by reference, so an in-place edit would raise no
change notification and the setting would be applied but never saved. `SetAdapterName` does
the same for the `Dictionary`.

Rows can be **renamed** and **dragged to reorder**, both keyed on the interface GUID so they
survive Windows renaming an adapter or it moving between ports. Two things worth knowing:

- Custom names are applied to the *visible* list only, never to `AllAdapters`. The rename
  field has to be able to show what an adapter is called without a custom name — otherwise
  committing an untouched field would pin the current label and quietly stop the adapter
  following its Windows name.
- The checklist rows are observable objects updated in place, not records replaced wholesale.
  The live rate in each row changes every second, and rebuilding the `ItemsSource` for that
  destroyed and recreated the controls once a tick, which ate any rename in progress — the
  text box stopped existing between keystrokes.

`AdapterOrder` is a *partial* order: adapters the user has placed come first in their order,
everything else follows by traffic. Storing only what was dragged is what makes a new VPN
interface appear sensibly rather than being dropped or pinned to the top, and ids for
adapters that are not currently present are kept so an unplugged dock keeps its slot.

**Mirror interfaces.** Loopback and the NDIS/WFP filter pseudo-interfaces present themselves
as ordinary adapters and carry a copy of the traffic of the adapter they sit on. They were
excluded from the totals from the start, but `IsVisible` forgot them, so the popover on a
plain Ethernet machine listed `Ethernet-WFP Native MAC Layer LightWeight Filter-0000` and two
more beside the real adapter, every one reading an identical rate.

## Speed test

Runs the macOS app's own engine. `Packaging/Resources/SpeedTest/*.html` renders **nothing** —
it measures and posts results to its host, which is why macOS draws the readout in SwiftUI and
Windows draws it in WPF. The WebView2 is zero-sized and never shown; it is a measurement
engine, not a page. Sharing it is the point: forking would let the two platforms quietly start
reporting different numbers for the same link.

The page talks to its host through `webkit.messageHandlers.speedTestBridge`, which exists on
WKWebView and not on WebView2. A four-line shim maps it onto `chrome.webview.postMessage`, and
that shim is the whole port.

**The message shape is easy to get wrong.** `progress` does not carry a completion fraction —
it carries the entire running summary, the same payload as `result`, posted repeatedly as the
engine refines it. Reading it as a percentage leaves every figure on "—" until the test ends,
which makes a twenty-second run look like it has hung.

Assets are linked from `Packaging/Resources/SpeedTest` rather than copied into `windows/`, so
there is only ever one copy of the test. WebView2's Evergreen runtime ships with Windows 11
and current Windows 10; where it is missing the window says so plainly rather than leaving a
dead Run button.

The window around it follows the macOS layout: a status card with live tiles and the phase
progress, connection details, the final result, the M-Lab consent step, and a history of the
last thirty results with a note on each (`%LOCALAPPDATA%\NetFluss\speedtest-history.json`).

## DNS switcher

The five macOS presets, plus custom ones, applied per adapter with the active one checkmarked.

**Reading needs no privileges** — `NetworkInterface` reports the live resolvers — so the whole
UI including the checkmark is accurate in an ordinary session. **Writing needs administrator.**
With the helper installed, it applies the change silently; without it, an apply elevates one
short-lived `netsh` run — one UAC prompt per change, rather than a tray app holding
administrator rights all day so that a rarely-used setting can be changed.

**`DnsValidator` is a security boundary, not a convenience.** Its output reaches the command
line of an elevated process, so every server must round-trip through `IPAddress` — not merely
look address-shaped — and the adapter name must be one Windows itself reported. `DnsTests`
covers the injection-shaped inputs specifically.

IPv4 and IPv6 are separate stores in Windows, so a preset carrying only IPv4 must also put
IPv6 back on automatic; otherwise a leftover IPv6 resolver keeps answering and the change
looks like it did nothing.

## The helper service

`NetFluss.Service` is the counterpart of the macOS privileged helper, and optional in the
same way. It runs as LocalSystem because that is the identity Windows lets enable the
Kernel-Network ETW provider behind Top Apps and the Network Slice; an unelevated app gets
`ERROR_ACCESS_DENIED` from `EnableTraceEx2`. The app talks to it over the `NetFluss.Helper`
named pipe in newline-delimited JSON (`HelperProtocol`), and the trace runs only while
something in the app holds a lease on it — the popover's Top Apps, an open Network Slice,
app statistics — never just because the service is up.

The pipe admits interactive users, so every operation is written as if the caller were
hostile: DNS servers must parse as addresses, adapters must be ones Windows reported, and
VPN configs arrive as file *contents*, never paths, so the service cannot be talked into
reading a file the caller could not read itself.

An older helper keeps serving traffic after the app updates; only the VPN client, which
needs protocol 2, asks for the helper to be updated.

## VPN client

Port of the macOS 2.4 client. OpenVPN and WireGuard need administrator rights to create a
tunnel, so the helper runs the user's installed OpenVPN Community and WireGuard for Windows:
it writes the received files into a folder under `Program Files\NetFluss\VpnStaging` that
only SYSTEM and Administrators can touch (not ProgramData, where a standard user could
create — and so own — the folder first), checks them there so nothing can change them
between the check and the launch, and starts the tool.

`VpnConfigPolicy` is the security boundary for running someone else's config as SYSTEM, and
it is an **allowlist**: only directives a client config needs pass, every file argument (in
whatever position) must stay inside the profile folder, and anything unknown is refused by
name — a denylist missed `providers`, `engine`, `pkcs11-providers` and `win-sys` in review.
Lines are tokenized exactly as OpenVPN's `parse_line` does (quotes, escapes), `<connection>`
blocks are checked like top-level directives, and anything the two parsers could read
differently is refused. `--script-security 1` still stops up/down scripts. Import already
warns about a config the helper would refuse. WireGuard script hooks are stripped, and the
helper's WireGuard tunnels are always named `NetFluss-…`, so it can neither replace nor stop
a tunnel it did not create. OpenVPN's management interface is on a loopback port behind a
one-time password, and the app checks that the port's listener is the OpenVPN process the
helper started before it sends that password or any credentials.

IKEv2 and other Windows VPN connections need no helper: they are Remote Access phonebook
entries, dialled with `RasDial` so the password stays in memory rather than on a command
line. "Add IKEv2 VPN…" creates the entry through the VpnClient PowerShell module and keeps
the password in Credential Manager. The RAS structures are 4-byte packed (`pshpack4.h`) —
a default-packed `RASCONN` is rejected with `ERROR_INVALID_SIZE`.

## Routers

`RouterService` polls each enabled router every five seconds while something shows router
traffic — the popover, the Router page, or the Dashboard meter style — with exponential
backoff up to a minute for one that keeps failing. Self-signed router certificates are
trusted on first use and pinned per host and port (`RouterPinStore`); a changed key is
refused and explained, and re-entering the router's address re-trusts it. Credentials and
API keys live in Credential Manager under `NetFluss:<router>:<host>`.

## Themes

`AppTheme` ports the macOS presets (Dracula, Nord, Solarized) plus a `system` entry that
defers to Windows. A theme sets the popover, the floating widget and the two rate colours;
`AppTheme.Surface(systemIsLight)` resolves it into a `SurfacePalette` with no nulls left, so
a themed window never has to guess at a colour the theme declined to specify.

**Precedence:** the theme supplies the base pair, and a per-row accent set to anything other
than *Automatic* overrides it. Picking Dracula recolours both rows; a user who had pinned
upload to orange keeps their orange. That matches macOS, where the theme sets the palette and
the per-element pickers win over it.

The theme picker was write-only for a while — Preferences stored `ThemeId` and nothing in the
app ever read it back, so choosing Dracula rewrote a line in `settings.json` and changed
nothing on screen. The popover made it worse by hardcoding its colours in XAML, so it ignored
Windows' own light mode too. `ThemeResolutionTests` covers the precedence and asserts every
theme's text clears 4.5:1 against its own background.

Preferences itself deliberately stays on the Windows light/dark palette rather than following
the app theme: it is styled to sit beside real Windows Settings, and a Solarized Settings
clone would read as a rendering fault rather than a preference.

## Tray glyphs

`TrayGlyphLibrary` ports the macOS `MenuBarIconLibrary` choice list. The glyphs are **drawn
geometry, not image files**: SF Symbols cannot ship off Apple platforms, and a raster
substitute is crisp only at the sizes it was authored for. The tray asks for 16, 20, 24 or
32 px depending on the display, plus whatever a future scaling factor invents, so every size
is authored. `TrayGlyphLibraryTests` asserts each glyph draws ink at every size, covers less
than 90% of the box, and — after "NetFluss" and "Arrows" were briefly the same method — that
no two of them render identically.

## Preferences and settings

`PreferencesWindow` follows Windows 11 Settings: a navigation pane with the macOS panes —
General, Taskbar, Appearance, Adapters, Statistics, Top Apps, DNS, Wi-Fi, VPN, Router — and
one scrolling column of grouped cards per page, control on the right, changes applied and
persisted immediately with no OK button. It is hand-styled rather than built on a UI
package, whose own theming would have to be reconciled with the NetFluss themes anyway.

The **preview strip** renders the real `TrayMeterRenderer` output at 16/20/24/32 px on the
user's actual taskbar colour. A 16 px icon is the whole difficulty of this port, so the
meter-style choice is shown rather than described.

Settings live in a JSON document at `%LOCALAPPDATA%\NetFluss\settings.json`, not the
registry: the macOS app keeps ordered lists in `UserDefaults` (adapter order, hidden
adapters, custom presets) and the registry has no ordered-collection story worth using. It is
written via write-then-replace. An unknown value — a style from a newer build, a hand edit —
costs only that preference; a file that cannot be parsed at all falls back to defaults, but is
first kept as `settings.json.unreadable-<time>.json`, because the next change would otherwise
save those defaults over everything the user had set.

Two pieces of state are deliberately **not** in that file:

- **Start with Windows** lives in `HKCU\...\CurrentVersion\Run`, because writing it is what
  actually makes the app start and a user can remove it from Task Manager's Startup tab. The
  toggle always reads the registry back rather than trusting what was last written.
- **Light or dark** comes from `SystemUsesLightTheme` / `AppsUseLightTheme`. Windows exposes
  the shell and app themes independently, and the tray meter follows the *shell* one because
  that is what it is composited over.

## Localization

The macOS `Localizable.strings` catalogues are the **single source of truth for every
string the two apps share**. Strings that only exist on Windows ("Start with Windows", the
taskbar placements) live in `windows/Localization/<lang>.lproj/Windows.strings`, in the same
format and the same four languages. Do not hand-edit the `.resx` files:

```
dotnet run --project windows/tools/StringsToResx
```

It rewrites Cocoa `%@` specifiers to .NET `{0}` items and writes
`src/NetFluss.Core/Resources/platform-review.md` listing every string that mentions a
platform-specific concept — "Menu bar icon style" needs a Windows word, and the report is
where those decisions get tracked. A key in `Windows.strings` that also exists in the Mac
catalogue **overrides** it, which is how such a string gets its Windows wording without the
Mac app changing. CI runs the tool with `--check` and fails if the generated files are stale.

The tool is a C# port of the original `strings2resx.py`, written so regenerating needs only
the .NET SDK. It was verified by regenerating every file and diffing nothing.

**Case-folded resource names.** .NET treats two resource names differing only in
capitalization as the same name; macOS `.strings` keys are case-sensitive, and NetFluss has
three pairs that differ only in case — a title-case heading beside the sentence-case control
that opens it (`Custom Date Range` / `Custom date range`). resgen's response is to drop one
and emit `MSB3568`, so the build stays green while a string vanishes from every language. It
is invisible in English, where the key doubles as the value, and only shows up as English
text leaking into German and Chinese.

The generator resolves it: the first key of each colliding group keeps its exact name and the
rest are stored as `key~2`, `key~3`, …, which `Localization.L` probes for when an exact lookup
misses. Call sites still pass the macOS key verbatim. `CollisionLimit` in the generator and
`CollisionLimit` in `Localization.cs` must move together, and `LocalizationCaseCollisionTests`
fails if they don't. `MSB3568` is promoted to an error in `Directory.Build.props` so a future
collision breaks the build instead of warning — note it only fires on a full resgen, so
reproduce with `dotnet clean` first.

## Verifying without a Windows machine

CI on `windows-latest` is the verification loop. Every push touching `windows/**` builds,
runs both test suites, and uploads **`tray-contact-sheet.png`** — every tray layout rendered
at 16/20/24/32 px (100%/125%/150%/200% scaling) over light and dark taskbar swatches, at 6×
magnification with a 1:1 inset. That artifact is how the Phase 0 question gets answered:
*is a 16 px tray icon legible enough to be the default, or does the taskbar-overlay window
have to be first-class?*

### Phase 0 verdict

From the first green run's contact sheet:

- **The tray meter is viable as the default.** Two-line is clean at 24 px (150%) and 32 px
  (200%), good at 20 px (125%), and cramped but functional at 16 px (100%). Most current
  Windows laptops ship at 125–150%, so the common case is comfortable.
- **16 px is the weak spot**, which is precisely the case the opt-in taskbar-overlay window
  exists to serve. It stays a Phase 2+ item, not a Phase 0 blocker.
- **`DownloadOnly` should be offered at 16 px** — a single line gets the full icon height
  and is markedly sharper than two half-height rows.
- **Arrows off by default is correct.** `↓4.7M` visibly degrades against `4.7M` at 16–20 px;
  the glyph eats width the digits need, and the row colour already carries the meaning.
- **The upload green needs darkening on light taskbars.** At `#2ea043` on `#f3f3f3` it reads
  noticeably weaker than the download blue. Worth a contrast pass in Phase 1.

### What Phase 1 did about it

Both of the open items above are closed; the verdict above is kept as the record of what the
spike found.

- **16 px is no longer the weak spot.** `PixelFont` replaced the sub-hinting Segoe rows with
  a bitmap face, so two-line at 100% is now sharp rather than "cramped but functional".
  `BitmapFontRows_AreFullyOpaque` asserts it the only way that cannot flatter itself: every
  pixel the bitmap path draws is fully opaque, so no edge got softened.
- **The contrast gap was measured and closed.** The download blue scored 4.08:1 on the light
  taskbar against the upload green's 3.04:1 — the two rows disagreed about how important
  they were. `Contrast.EnsureRatio` now lifts both to WCAG AA (4.5:1) against whichever
  taskbar they are drawn on, stepping toward black or white so the hue survives.
  `ContrastTests` pins the original measurements and the correction.
- **`DownloadOnly` is still worth offering**, but no longer because two-line is illegible —
  it is now a preference for density, not a workaround.
