# Privacy Policy — NetFluss for Windows

NetFluss shows your network traffic. It has no account, no analytics and no telemetry: nothing about you or your use of the app is sent to Rana GmbH or anyone else, apart from the connections listed below. Everything NetFluss records stays on your PC.

## Connections NetFluss makes on its own

You can switch each of these off, in the installer or later in **Preferences → General**.

| What | When | Service | What it sees |
|---|---|---|---|
| Update check | Once a day, if **Check for updates automatically** is on | GitHub (`api.github.com`) | Your IP address and the NetFluss version |
| Your public IP address | While the popover is open, or while the taskbar meter shows a country badge, if **Look up public IP addresses and countries** is on | ipify (`api.ipify.org`, `api64.ipify.org`) | Your IP address |
| The country of your public IP | When the popover or the taskbar meter shows a country (network path, VPN section, country badge), with the same switch | ipwho.is (`ipwho.is`) | Your IP address |
| Countries of the servers in Network Slice | While the Network Slice window is open, with the same switch | country.is (`api.country.is`) | Your IP address and the public addresses of the servers your PC talks to |

Network Slice also shows server names. It asks your PC's own DNS resolver for them, as any program does.

## Connections only when you ask for them

- **Speed Test.** Runs only when you start it.
  - **M-Lab** (`measurementlab.net`) publishes every test, including your IP address, as open data. NetFluss asks for your consent before the first M-Lab test. See the [M-Lab privacy policy](https://www.measurementlab.net/privacy/).
  - **Cloudflare** (`speed.cloudflare.com`) runs the alternative test.
- **Installing an update.** **Install and Relaunch** downloads the update from GitHub.
- **Routers.** NetFluss contacts only the router addresses you enter: Fritz!Box, UniFi, OpenWRT or OPNsense.
- **VPN.** NetFluss connects only to the servers in the profiles you import or create.
- **Links.** Release notes, the project page and donation links open in your browser.

## What stays on your PC

These files are kept in `%LOCALAPPDATA%\NetFluss`:
- settings;
- traffic statistics;
- speed test history;
- VPN profiles;
- error and VPN logs.

Router and VPN passwords are kept in Windows Credential Manager.

**Copy Diagnostics** puts a report on your clipboard and sends it nowhere. You decide whether to share it.

The optional NetFluss helper is a Windows service on your PC. It talks only to the NetFluss app, never to the internet.

## Removing NetFluss

Uninstall NetFluss in **Settings → Apps**. If you installed the helper, the uninstaller removes it too. To delete your data as well, remove the folder `%LOCALAPPDATA%\NetFluss`.

## Contact

Rana GmbH — [www.ranagmbh.de](https://www.ranagmbh.de). Questions about this policy: [open an issue](https://github.com/rana-gmbh/NetFluss/issues).
