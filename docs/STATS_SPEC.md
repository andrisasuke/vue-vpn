# VueVPN system Stats specification

Date: October 30, 2026.

Approved follow-up, November 2, 2026: [Stats menu-bar Label / Icon
plan](STATS_TRAY_STYLE_PLAN.md). The two styles defined there extend this
specification; other customizable menu-bar layouts remain out of scope. This
follow-up is implemented in this workspace; live appearance and energy verification remain user-run.

Status: implemented in this workspace and verified by unsigned compilation and
hostless/offscreen tests. Live device accuracy, placement, and energy checks
remain with the user under the confirmed testing boundary. The companion
implementation record is [STATS_PLAN.md](STATS_PLAN.md). Issue publication still
awaits the project's Matt Pocock skills tracker configuration.

## Problem Statement

The user wants to see the Mac's CPU, RAM, internal SSD, and network activity
without leaving VueVPN or keeping another monitoring application open. VueVPN
currently exposes VPN-session traffic and duration, but has no machine-wide
monitoring pages or system metric items in the macOS menu bar.

The feature must remain lightweight while providing useful realtime readings.
Monitoring must not introduce constant process scans, unnecessary network probes,
unbounded history, repeated layout work, or interference with VPN operations.

## Solution

Add a Stats section beneath Workspace and before the profile list in the existing
sidebar, containing CPU, RAM, SSD, and Network pages. Use the information shown in
the user's Stats reference screenshots, styled with VueVPN's native theme.

Display all four metrics in the macOS menu bar when no visibility preferences
have been saved. Clicking a visible metric opens
the corresponding page in the VueVPN window. Stats works independently of VPN
connections and helper availability. Aggregate readings remain current while the
window is hidden; expensive details run only while their page is visible.

Normal headline sampling is once per second. Low Power Mode changes Stats
headlines to once every two seconds. Fixed-size, memory-only history and one
shared sampling schedule keep work bounded. Actual energy impact must be measured;
this specification makes no zero-consumption or unmeasured battery-life claim.

## User Stories

1. As a Mac user, I want a Stats section below Workspace, so that system monitoring is easy to find inside VueVPN.
2. As a Mac user, I want separate CPU, RAM, SSD, and Network pages, so that I can inspect one resource at a time.
3. As a Mac user, I want the existing profile list to remain reachable by scrolling, so that adding Stats does not obstruct VPN management.
4. As a Mac user, I want Stats to work without a VPN connection, so that I can inspect ordinary laptop activity.
5. As a Mac user, I want aggregate Stats to work without enabling the VPN helper, so that monitoring does not require administrator privileges.
6. As a Mac user, I want Stats to follow VueVPN's Light, Dark, and System themes, so that monitoring feels part of the application.
7. As a Mac user, I want readable layouts at the default and minimum window sizes, so that I can inspect Stats on a small display.
8. As a keyboard and accessibility user, I want named controls and keyboard navigation, so that I can operate Stats without relying on chart colors or a mouse.
9. As a Mac user, I want CPU, RAM, SSD, and Network metrics visible in the menu bar initially, so that I can monitor them without opening the window.
10. As a Mac user, I want CPU and RAM usage and SSD used capacity displayed as percentages, so that I can recognize resource pressure quickly.
11. As a Mac user, I want separately identifiable download and upload rates in the menu bar, so that I can distinguish transfer direction.
12. As a Mac user, I want clicking a menu-bar metric to open its matching Stats page, so that I can move directly from an overview to details.
13. As a Mac user, I want menu-bar readings to keep updating after I close the window, so that monitoring remains useful in the background.
14. As a VPN user, I want the existing VPN menu and connection actions to remain stable, so that system monitoring does not disrupt connection management.
15. As a Mac user, I want CPU total, system, user, and idle readings, so that I can distinguish the main sources of CPU use.
16. As an Apple Silicon user, I want per-core bars and efficiency/performance group usage, so that I can understand work distribution across the processor.
17. As a Mac user, I want a CPU usage history chart, so that short spikes remain visible after they pass.
18. As a Mac user, I want system uptime and one-, five-, and fifteen-minute load averages, so that I have context beyond an instantaneous CPU percentage.
19. As an Apple Silicon user, I want CPU frequency details when supported, so that I can inspect processor behavior without assuming every Mac exposes the same information.
20. As a Mac user, I want the five highest-CPU processes, so that I can identify likely causes of high usage.
21. As a Mac user, I want RAM used percentage and memory pressure, so that I can distinguish memory occupancy from operating-system pressure.
22. As a Mac user, I want App, Wired, Compressed, Free, used memory, and swap values, so that I can understand the components of memory use.
23. As a Mac user, I want a RAM history chart and segmented usage display, so that I can recognize trends and the composition of usage.
24. As a Mac user, I want the five largest memory consumers, so that I can identify applications using the most RAM.
25. As a Mac user, I want the internal SSD hosting macOS monitored first, so that the main storage device is represented consistently.
26. As a Mac user, I want SSD total, used, available capacity, and used percentage, so that I can assess actual space remaining.
27. As a Mac user, I want reclaimable SSD space distinguished from currently free space, so that the displayed usage does not assume cleanup has already happened.
28. As a Mac user, I want SSD read and write speeds and a history graph, so that I can recognize sustained storage activity.
29. As a Mac user, I want the five most active disk-I/O processes with clearly stated measurement scope, so that I can investigate storage activity without misleading volume attribution.
30. As a Mac user, I want Network to follow the active physical Wi-Fi or Ethernet connection automatically, so that its default reflects the underlying network link.
31. As a Mac user, I want to select another available interface manually, so that I can inspect a specific connection when necessary.
32. As a Mac user, I want the selected interface name shown alongside its readings, so that I know what the rates represent.
33. As a VPN user, I want physical-interface and tunnel counters kept separate, so that the same transfer is not counted twice in the main Network reading.
34. As a Mac user, I want current download and upload rates and a direction-labelled history graph, so that I can recognize transfer patterns.
35. As a Mac user, I want cumulative transfer totals tracked separately per interface during the application session, so that interface changes do not mix unrelated totals.
36. As a Mac user, I want returning to an interface to restore its session totals, so that switching the displayed interface does not reset its accumulated usage.
37. As a Mac user, I want transfer totals reset when VueVPN is restarted, so that the accounting period is understandable and requires no persistent traffic database.
38. As a Mac user, I want interface status, available physical address, and local IP addresses, so that I can inspect basic connection details without Location permission.
39. As a Mac user, I want public IP fetched automatically when monitoring starts or the interface/VPN state changes, so that the reported egress address reflects the current connection context.
40. As a Mac user, I want a manual public-IP Refresh action and last-updated time, so that I can retry a lookup and assess the age of its result.
41. As a Mac user, I want stale, pending, and unavailable public-IP states to be explicit, so that an old address is not presented as freshly verified.
42. As a Mac user, I want connectivity history, latency, and jitter for a configurable target, so that I can inspect reachability with a known measurement destination.
43. As a Mac user, I want connectivity checks every five seconds while Network is visible, so that the detailed view provides current reachability information.
44. As a Mac user, I want three consecutive failed probes to report the target as unreachable, so that one lost response is not treated as proof that all internet access is down.
45. As a Mac user, I want unmonitored connectivity periods marked explicitly when the page is hidden, so that pauses are not mistaken for failures or successes.
46. As a Mac user, I want the five highest-traffic processes with clearly stated measurement scope, so that I can investigate network activity without assuming unsupported interface attribution.
47. As a Mac user, I want five minutes of recent chart history, so that I can inspect short-term behavior without retaining long-term monitoring data.
48. As a Mac user, I want history kept in memory and cleared on application restart, so that Stats does not continually write a monitoring database to disk.
49. As a Mac user, I want sleep and measurement interruptions shown as gaps, so that missing measurements are not represented as zero usage.
50. As a Mac user, I want normal headline readings refreshed approximately every second, so that the interface feels realtime.
51. As a battery-conscious user, I want headline sampling reduced to every two seconds in Low Power Mode, so that monitoring wakes the application less often.
52. As a battery-conscious user, I want process lists refreshed every three seconds normally and every five seconds in Low Power Mode only while their page is visible, so that expensive inspection has a bounded cost.
53. As a battery-conscious user, I want SSD capacity refreshed every thirty seconds, so that slowly changing storage values do not require one-second filesystem queries.
54. As a battery-conscious user, I want CPU frequency sampling restricted to the visible CPU page, so that advanced readings do not create a permanent background workload.
55. As a battery-conscious user, I want one shared sampling schedule and snapshot for the menu bar and pages, so that showing the same metric twice does not duplicate collection work.
56. As a battery-conscious user, I want unchanged labels and invisible pages to avoid unnecessary redraws, so that realtime data does not force full-window rendering.
57. As a Mac user, I want sampling suspended during sleep and resumed without replaying missed ticks, so that wake does not create a burst of catch-up work.
58. As a Mac user, I want slow reads and external requests prevented from overlapping or building a backlog, so that a slow system does not cause growing resource use.
59. As a Mac user, I want unavailable or inaccessible data identified honestly, so that missing hardware support is not disguised as a measured zero.
60. As a Mac user, I want accessible processes shown without extra administrator permission, so that process details do not expand the VPN helper's responsibilities.
61. As a Mac user, I want no Wi-Fi name display or Location permission prompt in this version, so that monitoring includes only the agreed network details.
62. As a Mac user, I want a separate Show in menu bar control on each Stats page, so that I can hide an unneeded tray item without losing that page's current readings or history. My choices should persist across restarts.
62. As a VPN user, I want Stats failures and sampling workloads isolated from VPN operations, so that connection, disconnect, and helper recovery remain responsive.
63. As a Mac user, I want monitoring stopped cleanly when the application quits, so that no Stats timers, tasks, or subprocesses remain running.
64. As a maintainer, I want reusable Stats reader and calculation code adapted with its license notices, so that established monitoring logic can be used responsibly.
65. As a maintainer, I want synthetic, hostless verification of sampling and presentation plus separate live energy measurements, so that automated test results are not mistaken for proof of battery performance.

## Implementation Decisions

### Native integration and reuse

- Keep the existing Swift/AppKit application, supported Apple Silicon/macOS
  deployment target, bundle identity, profile storage, credentials, and VPN
  helper contracts. Stats is app-wide and does not depend on a connected profile.
- Adapt the reference application's macOS readers and calculations. Extract the
  needed logic from its framework-specific types instead of adding its complete
  module, settings, widget, persistence, or helper infrastructure as a dependency.
- Reuse chart geometry or drawing logic where it fits VueVPN's renderer. Use
  VueVPN theme roles, typography, accessibility, control behavior, and retained
  rendering patterns for the resulting UI.
- Preserve MIT copyright and permission notices and any additional notices on
  adapted source. Include the notices in distributed application resources.
- Introduce a cohesive System Stats service with a narrow injectable platform
  dependency boundary. It owns lifecycle, cadence, current snapshot, bounded
  history, visibility demand, interface identity, and request generations.
- Keep UI state on the main actor. Collect blocking system/process readings on
  dedicated bounded execution resources. Slow Stats detail work must not occupy
  the VPN backend executor or block the next aggregate read.
- Constructing the Stats service, views, or menu controllers starts no live work.
  Application lifecycle explicitly starts and stops monitoring and installs or
  removes real status items.

### Navigation, pages, and menu bar

- Add CPU, RAM, SSD, and Network destinations below a Stats sidebar section.
  Preserve Overview, Activity, App settings, profile actions, and scroll access
  to the complete profile list.
- Present the agreed CPU, RAM, SSD, and Network details from the user stories.
  Chart and detail layouts must work at both default and minimum window sizes.
- CPU page: total and system/user/idle usage, per-core bars, efficiency/performance
  grouping, usage history, system uptime, load averages, optional supported
  frequencies, and top processes. CPU temperature and fan controls are excluded.
- RAM page: pressure gauge, percentage, history, segmented App/Wired/Compressed
  breakdown, used/free memory, swap, and top processes.
- SSD page: the internal macOS storage filesystem's name, capacity breakdown,
  used percentage, read/write rates, throughput history, and process I/O details.
- Network page: direction-labelled rates/history, connectivity history,
  per-interface totals, interface/status/physical address/local addresses, public
  addresses with lookup state, target-labelled latency/jitter, interface choice,
  probe-target setting, Refresh action, and process traffic details.
- All four metric items are visible by default. The intended compact arrangement
  follows the reference: RAM, SSD, Network, CPU. CPU/RAM/SSD align each small label
  and the entire usage percentage to the same left edge; Network stacks download above upload with direction
  indicators and explicit rate units. Items use compact fixed widths sized for
  their supported formats, so ordinary updates do not shift neighboring items. Exact
  system-controlled status-item placement is not
  guaranteed by the application.
- Each page has an accessible Show in menu bar checkbox for that metric. All
  four default to on when no preference exists. Save each choice independently;
  hiding an item releases its tray space but leaves aggregate collection, page
  details, histories, rates, totals, and other Stats settings untouched. Re-show
  the item with the latest formatted reading and its existing click destination.
- Clicking a metric selects its page and opens/activates the existing window,
  including restoring a minimized window. No Stats popovers are required.
- Preserve the original VPN status item and its menu behavior. Stats updates do
  not rebuild the VPN menu or mutate menu entries while that menu is tracking.
- Application pages follow VueVPN's selected appearance. Menu-bar text follows
  macOS appearance and remains readable across supported menu-bar backgrounds.
- Initial/loading, stale, unavailable, and insufficient-data states are distinct
  from measured zero. Use the application's English UI vocabulary, including
  labels equivalent to "Unavailable" and "Not monitored".

### Sampling and energy policy

| Work | Normal mode | Low Power Mode | Visibility/lifecycle rule |
| --- | --- | --- | --- |
| CPU/RAM/Network headline counters and relevant rate history | About 1 second | About 2 seconds | Continue while only menu-bar items are visible |
| SSD read/write rates and rate history | About 1 second | About 2 seconds | Share the aggregate schedule; avoid repeated device discovery |
| SSD capacity | 30 seconds | 30 seconds | Reuse the last valid result between reads |
| Top five processes for the selected Stats page | 3 seconds | 5 seconds | Only while that page is actually visible |
| CPU frequency and additional expensive CPU details | Demand-driven, no faster than needed by visible updates | Follow reduced Stats cadence | Only while CPU is actually visible; one read in flight |
| Connectivity/latency/jitter probe | 5 seconds | 5 seconds | Only while Network is actually visible |
| Public-IP lookup | Start, relevant connection changes, or Refresh | Same events | No periodic public-IP polling; coalesce changes |

- These are best-effort cadences with timer tolerance, not hard realtime
  deadlines. A late operation is skipped or coalesced rather than queued.
- Use one shared scheduler/time source for collection deadlines, with slower
  duties derived from that schedule. UI surfaces consume the shared snapshot.
  Repeatedly opening a page or window cannot add duplicate schedules.
- Keep at most one collection in flight for each aggregate/detail/external
  operation. Detail collection must be bounded and isolated from aggregate work;
  a timed-out process listing cannot accumulate behind subsequent ticks.
- Visibility follows the established rendering policy: hidden, minimized,
  occluded, application-hidden, modal-covered, and display-asleep pages perform
  no detail work or page redraws. Aggregate menu-bar readings remain active when
  the window is merely hidden and the display is awake.
- Suspend periodic Stats work when the Mac/display sleeps. Cancel or invalidate
  unnecessary in-flight work. Resume once, reset rate baselines, and mark the
  interrupted period; never replay missed samples.
- Low Power Mode changes Stats cadence only. Preserve the existing normal VPN
  connection animation in Low Power Mode and the existing Reduce Motion rules.
- Update retained chart/metric surfaces at sample cadence. Stable geometry,
  sidebar/header content, and unchanged formatted labels do not need rebuilding.
  Avoid per-frame chart animation and repeated image/font/process-icon creation.
- Bound all histories, per-process state, cached devices, pending work, request
  retries, and rendering caches. Do not persist sample history or traffic totals.
- Record measured performance and the measurement conditions. No arbitrary CPU
  percentage or battery-duration result is asserted before measurement.

### Measurement semantics

- Calculate CPU utilization from counter deltas. Overall CPU is normalized to
  0–100% across the machine; per-core values are individually 0–100%. Process
  CPU conventions must be clearly labelled when one-core percentages can exceed
  the machine-wide display's range.
- Derive RAM used, App, Wired, Compressed, Free, pressure, and swap consistently
  from operating-system counters. Used memory includes App, Wired, and Compressed;
  cache/reclaimable categories must not be double-counted.
- Use actual filesystem free space for SSD used percentage. Reclaimable or
  purgeable estimates do not count as space already free. APFS shared capacity
  and physical-driver I/O must each be represented once, without summing shared
  volumes or counting a driver multiple times.
- Compute Network and SSD rates as byte-counter differences divided by actual
  monotonic elapsed time. Handle initial samples, counter resets, wrap/invalid
  values, device changes, and sleep without false spikes or negative rates.
- Automatically select the active underlying physical Wi-Fi/Ethernet interface;
  a VPN default route must not make automatic mode sum a tunnel with its physical
  carrier. Manual mode may select another supported interface with clear identity.
- Read interface counters together where possible. Track baselines and session
  totals per interface identity. Switching the displayed interface does not mix
  totals or discard an existing interface's totals. Newly observed interfaces
  begin with a baseline rather than importing traffic predating monitoring.
- Charts retain the last five elapsed minutes with bounded storage, including
  correct timestamps when cadence changes. Gaps represent sleep, unavailable
  samples, or paused probes; zero is reserved for a valid zero measurement.
- Process lists show up to five accessible processes ordered by the page's
  relevant metric. Disk and Network lists show both transfer directions. Clearly
  label system-wide process I/O if the available reader cannot attribute it to
  the selected disk or interface. Do not imply unsupported filtering.
- Unsupported hardware-specific data and inaccessible processes do not prevent
  aggregate Stats from working. Missing frequency remains unavailable rather
  than being substituted with a nominal or invented measured value.

### Connectivity and public IP

- The initial probe destination is 1.1.1.1 and the user may change it in Network.
  Validate target input; do not treat it as a shell command or a request to change
  system networking. Probes use normal operating-system routing.
- Display the probe target. Three consecutive failed probes establish that
  target as unreachable; do not assert that every internet destination is down.
  Reset target-specific state after changing the target or connection context.
- Define latency and jitter consistently from successful timed samples. Until
  there is enough valid data, show an insufficient-data state. Missing responses
  are not zero-latency samples. Preserve explicit unmonitored periods.
- Public-IP lookups use a documented HTTPS provider behind the injectable
  platform boundary. Fetch public IPv4/IPv6 where available and distinguish an
  unavailable address family from a failed or pending lookup. Provider selection
  and response validation are implementation verification tasks, not a dependency
  on the reference application's complete networking module.
- Refresh public IP on monitoring start, active interface/address changes, and
  VPN connection/disconnection/reconnection context changes. Coalesce event
  bursts, bound timeouts/retries, and cancel or discard stale-generation replies.
- Retain a manual Refresh action and last-successful-update time. A connection
  change marks old values stale immediately; failed replacement requests must
  not make the old value appear current.
- Public IP describes the lookup request's current routed egress. Merely
  selecting an interface for counters does not bind external requests to that
  interface or bypass the VPN. Stats never changes routes or DNS for monitoring.
- Do not collect or display Wi-Fi SSID. Do not request Location permission.
  External lookups and probes send no profile, credential, private-key, or token
  information, and their expected destinations must be documented.

## Testing Decisions

- Prefer one new high-level platform boundary beneath the System Stats service.
  Inject a fake platform environment containing deterministic readings, clock
  control, probe/lookup outcomes, and completion control. Exercise the public
  service through start/stop, page-demand, power/sleep, interface, VPN-context,
  and Refresh events, then assert published snapshots and observable work.
- The user confirmed this boundary before authorizing worker implementation.
  It follows the existing injected backend, fake bridge/storage/clock, and
  explicit lifecycle patterns. Avoid creating a protocol for every individual
  OS call.
- Good tests verify observable behavior: which data is published, whether
  expensive reads occur while hidden, whether a stale reply is discarded, and
  whether totals/rates remain correct. They should not mirror private helper
  functions, lock selection, timer implementation, or view substructure.
- Cover service construction without work, idempotent lifecycle, normal and
  Low Power cadences, 30-second capacity refresh, detail visibility, one read in
  flight, skipped overdue work, sleep gaps, wake baselines, and bounded history.
- Cover CPU/RAM arithmetic with synthetic platform readings; elapsed-time rates;
  selected-interface and counter-reset behavior; retained per-interface totals;
  APFS/physical-driver deduplication; partial/unavailable readings; top-five order
  and real attribution labels; and explicit separation from VPN-session totals.
- Cover the initial, stale, refreshing, failed, and current public-IP states;
  startup and interface/VPN events; event bursts; timeout/retry bounds; obsolete
  response completion; and independent IPv4/IPv6 outcomes without real requests.
- Cover probe cadence only while Network is visible, target validation, three
  consecutive failures, recovery, target/context reset, latency/jitter handling,
  and unmonitored history gaps without sending real packets.
- Reuse existing presentation and hostless/offscreen AppKit seams for all four
  pages, menu metric formatting, click-to-destination actions, accessibility,
  theme changes, default/minimum sizes, unavailable values, and chart gaps.
- Extend the existing energy tests with bounded memory/cache assertions,
  unchanged-value no-redraw behavior, no hidden-detail work, and no unrelated
  workspace rebuilds. Use the existing CPU-time benchmark style to report Stats
  sampling/presentation costs separately from process details.
- Keep the existing VPN menu stability and Low Power/Reduce Motion tests. Retain
  frozen-reference checksums, 95% similarity expectations, and existing tolerance.
  Add synthetic Stats fixtures without replacing old references to hide failures.
- No automated test launches VueVPN, creates live test windows, installs real
  menu-bar items, starts/registers the helper, connects a VPN, alters networking,
  accesses real credentials, or contacts public-IP/probe services.
- Live menu placement, actual appearance, measurement accuracy, active-network
  transitions, battery/energy impact, and device-specific API support remain
  user-run verification. Hostless CPU results do not establish battery life.

## Out of Scope

- Packaging, installation, commits, pushes, issue publication, or live testing
  without a separate user request. Implementation, compilation, and the agreed
  hostless tests are authorized for the assigned worker.
- Stats popovers, customizable menu-bar layouts, extra widgets, and a new global
  Stats preferences surface.
- External-disk monitoring, SMART/SSD-health reporting, CPU temperature, fan
  control, sensors, and additional privileged capabilities.
- Wi-Fi names/SSID, protected Wi-Fi details, and Location permission requests.
- Long-term history, monitoring databases, persisted traffic totals, exports,
  quota accounting, alerts, and notifications.
- Process termination/actions, guaranteed visibility into every process, and
  unsupported per-interface or per-volume process attribution.
- VPN-session statistics redesign, bandwidth limiting, speed tests, kill switch,
  route/DNS changes, or new VPN helper commands/protocol requirements.
- A promise of zero battery drain, a guaranteed energy score, or a numeric CPU
  budget presented as already verified.

## Further Notes

- Implementation uses `SystemStatsService` with one injected platform environment,
  native aggregate readers, bounded visible-page detail work, four AppKit pages,
  retained chart paths, and separate menu-bar status items. The original VPN
  helper and wire protocol were not changed.
- Unsupported Apple Silicon live frequency and unavailable reclaimable/driver or
  protected-process readings display Unavailable. TCP port 443 is the defined
  connectivity probe; its result describes the configured target only.
- Hostless results and unsigned compilation are recorded in the plan. No live
  monitoring accuracy or battery measurement has been performed by the agent.

- Product choices above synthesize the completed conversation. The most recent
  corrections take precedence: public IP updates automatically on connection
  context changes; SSID is excluded; Low Power Mode slows Stats; probes stop when
  Network is not visible.
- Reference: exelban/Stats, inspected in the user-provided local clone at
  `~/Data/programs/stats`, clean revision
  `21f866bb3e8ba606c9c01769f558accbcf1fa27c`. The four module readers, popup
  callbacks, menu widgets, chart primitives, and reader scheduling were examined.
- The five screenshots are content and interaction references. VueVPN's native
  theme and existing application layout remain the visual integration target.
- Source adaptation must retain MIT copyright (2019 Serhiy Mytrovtsiy), permission
  text, and additional source notices where applicable. Record the adapted
  revision and components in the implementation's third-party documentation.
- Repository inspection found no project glossary or ADR collection. Existing
  terms such as Workspace, App settings, VPN helper, Snapshot, profile, session,
  and RenderingEnvironment are used according to the current native code.
- GitHub Issues is enabled for the repository, but no Matt Pocock skills tracker
  configuration or ready-for-agent label was found. Run
  `/setup-matt-pocock-skills` before publishing through the to-spec workflow.
  No issue or label is created by this documentation change.
