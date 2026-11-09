# VueVPN system Stats implementation plan

Date: October 30, 2026.

Approved follow-up, November 2, 2026: [Stats menu-bar Label / Icon
plan](STATS_TRAY_STYLE_PLAN.md). This addendum is planned only and extends the
original menu-bar scope with independent per-metric style choices.

Status: implementation completed in this workspace; unsigned compilation and
hostless/offscreen regression pass. Product requirements are in
[STATS_SPEC.md](STATS_SPEC.md). Live operations remain outside the confirmed
testing boundary and await user-run verification.

## Implementation outcome

| Slice | Result |
| --- | --- |
| 1. Contract/provenance | One `SystemStatsEnvironment` seam; native reader adaptations attributed to Stats commit `21f866bb3e8ba606c9c01769f558accbcf1fa27c` with bundled full MIT notice |
| 2. Scheduling | Shared 1/2-second aggregate schedule, 3/5-second visible process schedule, 30-second capacity, 5-second visible probe, cancellation/generation checks, five-minute/301-point history, and bounded interface/process state |
| 3. Readers | Mach CPU/VM, root APFS capacity, cached IOKit driver counters, physical Wi-Fi/Ethernet counters and addresses; unavailable readings remain explicit |
| 4. Pages | Stats sidebar, four theme-aware pages, native controls, accessible summaries, scrollable minimum-size layouts, retained chart paths |
| 5. Menu/lifecycle | Four initially shown metric status items with changed-value updates, per-page persisted visibility, and page/window actions; original VPN menu retained |
| 6. Public IP/probe | Event-driven IPv4/IPv6 ipify HTTPS requests with stale-reply rejection; configurable TCP/443 target probe while Network is visible |
| 7. Detail/frequency | Bounded visible-page process reads, system-wide disk/network scope labels; live frequency honestly Unavailable without a supported public API |
| 8. Handoff | README, manual checklist, notices, source membership, exact test counts, and synthetic hostless benchmark updated |

Original delivery checks: `scripts/test_core.py` 111/111, `scripts/test_ui.py all`
42/42, `scripts/test_ui.py performance --configuration Release` 2/2, and
`scripts/build.py` passed. The per-metric visibility follow-up passed Core
114/114, UI all 43/43, and the unsigned Debug build. The least similar frozen
image remained 98.805%, above
the unchanged 95% requirement; frozen references and checksums were preserved.
The Release hostless benchmark recorded 0.0060 CPU seconds for 300 synthetic
snapshot/history/menu iterations and 0.0477 CPU seconds for 30 visible CPU-page
draws. History was 300 points (hard limit 301); the image cache used 141,840
bytes of its 33,554,432-byte limit. These timings exclude live native reads,
subprocesses, WindowServer, VPN activity, and battery impact.

Unsigned build: `macos/build/Build/Products/Debug/VueVPN.app`. No package,
installation, app launch, helper operation, network probe/request, commit, push,
PR, or issue publication was performed. Device-specific readings, menu placement,
actual connectivity, and energy remain for the user-run checklist below.

## Delivery approach

Build a native, app-wide System Stats service that adapts the established reader
and calculation logic from exelban/Stats. VueVPN owns lifecycle, sampling demand,
energy policy, snapshots, history, navigation, drawing, and status items.

Deliver in the ordered slices below. Each slice states a reviewable outcome and
its verification. Files described as new are proposed locations; retain coherent
module boundaries if implementation reveals a better fit. Update source
membership after adding files, and keep Xcode builds/tests sequential.

No web UI, runtime dependency on the reference app, separate monitoring helper,
or change to VPN behavior is required.

## Current integration points

| Area | Existing code or test seam | Planned change |
| --- | --- | --- |
| Lifecycle and action routing | `macos/Sources/App/NativeApplication.swift` | Explicit Stats start/stop, status-item install/remove, page activation, connection-context events |
| Screen state and navigation | `macos/Sources/Core/WorkspaceModel.swift` | Add Stats destinations without making VPN state the owner of machine counters |
| Sidebar and page presentation | `macos/Sources/UI/WorkspaceChrome.swift`, `WorkspaceScene.swift`, `WorkspaceView.swift` | Stats section, scroll/layout changes, synthetic-data page presentation, dynamic metric updates |
| Native drawing and appearance | `macos/Sources/UI/ThemePalette.swift`, existing drawing/cache primitives | Reuse semantic colors, retained surfaces, bounded resource caches |
| Visibility | `macos/Sources/UI/RenderingPolicy.swift` and workspace lifecycle observers | Publish visible-page demand; pause detail work for hidden/occluded/modal/display-asleep states |
| VPN menu | `macos/Sources/UI/MenuBarController.swift`, `macos/Sources/Core/MenuPresentation.swift` | Preserve existing menu equality/tracking; keep Stats metric drawing separate |
| Core behavior tests | `macos/CoreTests/WorkspaceTests.swift`, `MenuTests.swift`, fake backend/clock conventions | Deterministic Stats lifecycle and external behavior tests |
| Hostless UI and energy tests | `macos/VisualTests/SceneTests.swift`, `ThemeTests.swift`, `EnergyTests.swift`, `PerformanceTests.swift` | Add Stats presentation, visibility, bounded-work, and CPU-time coverage |
| Source membership and expected counts | `scripts/sync_sources.py`, `scripts/test_core.py`, `scripts/test_ui.py` | Include new sources/resources and enforce actual added test counts |
| Notices and handoff | `docs/THIRD_PARTY.md`, `macos/Resources/ThirdPartyLicenses/`, `README.md`, `docs/MANUAL_TEST.md` | Attribution, feature behavior, external destinations, and manual scenarios |

## Confirmed testing boundary

Use one new injectable platform environment beneath the System Stats service.
The environment supplies readings, time/scheduling control, and external
probe/public-IP outcomes. Its production adapter owns native API integration and
bounded subprocesses where required. A deterministic fake controls completion,
including slow, failing, and out-of-order results.

The highest behavior seam is the service's public lifecycle/events and published
snapshot/history. Tests should start or stop monitoring, change page demand,
advance fake time, change interface/VPN context, complete a fake operation, and
assert what a user can see or what work was requested. Avoid a different mock
interface for every system function.

UI tests continue using existing synthetic presentations, offscreen AppKit
rendering, and injected RenderingEnvironment. Real status-item installation and
live collection remain explicit production lifecycle steps. Narrow pure-math or
buffer tests may support edge cases, but they do not replace service-level
behavior coverage.

The user has confirmed this testing boundary. Implement against it without
reopening the completed product interview or requesting the same confirmation.

## 1. Establish reference provenance and the service contract

Dependencies: testing boundary confirmed (complete).

Work:

- Record the inspected reference revision
  `21f866bb3e8ba606c9c01769f558accbcf1fa27c` and the specific adapted components.
  The local reference working tree was clean when planning.
- Review the source imports and notices at extraction time. Include the full MIT
  license in bundled third-party resources and update `docs/THIRD_PARTY.md` when
  adapted source enters the application.
- Propose cohesive Core types for CPU, memory, disk, interfaces, processes,
  timestamped histories, and individual availability/freshness states. Suggested
  new files are `SystemStats.swift` and `SystemStatsService.swift` under Core.
- Separate app-wide system statistics from the existing VPN `Snapshot` and
  `Session` counters. The workspace may consume both without changing the app/
  helper wire contract.
- Define service inputs for lifecycle, visible page, Low Power Mode, sleep,
  interface selection, probe target, VPN connection context, and manual Refresh.
- Define the injected platform environment and deterministic fake at the service
  seam. Store settings through a small injectable preference dependency if needed,
  following existing preferences; do not store sample histories or totals.
- Keep construction inert. No initializer reads live counters, starts timers,
  installs status items, or sends requests.

Verification/output:

- Core tests instantiate the service without live side effects and can provide
  synthetic readings and advance time through the proposed boundary.
- A coherent contract can represent unavailable/partial/stale readings and
  history gaps without zero-filled placeholders.
- Adapted code has complete provenance and bundled notices.

## 2. Implement bounded scheduling and energy policy

Dependencies: slice 1.

Work:

- Implement one scheduler with timer tolerance and monotonic timestamps. Derive
  1/2-second aggregate, 3/5-second process, 30-second capacity, and 5-second probe
  deadlines from it. Use completion-aware skips; never accumulate missed ticks.
- Collect on execution resources independent of the VPN BackendWorker. A slow
  process command, frequency sample, or HTTP request must not block the main
  actor, delay disconnects, or prevent subsequent cheap aggregate samples.
- Permit at most one operation in flight per collection kind. Bound concurrent
  detail work to the visible page, with cancellation, generation checks, and
  timeouts. Repeated visibility events cannot start duplicate schedules.
- Make Low Power Mode affect Stats only. Preserve existing VPN animation and
  Reduce Motion behavior.
- Derive detail demand from actual workspace visibility, including occlusion,
  minimization, application hiding, modal coverage, and display sleep.
- Suspend periodic work during system/display sleep. On resume, reset rate
  baselines and record a gap rather than replaying missed ticks.
- Add elapsed-time-based five-minute ring buffers. At normal cadence the
  maximum is approximately 300 aggregate samples per series; enforce both time
  expiry and a hard bound. Keep all histories in memory.
- Bound per-interface/device state and icon caches, remove vanished resources
  safely, and stop timers/tasks/subprocesses on explicit service stop.

Verification/output:

- Fake-clock tests cover cadence changes, capacity reuse, hidden detail/probe
  suppression, slow reads across multiple ticks, stop/restart, and sleep/wake.
- Advancing a long synthetic session demonstrates bounded history and pending
  work. Tests observe requested work and published data rather than private
  scheduler internals.

## 3. Adapt native aggregate readers and establish correct metrics

Dependencies: slices 1–2.

Work:

- Add a production platform adapter, suggested as `SystemStatsPlatform.swift` in
  Core with cohesive native-reader helpers where needed. Audit Swift 6 Sendable,
  native buffer ownership, and Mach/IOKit resource release.
- CPU: adapt Mach counter sampling and delta arithmetic, CPU grouping, uptime,
  and load averages. Prefer native calls over launching commands for basic
  aggregate data. Detect supported E/P groups rather than hard-coding a chip.
- RAM: adapt virtual-memory counters, pressure and swap reads, and consistent
  App/Wired/Compressed/Free calculations. Handle invalid counts and failed reads
  without publishing invented values.
- SSD: identify the internal macOS filesystem, collect actual capacity/free
  values, and resolve its underlying I/O driver. Cache discovery and invalidate
  on device changes. Count APFS shared capacity and driver counters once.
- Network: discover physical service/interface identity independently from a
  VPN default route. Read interface counters together; retain baselines and
  session totals by identity. Provide automatic and manual selection without
  combining carrier and tunnel traffic.
- Use actual monotonic elapsed time for all byte-rate calculations, including
  Low Power Mode, timer tolerance, delayed reads, and post-wake baselines.
- Handle new/disappearing devices, counter resets, address changes, unsupported
  data, and selection changes without false spikes, negative speeds, or totals
  from before monitoring began.
- Keep native API details behind the agreed environment rather than exposing
  platform handles to presentation code.

Verification/output:

- Synthetic service scenarios establish known CPU/RAM values and byte rates at
  1-second, 2-second, and irregular intervals.
- Interface switching and counter resets preserve the specified totals and
  avoid double counting. Shared-disk fixtures exercise driver deduplication.
- Native integration compiles without starting the application or sampling the
  developer's actual machine as a test.

## 4. Deliver native Stats navigation and four themed pages

Dependencies: slices 1–3; use synthetic snapshots while readers are being built.

Work:

- Add Stats destinations to screen/action presentation and route selection
  without changing the selected VPN profile or triggering backend operations.
- Insert the Stats section beneath Workspace and before profiles. Update sidebar
  content height and scroll behavior so all profiles and Import remain reachable.
- Build reusable retained chart/metric surfaces, suggested as `StatsPanel.swift`
  and `StatsLayers.swift` under UI. Adapt suitable chart geometry with notices;
  use VueVPN theme roles, fonts, spacing, and drawing caches.
- Render all four content sets in the specification, including CPU per-core
  bars, RAM pressure and segments, SSD direction-labelled I/O, and Network
  connectivity grid and controls.
- Keep geometry separate from changing values. Update metric/chart surfaces
  rather than rebuilding the whole workspace on each sample; preserve control
  identity, keyboard focus, scrolling, and hit regions.
- Give each chart a fixed memory/time bound, explicit unit/direction labels,
  unavailable values, and visible gaps. Support accessible text equivalents.
- Supply visible-page demand to the service through the existing rendering
  environment. Showing cached data must not require detail collection offscreen.
- Retain the default 960×720 and minimum 800×600 window behavior.

Verification/output:

- Hostless behavior/theme tests render CPU/RAM/SSD/Network with synthetic data
  at both sizes, including long process names and missing readings.
- Energy tests prove no hidden page redraw, no unrelated workspace rebuild for
  metric updates, and stable controls/focus through value changes.
- Preserve frozen references/checksums and the current 95% similarity tolerance.
  Review intended sidebar additions explicitly; do not regenerate references,
  lower thresholds, or silently exempt broad regions to conceal regressions.

## 5. Add menu-bar metrics and lifecycle integration

Dependencies: slices 2–4.

Work:

- Introduce a separate Stats metric presentation/controller, suggested as
  `StatsMenuPresentation.swift` in Core and `StatsMenuBarController.swift` in UI.
  Avoid routing one-second values through VPN menu reconstruction.
- Install all four status items explicitly at application launch. Render compact
  two-row RAM/SSD/CPU labels left-aligned with their percentages and stack Network download/upload
  rates with direction indicators and readable units, following system menu-bar
  appearance.
- Render only changed formatted values, reusing text resources and compact
  per-item fixed widths. Bound the largest rate format so unit transitions do
  not clip or shift neighboring items.
- Add one accessible Show in menu bar checkbox per Stats page and a small
  injectable preference store. Default all four to on; toggle only the chosen
  item, preserving its slot and the latest metric for restoration. Tray visibility
  must not control the Stats service or any page data/history.
- Map each metric click to its Stats destination and activate/restore the existing
  VueVPN window. Do not create popovers or a second application window.
- Keep the existing VPN status item, active-menu deferral, and connection actions
  intact. Aggregate monitoring continues when the main window is closed.
- Start Stats only from the explicit application lifecycle. Remove status items,
  observations, and monitoring work on actual application termination.

Verification/output:

- Pure presentation and hostless rendering tests cover values, units,
  unavailable states, and click destination mapping without installing status items.
- Fake-store and hostless UI checks cover independent persisted choices, all
  hidden, restored latest values, accessible controls, and continuing Stats
  publication without real status items.
- Existing VPN menu stability tests still pass while Stats snapshots change.
- Explicit lifecycle checks ensure inert controller construction and idempotent
  installation/removal semantics; real placement/clicks remain user verification.

## 6. Add connection-aware public IP and visible-page probes

Dependencies: slices 1–5.

Work:

- Implement external requests through the platform environment, using a native
  asynchronous HTTP client for public IP. Select and document a suitable HTTPS
  provider, response contract, address validation, timeout, and bounded retry
  policy before integration. Do not send profile or credential information.
- Fetch available public IPv4/IPv6 on monitoring start and after active physical
  interface/address or meaningful VPN session-context changes. Observe context
  transitions rather than treating unchanged one-second VPN snapshots as events.
- Coalesce event bursts, invalidate obsolete generations, and prevent parallel
  lookup storms. Preserve manual Refresh and successful update timestamps.
- Immediately mark an old public IP stale after relevant changes; reject late
  responses for previous contexts. Show refreshing, stale/error, or unavailable
  states independently for each address family.
- Label public IP as current routed egress. Manual counter selection must not
  bind lookups to an interface, bypass a VPN, or mutate routes/DNS.
- Adapt a bounded connectivity probe for the default target 1.1.1.1, plus target
  validation/editing. Run every five seconds only while Network is visible.
- Define and test successful-sample latency/jitter behavior and insufficient-data
  states. Three consecutive failures mark that target unreachable. Reset
  target/context state and mark hidden/sleep intervals as unmonitored gaps.
- Include no Wi-Fi SSID reader, Location request, or protected Wi-Fi detail UI.

Verification/output:

- Fake network tests cover cold start, interface/VPN transitions, repeated events,
  manual Refresh, timeout/retry bounds, stale completions, and separate IPv4/IPv6
  success/failure without contacting external services.
- Probe tests cover visibility, three-failure transitions, recovery, target
  validation, sample arithmetic, and gaps with no real ICMP/HTTP traffic.

## 7. Add bounded process details and optional CPU frequency

Dependencies: slices 2–4; Network process presentation also uses slice 6 states.

Work:

- Adapt process discovery/readers for CPU, RAM, disk I/O, and Network. Prefer
  native process counters where practical. Any necessary subprocess is bounded,
  cancellable, and started only for a visible detail page.
- The reference uses ps/top/nettop for several lists. In particular, nettop may
  take longer than a three-second refresh; skip subsequent scheduled reads while
  it is still running, enforce timeout, and clean up on page exit/stop.
- Return at most five ranked processes with stable identity and direction-labelled
  I/O. Bound identity/icon caches and counter baselines, handle exited processes,
  and skip inaccessible processes without elevation.
- Verify the real attribution scope of disk and Network readers. Where only
  system-wide process I/O is available, label it accordingly; do not suggest it
  is filtered to the page's selected volume/interface.
- Adapt the CPU frequency reader through a small optional runtime-supported
  platform bridge if needed. Check the reference's additional notices and
  deployment compatibility. A missing API must not become an app launch/link
  failure or a prerequisite for aggregate Stats.
- Avoid copying the reference's permanently scheduled multi-sample frequency
  workload. Run it only on visible CPU demand, with no overlapping sampling,
  and reuse its latest value between completions.
- If a native bridge/framework is needed, update the source generator and target
  configuration together. Preserve hostless test linking and the VPN bridge
  contract; do not add monitoring commands to the privileged helper.

Verification/output:

- Synthetic tests cover top-five sorting, directions, exited/inaccessible
  processes, actual scope labels, cancelled/slow reads, Low Power cadence, and
  zero detail requests while pages are hidden.
- Unsupported-frequency fixtures render Unavailable and leave other metrics
  functional. Native compatibility is established by compilation plus subsequent
  user-run hardware verification, not assumed from a successful fake test.

## 8. Complete regression, energy evidence, and handoff documentation

Dependencies: slices 1–7.

Work:

- Update README with Stats navigation, menu behavior, cadence/Low Power policy,
  interface/traffic semantics, public-IP external service, probe target, and
  limitations. Preserve the distinction between Stats cadence and VPN animation.
- Extend `docs/MANUAL_TEST.md` with the checklist below. Retain existing manual
  energy targets and disclose that the agent has not performed live measurement.
- Update source membership and exact expected test counts for added tests. If a
  new Stats UI phase is needed, add it to the runner with a checked count; ensure
  the all-phases run includes it.
- Run focused checks after the corresponding slices, then one final full core/UI
  regression and compilation pass. Broaden native/helper testing only if the
  implementation actually changes those components or their contracts.
- Add a bounded hostless CPU-time benchmark for aggregate-snapshot plus menu
  rendering separately from visible process/frequency details. Record actual
  numbers, sample conditions, allocations/cache bounds, and limits of the result.
- Inspect the complete diff, third-party resource inclusion, unchanged frozen
  checksums, source generation, and documented external destinations.
- Report delivered files, actual test/build commands and results, build output,
  and remaining user-run verification. Packaging is a separate requested action;
  this feature plan does not authorize installation or live launch.

## Verification commands for implementation

Run from the repository root, sequentially when using Xcode-derived outputs.
These are planned commands, not results from this documentation task.

```sh
rtk proxy python3 scripts/sync_sources.py
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py behavior
rtk proxy python3 scripts/test_ui.py theme
rtk proxy python3 scripts/test_ui.py energy
rtk proxy python3 scripts/test_ui.py performance --configuration Release
rtk proxy python3 scripts/build.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy git diff --check
```

The unsigned compile output is
`macos/build/Build/Products/Debug/VueVPN.app`; it is not a complete VPN-capable
package. When packaging is separately requested, the signed bundle output is
`artifacts/VueVPN.app`. Neither artifact is launched or installed by these checks.

## User-run verification after implementation

| Scenario | Expected observation |
| --- | --- |
| Open each Stats page with VPN disconnected/helper disabled | Machine metrics still work; no administrator or Location prompt |
| Menu bar with window open/closed/minimized | All four metrics remain readable; clicking selects/restores the matching page |
| Toggle Show in menu bar on each Stats page | Only that item leaves/returns; choices survive restart; pages keep updating even when all four items are hidden |
| Light/Dark/System, default/minimum size, scrolling, keyboard/accessibility | Native styling, readable details, reachable profiles and controls, no focus loss |
| Normal mode versus Low Power Mode | Stats headlines change from about 1s to 2s; process details from 3s to 5s; VPN animation retains its prior behavior |
| Network open versus hidden or another page | Rates continue in menu bar; probes/process details stop with explicit history gaps |
| Wi-Fi/Ethernet change and manual interface selection | Correct physical default, explicit identity, retained separate totals, no doubled tunnel traffic |
| VPN connect/disconnect/reconnect and rapid network changes | Public IP becomes stale then refreshes; no request storm or old-context result replacing current data |
| Offline/probe-blocked/provider unavailable | Honest target/freshness states; no false global-internet diagnosis or fabricated zero values |
| Sleep/wake and display sleep | Sampling pauses, no catch-up spike, correct history gaps and rate baselines |
| SSD/APFS and process detail comparison | Capacity/driver not duplicated; units/scope explicit; values plausible against system tools |
| Quit and reopen | No retained Stats tasks/subprocesses; histories and traffic totals reset |
| Release idle/menu-bar-only, each visible page, LPM, and VPN traffic | Record app CPU, helper/subprocess CPU, WindowServer, Energy Impact, and duration under comparable conditions |

For energy evaluation, compare a pre-Stats baseline and the implemented Release
build under the same workload, display state, connection context, and power mode.
Use the existing manual CPU targets as regression checks, account for subprocess
and WindowServer work, and record a sufficiently stable observation interval.
Actual battery measurements and VPN connectivity remain user-run activities.

## Engineering risks and completion criteria

- **Private/hardware-specific frequency APIs:** isolate support detection and
  optional linking; an unsupported reading is acceptable when shown honestly.
- **Process reader cost and attribution:** visibility gating, bounded duration,
  no overlap, honest system-wide labels, and comparative measurements are required.
- **APFS and tunnel accounting:** test shared identities and route/interface
  transitions; do not use heuristics such as blindly halving traffic under VPN.
- **Sampling versus rendering:** retain static geometry and existing VPN menu
  stability; demonstrate that offscreen updates produce no page rebuilds.
- **External lookups and probes:** document service/target, cap work, use normal
  routing, and discard old context. Test with fakes before user-run verification.
- **Battery claims:** consider the feature technically complete only when bounded
  work is demonstrated and actual results/remaining live measurement are reported;
  do not substitute hostless timings for a battery-life guarantee.

Completion means every in-scope user story is implemented or has the specified
honest unavailable state, required automated checks pass with exact counts,
notices/docs are current, and the manual verification boundary is clearly handed
off. Any change to agreed product scope needs an explicit updated decision.

## Tracker publication

GitHub Issues is enabled for `andrisasuke/vue-vpn`. During planning, no issue
tracker configuration for these skills or ready-for-agent label was found.
Run `/setup-matt-pocock-skills` to establish the tracker/triage vocabulary, then
publish the confirmed spec with ready-for-agent according to the to-spec workflow.
No tracker issue, label, commit, or pull request is authorized by this plan alone.
