# VueVPN development

Build, signing, source layout, and hostless test details.

[Back to README](../README.md)

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
verification through [manual checks](MANUAL_TEST.md). Unit test results
do not establish live connectivity.
