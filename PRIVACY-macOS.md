# Privacy Policy — NetFluss for Mac

NetFluss shows your network traffic. It has no account, no analytics and no telemetry: nothing about you or your use of the app is sent to Rana GmbH or anyone else, apart from the connections listed below. Everything NetFluss records stays on your Mac.

## Connections NetFluss makes on its own

| What | When | Service | What it sees | Off switch |
|---|---|---|---|---|
| Update check | About once a day | GitHub (`github.com`) | Your IP address and the NetFluss version | **Preferences → General → Check for updates automatically** |
| Your public IP address | While the popover is open, or while the menu bar shows a country flag | ipify (`api.ipify.org`, `api64.ipify.org`) | Your IP address | **Preferences → General → Look up public IP addresses and countries** |
| The country of your public IP | When the popover or the menu bar shows a country | ipwho.is (`ipwho.is`) | Your IP address | The same switch |
| Countries of the servers in Network Slice | While the Network Slice window is open | country.is (`api.country.is`) | Your IP address and the public addresses of the servers your Mac talks to | The same switch |
| Connection check | About once a minute while the menu bar link indicator or the DNS rules are on, more often while a connection looks degraded | Apple (`captive.apple.com`, plain HTTP), or an address you set | Your IP address | Turn off the internet check under the link indicator's settings |

Network Slice also shows server names. It asks your Mac's own DNS resolver for them, as any program does.

## Connections only when you ask for them

- **Speed Test.** Runs only when you start it.
  - **M-Lab** (`measurementlab.net`) publishes every test, including your IP address, as open data. NetFluss asks for your consent before the first M-Lab test. See the [M-Lab privacy policy](https://www.measurementlab.net/privacy/).
  - **Cloudflare** (`speed.cloudflare.com`) runs the alternative test.
- **Installing an update.** Downloads the update from GitHub.
- **Routers.** NetFluss contacts only the router addresses you enter: Fritz!Box, UniFi, OpenWRT or OPNsense.
- **Proxy statistics.** NetFluss contacts only the controller address you enter.
- **VPN.** NetFluss connects only to the servers in the profiles you import or create.
- **DNS.** Your Mac sends its name lookups to the resolver you pick, or that a DNS rule picks for the network you join. That resolver can see what you look up, as any resolver can.
- **Links.** Release notes, the project page and donation links open in your browser.

## What stays on your Mac

These are kept in `~/Library/Application Support/NetFluss`:
- traffic statistics, including one backup copy;
- VPN profiles and their keys, which are excluded from Time Machine;
- the VPN diagnostics log.

Settings are kept in `~/Library/Preferences/com.local.netfluss.plist`. Router, proxy and VPN passwords are kept in your Keychain.

**Copy Diagnostics** puts a report on your clipboard and sends it nowhere. You decide whether to share it.

The optional NetFluss helper runs on your Mac with administrator rights so it can change DNS and run VPN tunnels. It talks only to the NetFluss app, never to the internet; the tunnels it starts connect to the VPN servers you chose.

## Removing NetFluss

Quit NetFluss and move it to the Trash. If you installed the helper, remove it under **System Settings → General → Login Items**. To delete your data as well, remove the folder above and the settings file.

## Contact

Rana GmbH — [www.ranagmbh.de](https://www.ranagmbh.de). Questions about this policy: [open an issue](https://github.com/rana-gmbh/NetFluss/issues).
