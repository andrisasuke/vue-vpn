# Native macOS migration

Branch: `migration/native-macos`
Original UI revision: `c653eadfa02fef26bc6743b22b277adef8b5701b`
Acceptance updated by the user on September 20, 2026: **minimum 95% visual similarity**.

The native implementation replaces the active Vue/TypeScript and Rust/Tauri
stack. The application is Swift/AppKit with the existing Objective-C++ AppBridge,
privileged helper, and patched embedded OpenVPN 3 Core. The old sources, npm/Cargo
manifests, WebView implementation and temporary web reference generator have been
removed. There is no legacy UI fallback or archive in the active application.

## Preserved behavior and data

- Name, bundle identifier `com.vuevpn.desktop`, helper identity
  `com.vuevpn.helper`, Team-based XPC verification and wire protocol v1.
- Existing JSON profile format and location
  `~/Library/Application Support/com.vuevpn.desktop/profiles`, private directory
  and file permissions, and Keychain service `com.vuevpn.desktop.credentials`.
- Import, username/PIN/password, save only after successful connection, Forget,
  profile editing/deletion, Selected networks and All IPv4, simultaneous
  non-overlapping profiles, and hidden existing DNS settings.
- Serialized backend work off the main thread; immediate Connecting and
  Disconnecting states; helper update/recovery with bounded retries; cleanup
  before quit/delete or network changes.
- 960×720 initial / 800×600 minimum window, sidebar, Overview, Activity, settings,
  routing editor, dialogs, toasts, menu bar, exact original application icon,
  and exact original status-icon RGBA bytes in three states.
- Nonselectable static drawing, native editable fields with neutral selection,
  keyboard controls, modal focus containment/restoration, status/traffic updates,
  network line/pulse/breathe animations, and Reduce Motion.
- The network engine, route ownership journal, endpoint IPv4 patch, network
  transition handling, and sleep/wake recovery remain in the existing native code.

## Appearance and cursors

App settings includes Light, Dark and System choices above the helper card.
System is the default, including existing installations with no saved preference.
The global choice is stored in UserDefaults under `appearance.theme` and applies
immediately without backend commands. System follows the window's effective
macOS appearance, including when the hidden window is reopened. Explicit Light
and Dark choices override it. Menu bar icons and native menus follow macOS.

The renderer uses semantic colors, preserving the original Light RGB values and
providing green-charcoal Dark surfaces, neutral inputs and lime accents. Theme
changes reuse text controls and retain drafts, credentials, scroll positions and
animation timing. Enabled custom buttons use pointing-hand cursors, disabled
buttons use arrows, and editable inputs use I-beams. Cursor regions respect
clipping and suppress workspace controls while a modal covers them.

## Rendering energy

The connection panel uses retained Core Animation layers for line dash, pulse
and halo animations. There is no per-frame application timer or scene rebuild.
Static artwork, button feedback, traffic and duration update independently;
changing duration does not redraw the other statistics. A bounded 32 MiB LRU
stores shadow images, with separate bounded font and icon-path caches. Layer
contents are replaced when their size, theme, backing scale or relevant state
changes; entire scrolling pages are not stored in the production cache.

Visibility policy pauses animation for occlusion, minimization, application hide,
display/system sleep, modal coverage and scrolling the illustration out of view.
Hidden workspaces keep the latest model state without rebuilding scenes. Restore
applies current data once and resumes using the connection's monotonic epoch.
Low Power Mode deliberately keeps normal animation; Reduce Motion still applies.
Modal backdrops refresh on open, resize or theme changes, not traffic polling.
The energy changes leave backend polling and helper/network behavior unchanged.

## Disconnect lifecycle correction (September 25, 2026)

Each connection attempt now has a latched OpenVPN asynchronous stop token.
Disconnect and physical-network changes wake its reactor without depending on
the traffic clock callback. The token survives Core's teardown, and signaling
never holds the session mutex. `OPENVPN_IO_REQUIRES_STOP` exits the per-attempt
reactor after graceful shutdown; transport destruction still precedes final
bypass-route cleanup. No process-wide helper restart is part of this path.

After 30 seconds of observed Disconnecting, the app reports Disconnect stalled
and enables Retry disconnect in the window/menu. Ownership remains active until
the helper confirms completion. Synthetic tests cover cancellation before Core
registers its callback, cancellation without clock ticks, independent profiles,
and pending reactor work after graceful shutdown. A temporary build without
`OPENVPN_IO_REQUIRES_STOP` fails the pending-work regression assertion; the
production configuration passes. These tests do not establish which pending
operation caused the original live incident. Sleep/Wi-Fi verification is manual.

## Verification and its limits

The hostless Swift tests do not link the production bridge. Dependencies are
fake XPC/Keychain, synthetic clocks/data, temporary profile stores and in-memory
AppKit/CoreGraphics rendering. No test creates an NSWindow, starts the application
event loop, registers a helper, changes live Keychain/routes/DNS, or connects a VPN.

- Core: **102 unit tests**, including theme defaults, persistence, resolution,
  stalled-disconnect deadlines, safe retry and multi-profile ownership.
- Native UI: **36 tests** (8 reference rendering tests, 12 interaction/layout
  tests, 7 theme/cursor tests, 8 energy/layer tests and 1 CPU benchmark).
  Theme tests render both palettes at both window
  sizes and check contrast, control geometry, input identity and retained drafts.
- C++/Objective-C++: **4 suites**, covering policy, embedded parser, lifecycle
  and network ownership.
- Release package: compiled, app/helper/dependency signatures verified; app and
  helper Team IDs must match; build-machine library paths are rejected.
- All rendered comparisons pass the 95% threshold. The measured range is
  **98.805%–100%** with the comparison definition below.

The visual score is the percentage of pixels whose RGBA channels each differ by
at most **2/255**. This small color allowance accounts for gradient dithering
between WebKit reference pixels and CoreGraphics. A pixel with a larger difference
in any channel counts as a mismatch; at most 5% may mismatch. Every pixel inside
each declared comparison rectangle participates. Exact pixel differences are
also reported, and the frozen reference images have not been replaced.

| Compared content | Lowest similarity |
| --- | ---: |
| Full Overview: disconnected, connected, connecting | 99.923% |
| Welcome, Activity, helper settings, routing variations, minimum window | 99.923% |
| Connection panels | 99.894% |
| Sidebar, header, footer | >99.999% |
| PIN content | 99.953% |
| Profile editor, both routing modes | 99.349% |
| Delete dialog | 98.805% |
| PIN error dialog | 99.817% |

This is **not a claim that every live window/state has been measured**. Full-page
comparisons cover nine synthetic pages. The two settings comparisons cover the
unchanged helper content against its original reference crop; the new Appearance
card has separate layout/state tests and offscreen renders. Light comparisons
use the frozen originals; Dark is a new palette without a historical baseline.
Dialog comparisons cover their content
(the four additional dialogs use a one-point border inset). The backdrop blur,
outer modal shadow, macOS titlebar/traffic lights, live menu layout, focus/hover
appearance, live system-theme changes, stationary-pointer cursor refresh, all
intermediate animation frames, and arbitrary viewport/font-scale
combinations still need the user's visual review. Network animation timing and
menu presentation/icon data also have unit checks, but these do not replace live
interaction tests.

The actual window, macOS helper approval, upgrade of installed profiles/Keychain,
authentication, traffic, simultaneous tunnels, sleep/wake, and Wi-Fi changes
remain **manual acceptance**, as requested. See `docs/MANUAL_TEST.md`. The agent
has not opened the application or connected a VPN.

## Frozen reference provenance

Sixteen synthetic reference cases remain in `macos/VisualTests/References`.
The manifest records their original source commit, fixtures, dimensions and
SHA-256 hashes. They were captured before removing the old stack, using inert
Vue SSR from that commit and a nonpersistent, unattached WKWebView. Repeated
captures were checked for exact equality before freezing.

Environment: macOS 26.6.2 (25G83), Xcode 26.3, arm64, Aqua, 2× scale, sRGB.
Most viewports are 960×720 points; the minimum-size case is 800×600. Animations
were paused at phase zero. The native tests now need no Node, Vue or WebKit and
fail if any frozen input hash changes. References and comparison images are
not application resources.

## Reproduce

```sh
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy python3 scripts/test_ui.py all --configuration Release
rtk proxy python3 scripts/native.py test
rtk proxy python3 scripts/package.py
```

Optional UI phases: `native`, `panels`, `chrome`, `credentials`, `overview`,
`screens`, `dialogs`, `behavior`, `theme`, `energy`, and `performance`. The runners verify executed test counts
and reject skipped tests. Test logs, result bundles, expected/native/diff PNGs,
and numeric reports are written to `artifacts/migration`.

Use `performance --configuration Release` for a repeatable CPU benchmark. It
compares 90 frames of the original uncached full-scene drawing workload against
retained panel layers with three metric updates, at 2× scale. It includes cold
retained setup and software compositing of every frame, and requires at least
80% less process CPU time. The report is `energy/benchmark.json`; layer image
comparisons across themes, sizes and phases are in `energy/similarity.json`.
These are hostless measurements, not live CPU/GPU, WindowServer or battery tests.
The September 23, 2026 Release run measured 8.555 s versus 1.110 s process CPU
time (87.0% reduction). The 36 retained-panel comparison frames matched the
immediate renderer by at least 99.635% across both themes, sizes and three phases.
Live acceptance targets (<5% visible, <1% hidden over 60 seconds with light VPN
traffic) remain pending user testing, as described in `docs/MANUAL_TEST.md`.

`scripts/build.py` compiles an unsigned Debug app without a helper.
`scripts/package.py` builds Release by default (or `--configuration Debug`),
bundles the helper/libraries/licenses, signs and verifies in a temporary staging
directory, then replaces only the generated `artifacts/VueVPN.app`. It never
touches `/Applications` or registers/starts the helper. Use the packaged app
for manual testing.
