# VueVPN

A personal OpenVPN client for macOS Apple Silicon: **Swift/AppKit → Objective-C++ → embedded OpenVPN 3 Core**. No separate OpenVPN CLI installation is required.

The app provides a 960 × 720 window, `.ovpn` profiles, PIN/password authentication with optional Keychain storage, a native menu bar, simultaneous connections, per-profile IPv4 routing, and DNS settings supplied by the VPN server.

The previous Vue/TypeScript UI and Rust/Tauri backend have been removed. The app
is still called VueVPN. See [AGENTS.md](AGENTS.md) for coding-agent guidance and
[docs/NATIVE_MIGRATION.md](docs/NATIVE_MIGRATION.md) for migration history and
validation limits.

## Running a packaged build

1. Copy `artifacts/VueVPN.app` to `/Applications`.
2. Open the app manually. Choose **App settings → Enable VPN helper**.
3. If prompted, allow VueVPN in **System Settings → General → Login Items & Extensions**, then click **Refresh status**.
4. Import a development `.ovpn` profile. Select it, review its subnets, and click **Connect to VPN**.
5. Enter your PIN/password. Select **Remember on this Mac** to save it after a successful connection.

This local build targets **macOS 26.0+ arm64**, matching the native dependencies available on the build machine. The helper uses APIs available from macOS 13, but the local OpenSSL binaries require macOS 26. Supporting older macOS versions requires rebuilding native dependencies for the intended deployment target.

Closing the window hides it. The app and VPN keep running through the menu bar.
**Quit VueVPN** cleans up connections before exiting. Opening the app does not
automatically connect any profile.

## Appearance and interaction

Choose **App settings → Appearance → Light / Dark / System**. The default,
**System**, follows macOS appearance changes immediately. Light and Dark retain
the selected theme when the system appearance changes. The preference is saved
for the app, applies to every profile, and requires no restart or VPN reconnect.

Dark uses a deep green palette. Inputs, dialogs, diagrams, statistics, and toast
messages follow the app theme; native menus and the menu bar follow macOS.
Clickable controls use a pointing-hand cursor, disabled controls use an arrow,
and text inputs use an I-beam. Standard menus and window controls retain their
native macOS behavior.

Connection animations use Core Animation layers without a timer redrawing the
entire Overview every frame. Traffic and duration values update separately,
about once per second. Workspace rendering pauses when the window is hidden,
minimized, fully occluded, or covered by a dialog; menu-bar controls and VPN
connections remain active. Animation also pauses when its illustration scrolls
out of view. Low Power Mode retains normal animation, while Reduce Motion is
respected.

## Updating the app

Quit the old VueVPN app, replace `/Applications/VueVPN.app` with the new
`artifacts/VueVPN.app`, and reopen it. **Routine updates do not require disabling
and re-enabling the helper**, including upgrades from versions without helper
version detection.

The app compares the signed helper executable's fingerprint in the bundle with
the running helper's fingerprint over XPC. If they differ, it waits for all VPN
connections to disconnect, unregisters the service, waits for macOS to confirm
that the old process has stopped, and registers it again. New connections are
allowed after the new helper's fingerprint is verified. UI-only changes with an
unchanged helper executable do not restart the helper.

When a VPN is active, **update pending** is shown and connections continue until
the user disconnects. **Disconnect all and update** is available in App settings.
Profiles and PINs stored in Keychain are preserved. Grant approval in System
Settings if macOS requests it. A deliberately disabled helper is not enabled
automatically. Wait for an update to finish before quitting.

A **not found** status with a complete bundle is treated as a registration that
needs recovery: the app checks the signed executable and plist, then attempts
automatic registration. After the previous helper stops, registration continues
with a fresh SMAppService instance. Temporary registration failures are retried
up to three times with delays; the status remains **updating** until the helper's
fingerprint is verified. A helper deliberately left unregistered still requires
Enable, unless registration was lost during an update or the user selects Retry.

Disconnect sends an asynchronous signal to the engine, including during sleep
or network changes. Core stops its event loop after shutdown so pending work
cannot keep `connect()` running indefinitely. The transport closes before its
bypass routes are released. If Disconnecting lasts 30 seconds, the app shows
**Disconnect stalled** and **Retry disconnect**. A timeout does not count as
success: session/route ownership is retained, replacement connections are
rejected, and helper updates wait for cleanup. Retry does not restart the helper
or disconnect other profiles.

Persistent update failures offer **Retry helper update**, which resumes
registration without requiring another Enable click. Unregister/register retries
are bounded. An unreachable helper is not stopped immediately because the app
cannot yet confirm the state of its connections. Bundle detection applies only
to a complete, signed `.app`; an unsigned compilation is not a ready-to-use
bundle and must not be used for live VPN testing.

## Profiles and routing

- Pritunl profiles with `password_mode: pin` use a PIN and the username from profile metadata. The username can be changed in **Edit profile**. Standard username/password profiles are also supported.
- Profiles containing `route-nopull` and explicit routes start in **Selected networks** mode. Other profiles start in **All IPv4 traffic** mode.
- The editor accepts prefixes (`24`, `/24`) or subnet masks (`255.255.255.0`). Addresses are normalized to network addresses.
- Only one full IPv4 tunnel can be active. Other split-tunnel profiles may run concurrently if their subnets and DNS domains do not overlap.
- The backend supports IPv4 DNS and stored domain suffixes; empty settings use server-provided values. In Selected networks mode, automatic DNS without a domain suffix is ignored, retaining system DNS without adding routes to VPN resolvers. Internal hostnames require a stored or server-provided suffix; manually configured DNS without a suffix is rejected. Resolver IPs in use are also routed through the VPN. Internal DNS controls are temporarily hidden from Overview and Profile settings. Editing a profile preserves stored DNS settings, and backend handling of server-provided DNS remains active. All IPv4 mode can use server DNS without requiring a suffix.
- Server-pushed routes do not select the routing mode: VueVPN's settings determine it.
- Saving network changes to an active profile reconnects only that profile.
- IPv6 is neither modified nor blocked. A full tunnel covers **IPv4**, except for VPN transport, local/peer interface addresses, and more-specific local-network routes owned by macOS. There is no kill switch.
- Ordinary connection failures allow five retries with 2/4/8/16/30-second backoff. Offline/sleep states pause attempts. Network changes and temporary network errors reset the counter, so waiting for network recovery is not limited to five total attempts. Authentication, certificate, and configuration errors stop retries.
- Profiles with legacy compression framing, including `comp-lzo no`, use receive-only compatibility mode. VueVPN does not compress outgoing data but can receive compressed data from these servers. Profiles without compression directives retain mode `no`; `allow-compression no` is always respected.

## Local data

Profiles are stored in `~/Library/Application Support/com.vuevpn.desktop/profiles`,
with directory permissions `0700` and file permissions `0600`. Referenced
certificate/key files are imported inline without changing the originals.
Pritunl synchronization metadata is not stored. Passwords are never written to
JSON or logs. Appearance preferences use UserDefaults, separately from Keychain
credentials.

Remembered passwords use macOS Keychain service
`com.vuevpn.desktop.credentials`. **Forget password** removes them. Passwords
rejected by the server are deleted so the next connection requests credentials
again. Without the remember option, credentials are retained only in memory for
reconnections within the current session.

The helper runs separately with administrator privileges. XPC communication
requires matching signing identifiers and Team IDs in both directions, as well
as the active console user. The UI does not run as root. The helper accepts
neither shell commands nor file paths from the UI; profiles are restricted to
supported inline configuration.

## Development and builds

Run all commands from the repository root. Requirements: Apple Silicon,
macOS 26+, full Xcode 26 with Swift 6 and the macOS SDK, Python 3, CMake, Asio,
OpenSSL 3, and LZ4. Build scripts look for Homebrew dependencies in
`/opt/homebrew`. Node.js, npm, Rust, Tauri, WebView, and the OpenVPN CLI are not
required.

Examples use `rtk proxy`, a CLI wrapper in the developer workspace. RTK is not a
dependency of the app or build scripts. If RTK is unavailable, run the same
commands without the `rtk proxy` prefix.

Ensure the developer directory points to full Xcode, not just Command Line
Tools. Check the toolchain before building:

```sh
rtk proxy xcode-select -p
rtk proxy xcodebuild -version
rtk proxy python3 --version
```

Install dependencies if needed:

```sh
rtk proxy brew install cmake asio openssl@3 lz4
rtk proxy python3 scripts/native.py prepare
```

OpenVPN Core is pinned to the commit in `scripts/native.py`; IPv4 endpoint patches
are applied from `native/patches/`. The first prepare requires network access to
download the source. Native build/test commands also run prepare and verify the
pin and patches. Vendor files are not committed.

Build a Release package with the helper and all libraries, without opening the app:

```sh
rtk proxy python3 scripts/package.py
```

The script automatically selects a signing identity when exactly one Apple
Development or Developer ID Application identity is available. Otherwise, set
`VUEVPN_SIGNING_IDENTITY` to the desired identity's SHA-1. Packaging requires the
identity and its private key in Keychain; unsigned compilation and unit tests
remain available without an identity. Use the same identity/Team as previous
builds. Local signing does not notarize or publish the app. The script verifies
app/helper signatures and dependencies before replacing the previous build
artifact.

The package for manual testing is **`artifacts/VueVPN.app`**. Quit the old app,
copy this package to `/Applications`, and open it manually. Building does not
register or start the helper.

For a Debug Swift application with the complete helper bundle:

```sh
rtk proxy python3 scripts/package.py --configuration Debug
```

Use the same launch workflow: copy the package to `/Applications` and open it
manually. There is no frontend server or hot reload. Edit the project in
`macos/VueVPN.xcodeproj`. The `--configuration Debug` option applies to the Swift
app; `scripts/native.py` still builds the helper/OpenVPN in Release configuration.
For a quick compilation without packaging/signing:

```sh
rtk proxy python3 scripts/build.py
```

The output at `macos/build/Build/Products/Debug/VueVPN.app` does not contain the
complete helper bundle; use the packaged output to test connections. After
adding or removing Swift files, run:

```sh
rtk proxy python3 scripts/sync_sources.py
```

Commit changes to `macos/VueVPN.xcodeproj/project.pbxproj` together with the Swift
files. Build logs are written to `artifacts/build/`.

## Code map

| Location | Responsibility |
| --- | --- |
| `macos/Sources/App/` | App lifecycle, window, and user-action coordination |
| `macos/Sources/UI/` | AppKit views, drawing, themes, inputs, animations, and menu bar |
| `macos/Sources/Core/` | State, profiles, routing policy, session credentials, and helper updater |
| `macos/Sources/Bridge/` + `native/src/AppBridge.mm` | Swift/Objective-C++ bridge, XPC, Keychain, and helper registration |
| `native/src/Engine.mm` | OpenVPN sessions, connect/reconnect/disconnect, and statistics |
| `native/src/Network.mm` + `native/src/Connectivity.mm` | TUN, routes/DNS, ownership journal, and network changes |
| `native/src/Helper.mm` | Privileged service, XPC authorization, and sleep/wake notifications |
| `macos/CoreTests/`, `macos/VisualTests/`, `native/tests/` | Unit tests with synthetic data and frozen image references |
| `scripts/` | Prepare, Xcode synchronization, build, packaging, and test runners |

## Testing without opening the app

```sh
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy python3 scripts/native.py test
```

Core tests use fake XPC/Keychain, synthetic clocks, and temporary storage. UI
tests use offscreen AppKit/CoreGraphics without an NSWindow or application event
loop. Four native suites test policy, the OpenVPN parser, lifecycle, and network
ownership using fake dependencies. Tests do not start the root helper, modify
live routes/DNS/Keychain, or establish VPN connections.

Run Xcode build/test scripts sequentially because they share `macos/build`.
For focused changes, the UI runner accepts phases such as `behavior`, `theme`,
`energy`, and `performance`; see `rtk proxy python3 scripts/test_ui.py --help`.
Logs, `.xcresult` bundles, and image comparisons are written to
`artifacts/migration/`; CTest results are in `native/build/Testing/Temporary/`.
Runners verify test counts and reject skipped tests. Update the expected counts
when test coverage changes.

Native image comparisons use frozen references from the previous UI, targeting
at least **95%** matching pixels with a **2/255 per-channel** color tolerance for
dithering. Exact pixel differences are also reported. Results, coverage, and
validation limits are documented in `docs/NATIVE_MIGRATION.md`. References are
not application resources.

Actual windows, mouse/keyboard interaction, macOS approval, Keychain,
authentication, VPN traffic, sleep/wake, and Wi-Fi switching require manual user
verification through [docs/MANUAL_TEST.md](docs/MANUAL_TEST.md). Unit test results
do not establish live connectivity.

## Troubleshooting a stalled disconnect

If **Disconnect stalled** appears, choose **Retry disconnect**. The session is
not considered complete, and helper updates remain deferred until cleanup is
confirmed. If the error persists, record the Activity message and sample the
helper while it is still stuck:

```sh
rtk proxy sudo sample vuevpn-helper 5 10 -file /tmp/vuevpn-helper-disconnect.txt
```

Sampling only records thread activity. For an older helper version that is
already stuck, the user can perform a one-time service restart:

```sh
rtk proxy sudo launchctl kickstart -k system/com.vuevpn.helper
```

This disconnects **all VueVPN sessions**, including other profiles. It is a
manual recovery action, not part of routine builds, tests, or updates. Once the
helper responds again, quit the old app, replace it with the new build, and open
it manually. If recovery fails, retain the diagnostics for investigation. Do not
bulk-delete routes or delete the ownership journal.

## Support limits

Supported: IPv4 TUN with inline certificates/keys and PIN/password authentication.
TAP, external PKI, encrypted private keys, OTP/dynamic challenges, SSO, device
authentication, Pritunl dynamic firewall, scripts/plugins, proxies, and chained
external configurations are not supported. Specific errors are reported during
import or native validation before connecting.

## Uninstalling

Choose **App settings → Disable helper and disconnect all**, then Quit. Delete
`/Applications/VueVPN.app` afterward. Remove profiles through the UI first if you
also want their Keychain credentials deleted; original `.ovpn` files are
preserved. The helper's route journal at
`/var/run/com.vuevpn.helper/routes.json` stores route ownership only, without
credentials.

If route cleanup fails, the app reports an error and does not claim cleanup has
finished. Complete cleanup or helper recovery before deleting the app; see the
troubleshooting section above.
