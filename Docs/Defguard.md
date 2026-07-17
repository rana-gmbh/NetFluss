# Defguard support — design & research notes (issue #51)

Goal (Phase 1): let a NetFluss user connect to a **Defguard** VPN location that
requires **TOTP** desktop-client MFA, single instance, free tier. Defguard is
stock WireGuard for the data plane plus an MFA/identity control plane.

## Key facts (researched July 2026)

- **Data plane = stock WireGuard.** NetFluss already runs WireGuard via bundled
  `wireguard-go` + `wg-quick` through the root helper. That part is reused as-is.
- **MFA is enforced at the gateway by peer gating.** For an MFA location the
  gateway does NOT admit the device's peer (no pre-shared key) until the client
  completes MFA. The **pre-shared key acts as a session token**, rotated per MFA
  session and **removed after ~3 min without a live WireGuard handshake** (that's
  the "logout"). Source: docs.defguard.net/in-depth/architecture/architecture.
  → A static `.conf` import connects then drops within minutes on MFA locations,
    so real Defguard MFA support needs the control-plane client, not just import.
- **Transport = REST/JSON over HTTPS (CORRECTED).** Earlier I assumed gRPC, but
  the proxy ("Edge") exposes the client flows as a **public REST API** and the
  gRPC service is only core↔proxy (the `Proxy.Bidi` stream is explicitly
  "initiated by core"). The desktop client uses `reqwest` for these, with the
  proto messages as JSON DTOs. Confirmed routes in DefGuard/proxy
  (`src/handlers/`): `POST /api/v1/enrollment/{start,create_device,activate_user}`
  and `POST /api/v1/client-mfa/{start,finish}`.
  → **No Go agent needed.** Implemented in pure Swift (URLSession + CryptoKit for
    the WireGuard keypair). grpc-swift / bundled-binary plan is dropped.
- **`DeviceConfig`** (enrollment result) carries the WireGuard fields:
  `assigned_ip` (address), `pubkey`, `endpoint`, `allowed_ips`, `dns`,
  `keepalive_interval`, and `location_mfa_mode` (Disabled / Internal / …).
- **Client-facing RPC surface** (from DefGuard/proto, all AGPL open-core, not the
  `enterprise/` dir): enrollment (`EnrollmentStart` → `NewDevice`/`ExistingDevice`
  → `DeviceConfigResponse`), client MFA (`ClientMfaStart` → `ClientMfaFinish`),
  `ClientMfaTokenValidation`, TOTP setup (`CodeMfaSetupStart/Finish`),
  `InstanceInfo`. NOTE: in the proto repo these payloads ride the proxy↔core
  `Bidi` stream; the exact CLIENT→proxy unary service still needs mapping from the
  DefGuard/proxy repo before wiring (TODO).
- **Free tier covers the need.** Desktop-client MFA at the WireGuard level (TOTP),
  device enrollment, and zero-touch provisioning are all free. Paid adds external
  SSO, real-time config sync, ACLs, LDAP/AD, SIEM, REST API. Source:
  defguard.net/pricing.
- **Licensing is clean.** Core/proxy/proto are AGPL-3.0 (except `enterprise/`,
  proprietary). NetFluss is GPLv3; GPLv3 §13 permits combining with AGPL-3.0, and
  reimplementing a protocol/API is not a derivative of the code. Market as "works
  with Defguard" — avoid implying endorsement (trademark).

## Architecture decision: pure-Swift REST client (Go agent NOT needed)

The initial plan was a bundled Go agent, on the assumption the client used gRPC
(and grpc-swift 2 needs macOS 15, breaking our macOS 13 floor). But the enrollment
+ client-MFA flows are **REST/JSON**, so this is implemented directly in Swift:

- `DefguardControlClient` (protocol) — transport-agnostic operations.
- `DefguardRESTClient` — URLSession + CryptoKit (Curve25519 WireGuard keypair);
  cookie-persisting ephemeral session across the enrollment calls.
- `DefguardMockControlClient` — accepts TOTP `000000`, for UI/dev.

Endpoints (base = `<proxy>/api/v1`):
- `POST enrollment/start` `{token}`
- `POST enrollment/create_device` `{name, pubkey, token}` → `{configs:[DeviceConfig], instance}`
- `POST client-mfa/start` `{location_id, pubkey, method}` → `{token, challenge}`
- `POST client-mfa/finish` `{token, code}` → `{preshared_key}`

The device private key is generated with CryptoKit and stored in the **Keychain**;
only the public key is persisted in the profile.

### To validate against Stephan's live instance
- `MfaMethod` JSON encoding (integer `0` for TOTP vs the string `"TOTP"`).
- Whether `enrollment/start` sets a session cookie that `create_device` needs
  (URLSession keeps cookies by default).
- Whether first-time enrollment also requires `activate_user`.
- Exact `DeviceConfig` field JSON (we map `network_id/assigned_ip/pubkey/endpoint/
  allowed_ips/dns/keepalive_interval/location_mfa_mode`).

## Phase 1 plan (single instance, TOTP only)

1. **Models + client abstraction (Swift, transport-agnostic)** — `DefguardModels`,
   a `DefguardControlClient` protocol, a mock for UI/tests. ← start here
2. **Profile type** — represent a Defguard-managed WireGuard profile (instance +
   proxy URL, location, device pubkey, MFA mode) alongside the existing kinds.
3. **UI** — "Add Defguard instance" (instance URL + enrollment token) and a TOTP
   prompt shown on connect.
4. **Connect flow** — enroll → on connect run `mfaStart`/`mfaFinish(totp)` → inject
   the returned pre-shared key into the WireGuard config → bring the tunnel up via
   the existing helper path.
5. **Session lifecycle** — detect the ~3-min gateway de-auth (handshake age; we
   already poll the tunnel) and re-run MFA / reconnect cleanly. Highest design risk.
6. **The Go agent** — vendor the AGPL `.proto`, implement enroll + client MFA over
   gRPC, expose the JSON stdio contract; build universal + sign + notarize.

## Decisions (owner-confirmed)

- ~~Network layer = bundled Go agent~~ **SUPERSEDED**: the client flows are
  REST/JSON, so it's a **pure-Swift URLSession client** — no Go, no bundled binary,
  no macOS-15 problem. (The Go-agent decision was based on an incorrect gRPC
  assumption; corrected after reading the DefGuard/proxy REST handlers.)
- **End-to-end testing via the reporter (Stephan)** against his company's live
  Defguard — I can't reach it, so the agent is built against the proto/docs and
  validated through him. Expect a round or two of protocol fix-ups.

## Remaining work / next steps

1. **Map the client→proxy unary gRPC service** from the DefGuard/proxy repo (the
   proto repo shows the payloads but routes them over the core↔proxy Bidi stream).
2. **Build the Go agent**: `go.mod`, vendor the AGPL `.proto`, implement enroll +
   client MFA, expose the JSON-over-stdio contract above.
3. **Swift flow/UI** against `DefguardControlClient` (mock first): enrollment sheet
   (URL + token) → profile; connect → TOTP prompt → PSK → existing WG bring-up;
   ~3-min re-auth lifecycle.
4. **Package** the agent (universal, Developer ID, notarized) like the VPN tools.
