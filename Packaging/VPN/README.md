# VPN bundling & entitlements

NetFluss's VPN client uses three backends:

| Protocol | How it runs | Bundling | Entitlement |
|---|---|---|---|
| OpenVPN | bundled `openvpn` via the privileged helper + management socket | `bundle-openvpn.sh` | none |
| WireGuard | bundled `wireguard-go`/`wg`/`wg-quick`/`bash` via the helper | `bundle-wireguard.sh` | none |
| IKEv2/IPsec | `NEVPNManager` (Personal VPN) in-app | none | **Personal VPN** |

## Bundling (OpenVPN + WireGuard)

Run during app assembly (see CLAUDE.md → Manual release build). Needs
`brew install openvpn wireguard-go wireguard-tools bash`. Universal builds lipo
in an Intel slice produced by the `intel-vpn` CI job.

## IKEv2 — Personal VPN entitlement (required)

In-app IKEv2 connect/disconnect uses `NEVPNManager`, which requires the
`com.apple.developer.networking.vpn.api` ("allow-vpn") entitlement. This is a
**restricted** entitlement: it must be authorized by a provisioning profile, and
signing the app with it but *without* such a profile makes the app fail to
launch. So the default build signs with `Netfluss.entitlements` (no VPN
entitlement, app launches, OpenVPN/WireGuard work); the IKEv2-enabled build signs
with `Netfluss-vpn.entitlements` **and** embeds a provisioning profile.

### One-time setup (Apple Developer portal, Rana GmbH account)

1. **Identifiers → App IDs**: ensure an explicit App ID `com.local.netfluss`
   exists, and enable the **Personal VPN** capability on it.
2. **Profiles → +**: create a **Developer ID** provisioning profile for that App
   ID (Profile Type: "Developer ID"). Download it (`Netfluss.provisionprofile`).

### Building the IKEv2-enabled app

After assembling `NetFluss.app` (and bundling openvpn/wireguard):

```bash
cp Netfluss.provisionprofile NetFluss.app/Contents/embedded.provisionprofile
codesign --force --sign "Developer ID Application: Rana GmbH (D6P24X5377)" \
  --options=runtime --timestamp \
  --entitlements Netfluss-vpn.entitlements NetFluss.app
```

Then notarize/staple as usual. Without the embedded profile, use
`Netfluss.entitlements` instead (IKEv2 connect will report that the Personal VPN
entitlement is missing; the rest of the app is unaffected).
