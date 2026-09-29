# VueVPN development guide for coding agents

## Start here

- Read `README.md` for setup, commands, supported behavior, and troubleshooting.
- Check `git status --short --branch` before editing; preserve unrelated changes.
- Read the relevant source/tests rather than treating migration notes as current
  implementation. `docs/NATIVE_MIGRATION.md` records visual baselines and past
  validation; `docs/MANUAL_TEST.md` describes checks performed by the user.
- VueVPN is a personal macOS Apple Silicon app. The current stack is
  **Swift/AppKit → Objective-C++/XPC → privileged helper → OpenVPN 3 Core**.
  The Vue, TypeScript, Rust, Tauri, npm, and Cargo application code was removed.
  Do not reintroduce a web UI, frontend server, or OpenVPN CLI dependency.
- In this workspace, prefix shell commands with `rtk proxy` (or the appropriate
  RTK wrapper). RTK is a developer tool, not an application dependency. On other
  machines without RTK, the underlying commands work directly. Honor any local
  user instructions about command wrappers.

## Where changes belong

| Area | Entry points |
| --- | --- |
| App lifecycle/window/actions | `macos/Sources/App/NativeApplication.swift` |
| UI and rendering | `macos/Sources/UI/WorkspaceView.swift`, `WorkspaceScene.swift`, `ConnectionPanel.swift`, `ConnectionLayers.swift` |
| Input, dialogs, theme/menu | Other files in `macos/Sources/UI/`; preferences and menu state in `macos/Sources/Core/` |
| State and operations | `macos/Sources/Core/WorkspaceModel.swift`, `VPNBackend.swift`, `BackendWorker.swift` |
| Profiles and routing validation | `macos/Sources/Core/ProfileParser.swift`, `ProfileStore.swift`, `Policy.swift`; `native/include/Policy.hpp` |
| Helper updates | `macos/Sources/Core/HelperUpdater.swift`, `native/src/AppBridge.mm` |
| Bridge/wire contract | `macos/Sources/Bridge/`, `macos/Sources/Core/BridgeProtocol.swift`, `native/include/Protocol.h` |
| VPN lifecycle and statistics | `native/src/Engine.mm` |
| TUN/routes/DNS/physical link | `native/src/Network.mm`, `Connectivity.mm`, `native/include/RouteTable.hpp` |
| Privileged service and sleep/wake | `native/src/Helper.mm` |

Keep UI/model work on the main actor. Blocking XPC, storage, and service work
belongs on the serial `BackendWorker` executor. Tests inject bridge, clock, and
storage dependencies; constructing models must not start live system operations.

## Build and test

Run from the repository root. Current targets require macOS 26+, arm64, full
Xcode 26/Swift 6, Python 3, and the Homebrew dependencies listed in README.

```sh
rtk proxy python3 scripts/native.py prepare
rtk proxy python3 scripts/build.py
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/native.py test
rtk proxy python3 scripts/test_ui.py all
```

- `build.py` defaults to Debug and only compiles the unsigned app. It does not
  produce a complete VPN-capable bundle.
- `test_core.py` runs hostless Swift unit tests with fake XPC/Keychain and a fake
  clock. `native.py test` runs four suites without live VPN/network mutations.
- `test_ui.py` runs hostless AppKit unit/image tests without a window or app
  event loop. Use a relevant phase (`behavior`, `theme`, `energy`, `performance`,
  etc.) for focused changes; `--configuration Release` is available.
- Run Xcode build/test scripts sequentially: they share `macos/build`.
- After adding/removing Swift files, run `rtk proxy python3 scripts/sync_sources.py`
  and include the generated `project.pbxproj` diff. The generator rewrites target
  membership/settings; update the generator too when changing generated sections.
- Runners enforce expected test counts. Update `scripts/test_core.py` or the
  relevant counts in `scripts/test_ui.py` when adding/removing tests; do not
  disable the count/skip checks to make a failed run pass.
- Run tests appropriate to the change. Documentation-only edits need path,
  command, and diff checks rather than an application build or full test run.

For a signed bundle, when packaging is part of the task:

```sh
rtk proxy python3 scripts/package.py
# Debug Swift app, with the native helper still built in Release:
rtk proxy python3 scripts/package.py --configuration Debug
```

Packaging requires an Apple Development or Developer ID Application identity
with its private key. It auto-selects exactly one matching identity, otherwise
use `VUEVPN_SIGNING_IDENTITY`. Preserve the signing Team across updates. Output:
`artifacts/VueVPN.app`. Packaging verifies signatures and bundled dependencies;
it neither installs the app nor starts/registers the helper. Prefer a full build
over `--skip-build` unless the compiled outputs are known to match the sources.

## Testing boundary

The user performs live app/VPN testing. During development, use unit tests and
compilation only, including the existing hostless/offscreen tests. Do not launch
VueVPN, open test windows, run UI automation, start/register/restart the helper,
connect a VPN, mutate live routes/DNS/Keychain, or copy builds into `/Applications`
as a test. Live recovery commands in README are for user-run troubleshooting,
not automated verification. An explicit user request for a live operation is a
separate task; do not infer it from a request to fix code or build a package.

## Invariants to preserve

- Preserve bundle ID `com.vuevpn.desktop`, helper service `com.vuevpn.helper`,
  XPC signing/active-console-user checks, and protocol compatibility across
  app/helper updates. The UI must not run as root.
- Preserve existing profile storage and Keychain service
  `com.vuevpn.desktop.credentials`. Save remembered secrets only after a successful
  connection. Never log raw profiles, passwords/PINs, private keys, or server tokens.
- Keep IPv4 routing semantics: one full tunnel, compatible split profiles,
  overlap checks, and ownership-based cleanup. Internal DNS controls remain
  hidden; preserve stored DNS settings and backend handling when editing profiles.
- Never report successful disconnect or release ownership solely because a
  deadline expired. Close the transport before releasing its bypass routes.
  Clean up only VueVPN-owned routes; do not flush the route table or delete the
  ownership journal to hide an error.
- Each attempt has its own latched asynchronous stop token. Preserve token
  lifetime through Core destruction, signal outside the session mutex, and keep
  `OPENVPN_IO_REQUIRES_STOP` unless replaced by an equivalently tested mechanism.
  Disconnect must not depend exclusively on `clock_tick()` or restart other profiles.
- A disconnect stalled for 30 seconds remains active and offers Retry disconnect.
  Helper updates must wait for active sessions and successful cleanup. Preserve
  bounded helper update/recovery retries and do not re-enable a deliberately
  disabled helper automatically.
- Maintain the established native layout, icons, Light/Dark/System themes, input
  alignment, and clickable-control cursors. Visual baseline target is at least
  95% similarity with the documented tolerance. Do not lower thresholds or replace
  frozen references just to hide regressions.
- Keep animation on retained Core Animation layers with bounded caches. Avoid
  per-frame workspace rebuilds. Preserve visibility/Reduce Motion gating;
  Low Power Mode intentionally retains normal animation.

## Repository and handoff

- Keep `design/`, `vendor/`, build outputs, signing material, and real VPN profiles
  untracked. Synthetic test references under `macos/VisualTests/References/` are
  tracked inputs, not application resources. Preserve their manifest checksums.
- OpenVPN is pinned by `scripts/native.py`. Put upstream edits in tracked
  `native/patches/`, document them there, and verify fresh prepare can apply them;
  editing ignored `vendor/` alone does not deliver a fix.
- Update README for changed commands/behavior and `docs/MANUAL_TEST.md` for new
  live scenarios. Keep third-party notices when adapting external source.
- Before handing off, check the diff and report actual tests/builds, output path,
  and remaining manual verification. Unit/offscreen results do not establish
  live connectivity, battery usage, or actual window appearance.
- Commit/push/create PR when requested or covered by the current task; do not
  merge a PR merely because the user says they intend to merge it themselves.
