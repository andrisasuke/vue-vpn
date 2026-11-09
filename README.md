# VueVPN

A personal OpenVPN client for **macOS 26+ on Apple Silicon**, built with
Swift/AppKit and embedded OpenVPN 3 Core.

- Import `.ovpn` profiles with PIN/password authentication and optional Keychain storage.
- Use one full IPv4 tunnel or compatible simultaneous split tunnels.
- Monitor CPU, RAM, SSD, and Network with live charts and menu-bar controls.
- Choose Light, Dark, or System appearance.

## Setup and build

Install **full Xcode 26 (Swift 6)**, Python 3, and Homebrew. Open Xcode once to
finish setup, and ensure `xcode-select -p` points to full Xcode.

Run from the cloned repository root:

```sh
brew install cmake asio openssl@3 lz4
python3 scripts/package.py
```

Packaging requires an **Apple Development** or **Developer ID Application**
certificate and its private key in Keychain. It selects the identity automatically
when exactly one matches; otherwise set `VUEVPN_SIGNING_IDENTITY` to its SHA-1.
Keep the same signing Team for updates.

The script downloads the pinned OpenVPN Core, builds the app/helper, bundles
libraries, and signs the result at **`artifacts/VueVPN.app`**. It does not launch
the app, register the helper, or notarize the package.

Node.js, npm, Rust, and the OpenVPN CLI are not required. On the original
developer workspace, prefix shell commands with `rtk proxy`; other Macs do not
need RTK.

## Run and update

1. Copy `artifacts/VueVPN.app` to `/Applications` and open it.
2. Choose **App settings → Enable VPN helper**.
3. If prompted, approve VueVPN in **System Settings → General → Login Items &
   Extensions**, then click **Refresh status**.
4. Import an `.ovpn` profile, review its routing, and connect.

Closing the window keeps the app and VPN running in the menu bar.
Use **Quit VueVPN** to disconnect and exit.

For updates, quit, replace the app, and reopen it. Helper updates are automatic
after active connections disconnect; routine updates do not require toggling the helper.

## Development and tests

```sh
# Compile without signing; output lacks the complete VPN helper bundle.
python3 scripts/build.py

# Build a complete signed package with a Debug Swift app.
python3 scripts/package.py --configuration Debug

# Run tests sequentially without opening the app or connecting a VPN.
python3 scripts/test_core.py
python3 scripts/test_ui.py all
python3 scripts/native.py test
```

Edit `macos/VueVPN.xcodeproj`. After adding or removing Swift files, run
`python3 scripts/sync_sources.py` and include the generated project changes.

## Limits and documentation

IPv4 TUN only. IPv6 is neither tunneled nor blocked; there is no kill switch.
TAP, SSO, OTP/dynamic challenges, and encrypted private keys are unsupported.

- [User guide](docs/USER_GUIDE.md): Stats, profiles, routing, local data, updates,
  troubleshooting, and uninstalling.
- [Development guide](docs/DEVELOPMENT.md): build/signing details, code map,
  test commands, and logs.
- [Manual checks](docs/MANUAL_TEST.md) · [Migration notes](docs/NATIVE_MIGRATION.md) ·
  [Third-party notices](docs/THIRD_PARTY.md) · [Agent instructions](AGENTS.md).
