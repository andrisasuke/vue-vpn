# Per-metric Stats monitoring enable/disable: analysis and plan

Date: November 2, 2026.

Status: implemented in this checkout. Monitoring choices are persisted per
domain and applied before startup; selective readers, cancellation and drain,
fresh baselines, disabled states, and effective tray visibility are wired.
Hostless verification: `test_core.py` passed 126 tests, `test_ui.py all` passed
47 tests, and `build.py` passed unsigned Debug compilation. The tests include
all 16 domain combinations, held and cancelled fake operations, fresh rate and
Network total baselines, timer lifecycle, and offscreen controls. They do not
establish live network behavior, actual window appearance, or energy impact.
This extends [STATS_SPEC.md](STATS_SPEC.md), [STATS_PLAN.md](STATS_PLAN.md), and
the presentation choices in [STATS_TRAY_STYLE_PLAN.md](STATS_TRAY_STYLE_PLAN.md).

## Requested outcome

Each CPU, RAM, SSD, and Network page has its own persistent **Enable monitoring**
setting. Disabling a metric hides it from the menu bar and stops its Stats
collection, calculations, process inspection, and other background operations.
Other enabled metrics and VPN operations continue normally.

Keep **Show in menu bar** as a separate display preference. This preserves the
existing ability to monitor a metric in the window without showing it in the
tray. Both settings default to on for new users; existing visibility and
Label/Icon choices are retained.

| Enable monitoring | Show in menu bar | Outcome |
| --- | --- | --- |
| On | On | Collect the metric; show it in the tray |
| On | Off | Collect the metric for the window/history; hide its tray item |
| Off | Either saved value | No collection; hide its tray item; show a disabled page state |

Effective tray visibility is the intersection of enabled monitoring and the
saved visible-in-menu-bar set. Turning monitoring off must not overwrite the
visibility/style preferences. Turning it back on restores those preferences.

## Findings before implementation

| Area | Current behavior | Necessary change |
| --- | --- | --- |
| `StatsMenuVisibilitySettings` in `StatsMenuPresentation.swift` | Controls display only | Add an independent monitoring preference |
| `SystemStatsEnvironment.aggregate()` in `SystemStats.swift` | Returns all four domains in one reading | Allow genuinely selective domain collection |
| `readAggregate()` in `SystemStatsPlatform.swift` | Always calls `readCPU`, `readRAM`, `diskIdentityAndCounters`, and `readInterfaces` | Prevent disabled domain reads before native API work starts |
| `SystemStatsService.accept()` | Updates all domains, rates, and histories together | Merge only valid enabled-domain results |
| Scheduler in `SystemStatsService` | Wakes about every 200 ms while running; aggregate and capacity work are not per-domain enabled | Gate each operation; suspend the timer when all domains are disabled |
| Visible-page detail/frequency/probe scheduling | Checks page visibility | Require visibility and domain enablement |
| Startup/wake/VPN-context public-IP requests | Do not have a Network enable gate | Suppress requests while Network is disabled |
| Native cancellation | Detached reads and process readers propagate cancellation; probe connection has timeout/completion handling but no enclosing task cancellation handler | Ensure owned work actually cancels and drains, not just that its results are ignored |
| Application startup | Calls `stats.start()` after tray configuration | Load/apply monitoring choices before any collection or public-IP request |

Filtering values after the current all-domain aggregate call is insufficient:
the disabled metric would still be read and calculated. Cancelling a Swift task
also needs matching cleanup of its owned subprocess, connection, and callbacks.

## Proposed page and data behavior

- Keep each sidebar destination accessible when disabled so the user can
  re-enable it. Do not automatically enable it by opening its page.
- Put **Enable monitoring** above the display settings. Show a clear state such
  as **CPU monitoring is disabled** with an enabled control to resume.
- Replace live cards, charts, and process results with the disabled state while
  off. Distinguish Disabled from Unavailable, valid zero, and warming up.
- Disable the Show in menu bar and Label/Icon controls while monitoring is off,
  retaining their selected values and explaining that monitoring must be enabled.
- Network Refresh and interface/probe actions must not start work while disabled.
  Retain interface-selection preference and probe target for later use.
- Suppress disabled-page rebuilds caused by unrelated active-domain snapshots.
  Disabled pages still respond to theme, layout, and preference changes.
- When all Stats are disabled, remove/hide the Stats tray surface as appropriate
  to its current controller implementation. Preserve the separate VPN menu.

### Work stopped per domain

| Disabled domain | Stats work that must stop |
| --- | --- |
| CPU | CPU counter/delta collection, per-core/group/load/uptime updates, frequency requests, CPU process inspection, CPU history updates |
| RAM | VM/pressure/swap collection and calculations, RAM process inspection, RAM history updates |
| SSD | Disk discovery/counter collection, capacity refresh, read/write calculations, disk process I/O inspection, SSD history updates |
| Network | Physical-interface discovery/address/counter collection, rate/totals updates, Network process inspection, latency/jitter/connectivity probes, IPv4/IPv6 public-IP requests and Stats-specific context work |

These switches control VueVPN's Stats feature, not the operating system's own
counters or VPN traffic/session monitoring. Disabling CPU Stats does not promise
zero app CPU usage. Disabling Network Stats does not disconnect or stop the VPN.
Do not change the helper, VPN polling, routes, DNS, or credential handling.

### History, totals, and resuming

- Clear live values and process lists for the disabled domain; do not present
  its last reading as current or substitute zero.
- Retain bounded, memory-only pre-disable history with one Disabled gap marker;
  do not append samples or schedule expiry work while disabled. Prune by elapsed
  time on the next relevant event/resume and keep the 301-point cap. Disabled
  history is not rendered as live data.
- On re-enable, resume from fresh counter baselines. First delta-based values
  show Collecting/Unavailable until a valid second sample. Never average CPU or
  byte rates across the disabled interval and never replay missed ticks.
- Retain Network's already observed per-interface session totals in memory, but
  exclude traffic during disabled intervals. Reset the baseline, not the stored
  pre-disable total. Clarify the UI wording as traffic observed while monitoring
  was enabled; app restart still resets totals.
- Preserve process I/O baseline correctness too: discard pre-disable process
  baselines and establish fresh ones before showing resumed rates.
- Re-enable Network with fresh interface/address state and one coalesced public-IP
  refresh using the current VPN context. Resume probes only when Network is
  actually visible. Old public-IP values cannot reappear as fresh results.
- Re-enable SSD with a fresh capacity request. CPU/RAM snapshots refresh without
  resetting any other metric's data, history, or deadlines.

## Collection and cancellation design

Keep one high-level `SystemStatsEnvironment` boundary and one shared scheduler.
Replace the all-domain aggregate contract with explicit per-domain sampling
requests and a typed result identifying its domain. This allows the service to
own one in-flight headline task per enabled domain without four independent
timers. Keep capacity, processes, frequency, probe, and public-IP operations
behind the same environment boundary.

- Normal headline cadence remains 1 second, Low Power 2 seconds. Keep existing
  visible-detail 3/5 seconds, SSD capacity 30 seconds, and visible Network probe
  5 seconds. Only enabled work contributes scheduler deadlines.
- Use a generation per domain plus operation identity for in-flight ownership.
  Disabling a domain invalidates its results without invalidating other domains.
- Apply enabled checks before scheduling, before expensive reader steps, and
  before accepting a completion. Late results cannot restore data/tray state or
  clear the handle of a newer task.
- Cancel only the disabled domain's work. Shared detail demand must use the
  enabled visible page; leaving it selected while disabled requests no work.
- Serialize each domain's reader state. A brief synchronous OS call already in
  progress may finish; it must not proceed to further disabled work. Discard its
  result, drain the task, then reset baselines before another enable generation
  reads. Avoid a stale cancelled reader mutating newly reset baselines.
- Own and terminate only Stats subprocesses, with bounded cleanup and output
  draining. Tailor process-command columns/work to the enabled visible domain
  so RAM inspection does not request CPU process statistics unnecessarily.
- Give Network probes cancellation-aware connection/timeout ownership with
  exactly-once completion, including cancellation before connection setup ends.
  Cancel Stats public-IP requests through their owned tasks; do not leave a
  timeout, connection, continuation, or subprocess alive after teardown.
- When all domains are disabled, cancel the shared Stats timer and pending Stats
  deadlines/tasks. Do not leave a loop waking only to return early. Once owned
  cleanup completes there is no scheduled Stats work until an enable event.
- Track application lifecycle separately from collection demand: all-disabled
  is not application shutdown. Re-enable restarts exactly one scheduler only if
  lifecycle is active, automatic scheduling was requested, and the device is
  awake. Preserve manual fake-clock mode without creating a real timer.
- Sleep/display sleep and wake never re-enable a disabled domain. VPN/interface
  context changes, manual actions, Low Power, visibility changes, and repeated
  start/stop must obey the same enable gates. A retained last VPN context is
  sufficient while Network is disabled; it must trigger no Stats network work.

## Ordered implementation plan

1. **Preferences and domain state.** Add a small injectable persisted monitoring
   settings owner, default on, with separate keys such as
   `stats.monitoring.enabled.<page>`. Add explicit disabled/collecting state to
   presentation/snapshots. Preserve visibility/style preferences and constructors
   without live operations.
2. **Selective platform contract.** Split all-domain aggregate collection into
   domain-specific operations at the existing environment seam. Adapt native
   readers and fakes, with per-domain baseline reset and non-overlap ownership.
   Make production call paths themselves selective; do not merely filter a
   result from `readAggregate()`.
3. **Demand-aware scheduler and lifecycle.** Load enabled state before start;
   implement per-domain deadlines/generations, selective snapshot/history merge,
   detail gating, and timer suspension when all domains are disabled. Keep active
   metrics' cadence and existing navigation-preservation behavior unchanged.
4. **Cancellation and resumption.** Finish native subprocess/probe/HTTP cleanup,
   reject obsolete results, reset only affected baselines, exclude disabled
   traffic, and coalesce Network restart/context refresh. Cover rapid toggles
   and enabling while prior cancellation is still draining.
5. **UI/tray wiring.** Add per-page monitoring controls through application
   actions, propagate saved state before tray installation/startup, and derive
   effective visibility. Add disabled/collecting screens, control availability,
   accessibility, and observed-traffic wording. Integrate with the current tray
   layout implementation; do not revert the separate spacing work.
6. **Verification and documentation.** Add meaningful service/fake-platform and
   offscreen coverage below; update exact runner counts, README, manual guidance,
   and actual results. Sync sources/project only if Swift files are added/removed.

Primary integration points: `macos/Sources/Core/SystemStats.swift`,
`SystemStatsService.swift`, `SystemStatsPlatform.swift`, existing Stats preference
types in `StatsMenuPresentation.swift`, `macos/Sources/App/NativeApplication.swift`,
and `StatsPanel.swift`, `WorkspaceChrome.swift`, `WorkspaceScene.swift`,
`WorkspaceView.swift`, `StatsMenuBarController.swift` under `macos/Sources/UI/`.
Keep reader/operation policy in Core, not in drawing or tray visibility code.

## Observable acceptance and tests

Use the existing fake platform/clock as the primary behavior seam, extended with
per-domain request counts, held completions, and observable cancellation/cleanup.

- Cover all 16 enabled-domain combinations. For each, assert only enabled native
  collection entry points are requested and only their histories/data advance.
  A fake all-domain read followed by filtered output cannot prove this property.
- Disabling each domain hides it and cancels all its related operation types;
  active domains preserve readings, cadence, histories, and baselines.
- Show in menu bar off alone still collects; Enable monitoring off stops it even
  when its page is open or its saved visibility is on. Restore saved style and
  visibility independently after enable/restart.
- Startup with disabled settings starts no forbidden reads/public-IP calls,
  including all-disabled startup. Missing settings default on.
- While Network is disabled, inject VPN/interface events, wake, Refresh, and page
  selection. Assert zero Network discovery/process/probe/public-IP work. On
  enable, assert a fresh coalesced lookup and correct visible-only probe demand.
- Hold every relevant operation, disable/re-enable rapidly, then release old
  results out of order. Assert no stale publication, cleared-new-task ownership,
  overlapping same-domain reads, revived tray content, or baseline contamination.
- Verify cancellation reaches owned fake subprocess/HTTP/probe resources and
  continuations complete exactly once. Test the production cleanup logic through
  controlled resources without network access or live process inspection.
- Large fake elapsed intervals while disabled add no readings, replay, totals,
  rate spikes, or duplicate timers. CPU, SSD, Network, and process rates restart
  from fresh baselines; monitored Network totals exclude disabled traffic.
- All-disabled state has no scheduled Stats timer after cleanup, and time/power/
  sleep/visibility events do not restart it. Enabling one module restarts only
  that work; stopped lifecycle and manual-clock mode never start real timers.
- Offscreen pages at default/minimum sizes and Light/Dark show accessible enable
  controls, saved disabled display options, Disabled/Collecting/Unavailable
  distinctions, and no live chart/process/refresh action while disabled.
- Preserve navigation, Low Power, sleep/wake, original VPN menu, tray spacing,
  icon geometry, styles, per-metric destinations, and frozen visual references.

Run the appropriate checks sequentially during implementation:

```sh
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy python3 scripts/build.py
```

Use focused Stats/energy checks while developing; broaden/repeat only when a new
change or unresolved concern warrants it. Report real counts/results; update
runner expectations for tests actually added. Preserve thresholds/checksums.

## Scope and handoff boundary

Implementation is in the current checkout. Existing tray-spacing work was
retained. The checks above are hostless; the user-run checks below remain.

Future implementation verification uses fakes, hostless/offscreen tests, and
unsigned compilation. Do not launch VueVPN, create real test windows/status
items, automate live UI, operate helper/VPN, alter routes/DNS/Keychain, or contact
real probe/public-IP services. Packaging, installation, commits, pushes, and PRs
remain outside this task.

Manual verification after implementation: disable/re-enable each domain with its
page open and window hidden, restart with mixed/all-disabled choices, verify
tray restoration, confirm disabled Network sends no Stats requests, and measure
idle/energy behavior under comparable conditions. Unit results establish requested
work/cancellation semantics, not a measured battery-life improvement or zero CPU.
