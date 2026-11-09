# Stats realtime summary cards plan

Date: November 2, 2026.

Status: proposed implementation plan. This task adds documentation only.

## Product outcome and scope

Add a compact live summary at the top of each CPU, RAM, SSD, and Network page,
following the four screenshots supplied by the user. CPU, RAM, and SSD use a
percentage ring beside a horizontal composition bar and a labelled legend.
Network uses two large live rate readings, Download and Upload, as shown in its
reference. Colors, surfaces, typography, and spacing belong to VueVPN's
Light/Dark/System themes.

The screenshots describe the latest sample, rather than a time-series chart.
The proposed default is to retain the existing five-minute history charts and
supporting details below these summaries. Replace redundant rows in the current
top cards instead of duplicating the same values above and below a new card.
User clarification: measurements already printed inside a summary/chart card
must not appear again as measurement text or key/value rows beneath it. Keep
the labels and legends inside the card, as in the references; lower sections
contain only history and additional information.
Keep the aligned monitoring/menu-bar controls and menu style choices above the
summary. Sidebar navigation and menu-bar artwork keep their current behavior.

The reference images are visual direction, not assets to ship. Implement native
vector drawing with AppKit/Core Animation, using real readings without hardcoded
hardware names, capacities, core counts, percentages, or interface speeds.

## Findings from the current implementation

| Area | Current source behavior | Consequence for this feature |
| --- | --- | --- |
| `StatsPanel.swift` | Four pages use key/value cards, CPU core bars, a RAM composition bar, and history charts | Replace the summary presentation; retain useful details and history |
| `SystemStats.swift` | CPU total/system/user/idle and core kinds; RAM categories; SSD capacity; Network rates already exist | Main summary values can reuse the current snapshot |
| CPU identity | `StatsCPU` has no chip/model display name | Add optional cached metadata with a generic fallback |
| SSD identity | Reader supplies an internal-device label; snapshot has no filesystem type or volume display name | Add optional volume metadata if matching the reference header; retain existing disk identity for counters |
| Sampling | Aggregate readings run about every 1 second, or 2 seconds in Low Power Mode; capacity runs every 30 seconds | Reuse these schedules; a capacity bar must not imply a new measurement every second |
| `StatsLayers.swift` | History charts retain their vector layers and skip identical surfaces | Extend this pattern for ring/bar summary artwork |
| `WorkspaceView.updateStats` | Any unequal Stats snapshot rebuilds visible Stats content through `rebuildContent()` | Compare page-relevant inputs and retain summary layers; unrelated domain samples should do no visible work |
| Current update test | `sceneBuilds` counts full workspace rebuilds, not content rebuilds | Add evidence at the content/layer seam; the existing counter alone cannot prove efficient summary updates |
| Lifecycle | Monitoring, sleep, page visibility, and Reduce Motion already have explicit policy | Integrate Stats transitions with these policies; Overview-only animation gating does not cover Stats automatically |

## Per-page design

| Page | Left/main visual | Header and composition | Legend and retained details |
| --- | --- | --- | --- |
| CPU | Ring with total busy percentage in the center; System and User arcs over an Idle track | Chip name when available; actual E/P core counts on the right. Bar: System + User + Idle | System, User, Idle percentages. Retain per-core usage, uptime, load, frequency availability, and five-minute CPU history below |
| RAM | Ring with used percentage; App, Wired, and Compressed arcs over a Free track | Used bytes on the left and Total bytes on the right. Bar: App + Wired + Compressed + Free | Four labelled categories, using two columns at normal/minimum widths. Retain memory pressure, swap, and history below |
| SSD | Ring with used percentage; Used arc over an available-capacity track | Actual volume name when available; filesystem and total capacity when available. Bar: Used + Available now | Used and Available now bytes. Retain reclaimable estimate, read/write rates, and read/write history below |
| Network | Two equal-width columns, each with a large number and smaller byte-rate unit | Download and Upload labels with direction glyphs and color keys; show selected physical interface nearby | Preserve interface selection, session totals, history, public IP, connectivity, and process details below |

Use **Available now** for SSD instead of copying the reference's **Free** label:
the existing reader's `available` value determines `used = total - available`.
Do not add reclaimable capacity to available space, or change filesystem
accounting while introducing the new UI. Device-driver I/O and filesystem
capacity remain separately identified. Omit the reference's small colored disk
dots unless a real, labelled status is defined for them.

All four summaries appear directly after the page's display settings. For
Network, put the existing Interface control just above its rate card. Supporting
details stay scrollable after the summary and history; preserve each page's
information without repeating the headline readings in a large key/value card.

Remove these duplicate measurement rows from the sections below each card:

- CPU: Total usage, System, User, and Idle percentages.
- RAM: Used bytes/percentage, Total, App, Wired, Compressed, and Free bytes.
- SSD: Used bytes/percentage, Available now, and Total capacity.
- Network: current Download and Upload rates.

This rule also applies to any later measurement added to a chart card. Retain
distinct information such as CPU per-core readings, RAM pressure/swap, SSD
read/write rates, and Network session totals. Historical plots still show the
metric over time, without a separate repeated latest-value text block below.

## Layout and theme

- Design for the actual app sizes: 960 x 720 default and 800 x 600 minimum.
  The content canvas is respectively 766/606 points wide; after the existing
  24-point side padding the card has 718/558 points available. Do not treat the
  screenshot's pixel dimensions as AppKit point sizes.
- Proposed card geometry: 16-point internal padding, 12-point corner radius,
  an approximately 88-point ring, and a 20-point gap before the text/bar area.
  Start with a 136-156-point card height, allowing RAM's two-row legend to use
  the taller variant. Confirm final geometry using offscreen output.
- Keep a fixed ring column. At the minimum width, wrap legends/metadata to
  another row before reducing text or clipping labels. Truncate long chip,
  volume, and interface names with accessible full values.
- Network reserves fixed number/unit space within each half. Use tabular digits
  and a stable unit column so transitions between B/s, KB/s, MB/s, and GB/s do
  not move labels or neighboring content. Preserve bytes-per-second semantics
  and the existing decimal unit convention; do not silently switch to bits/s.
- Draw ring segments from 12 o'clock clockwise, with the same category order in
  the bar and legend. Clip bar segments inside one rounded track. Avoid rounded
  internal caps that distort small categories or render dots for zero values.
- Use `palette.surface`, `border`, `text`, and `secondaryText` for the card.
  Add Stats-specific semantic series/track colors to `ThemePalette`, rather
  than hardcoding screenshot blue/red/orange in the renderer.

Proposed color mapping, to be checked in both themes:

| Semantic color | Light starting value | Dark starting value | Use |
| --- | --- | --- | --- |
| Stats primary | `#25674D` | `#D8EFAD` | CPU User, RAM App, SSD Used, Network Download |
| Stats secondary | `#4D8070` | `#83BDA1` | CPU System, RAM Wired, Network Upload |
| Stats tertiary | `#996331` | `#E4C28A` | RAM Compressed |
| Stats neutral track | `#DDE5DC` | `#3F5044` | Idle, Free, Available now, ring/bar background |

These are initial design values, not frozen references. Keep series colors
consistent between each card and its related history where the series has the
same meaning. Numeric labels and direction glyphs make the UI understandable
without depending on color. Memory pressure retains its separate status label;
an ordinary category color does not indicate a warning or error.

## Data and state rules

1. CPU uses the existing normalized fractions, not process percentages. System,
   User, and Idle come from one snapshot; total busy remains the reader's total.
   E/P counts derive from core kinds, with unknown topology described honestly.
2. RAM ring/bar share the same App/Wired/Compressed/Free byte values and total
   as the numeric labels. Retain the current memory calculation. Compute visual
   fractions before rounding text; do not reconstruct fractions from GB labels.
3. SSD ring/bar use the same total and available values as its labels. Capacity
   updates on the existing 30-second cadence, including the existing fresh-read
   lifecycle. Read/write rates continue on the aggregate cadence.
4. Network uses current selected physical-interface rates from the service,
   without adding VPN tunnel counters. Actual zero is `0 B/s`; a missing baseline
   or unavailable counter is `Unavailable`, not zero. Preserve per-interface
   session totals and reset semantics.
5. Validate finite, nonnegative inputs and positive denominators. Bound drawing
   geometry to the track. If categories are incomplete or inconsistent, retain
   valid labels but show an unavailable composition rather than inventing a
   missing category or silently renormalizing misleading data. Minor floating
   point residue can be absorbed within a documented tolerance.
6. Monitoring disabled keeps the current disabled message and stops summary
   animation. Collecting keeps the existing collecting state. Partial/unavailable
   readings show neutral artwork and explicit labels; cached artwork must not
   masquerade as a newly valid sample.
7. Sleep, interface/baseline changes, disabled/resumed monitoring, and page changes
   break transitions. Returning to a visible page presents the latest valid
   reading directly. Existing history gaps remain intact.
8. Chip/volume metadata reads run asynchronously in the platform adapter, never
   in drawing or model construction. Cache chip identity and refresh volume
   metadata on the existing capacity/identity lifecycle. Keep fallback labels
   (`Processor`, existing disk name) when metadata is unavailable. Do not hardcode
   `Apple M1`, `Macintosh HD`, or `APFS`, and do not broaden monitoring scope.

## Rendering and update approach

Separate fixed layout from changing values, following the existing retained
history-chart pattern. Proposed presentation inputs describe ring/bar fractions,
labels, metadata, and availability. One shared geometry/calculation path should
serve the retained renderer and deterministic offscreen rendering so screenshots
and production UI cannot diverge in category order or percentages.

Retain one bounded summary layer group for the visible Stats page. Use a fixed
number of shape layers for its ring and bar; reuse layers on sampling updates.
Numbers update from the actual sample immediately. A short, approximately
200-300 ms transition may interpolate valid ring/bar changes, starting from the
currently presented geometry if a new sample arrives mid-transition. All
category boundaries must move consistently so segments do not overlap. Do not
animate through fabricated numeric readings or create a continuous frame timer.

Skip equal inputs and samples belonging only to other pages. Where existing
detail content still needs rebuilding, do so only for changed page-relevant
inputs and keep the ring/bar layers retained. Metadata or availability changes,
theme changes, resize, and navigation may legitimately trigger layout changes.
Do not redesign the entire workspace rendering system for this feature.

Animate only while the summary intersects the visible scroll area and the
workspace is visible, unoccluded, unminimized, awake, and not covered by a modal.
Reduce Motion applies values immediately. Low Power Mode retains normal
transition behavior but uses the existing two-second aggregate cadence. Hidden
pages perform no summary rendering/animation; background collection/menu-bar
updates continue according to their existing independent policy.

## Implementation sequence and ownership

1. **Define presentation and theme.** Add a small shared summary presentation /
   geometry abstraction under `macos/Sources/UI/`, or keep it in `StatsLayers.swift`
   if it remains compact. Add Stats semantic colors in `ThemePalette.swift`.
   Establish normal, collecting, disabled, partial, and unavailable inputs.
2. **Complete optional metadata.** Extend `StatsCPU`/`StatsDisk` and the existing
   `SystemStatsEnvironment` result types as needed in `SystemStats.swift`.
   Read/cache real display metadata in `SystemStatsPlatform.swift` and propagate
   it through `SystemStatsService.swift`. Update fakes; preserve sampling,
   cancellation, baseline, and generation behavior. Do not introduce a second
   service or privileged operation.
3. **Build the four summaries.** Update `StatsPanel.swift` and retained vector
   surfaces in `StatsLayers.swift`. Reorganize redundant top-card rows into the
   summary and useful detail section. Remove lower measurement rows for values
   already printed in a chart card, following the per-page list above.
   Preserve histories, process lists,
   Network controls, monitoring controls, and accessibility information.
4. **Integrate efficient updates.** Extend `WorkspaceScene.swift` and the canvas
   integration in `WorkspaceView.swift` to carry/update summary surfaces.
   Compare visible-page inputs, preserve layer identity, and implement explicit
   visibility/scroll/Reduce Motion transition gating.
5. **Verify and document.** Extend existing Core/UI test files at the service and
   rendered-output seams. Update runner counts for actual added tests. Run
   `scripts/sync_sources.py` if Swift files are added/removed. Update README and
   `docs/MANUAL_TEST.md` for the delivered UI, cadence, and manual scenarios.

## Acceptance and verification

- All four pages match the requested visual structure using VueVPN theme colors
  at default/minimum sizes, Light/Dark, and 1x/2x scale. Controls, labels, and
  legends stay within bounds with long names and large rate values.
- Deterministic values verify CPU 6/8/86 -> 14% busy, RAM category sums, SSD
  `used = total - available`, and independent Network download/upload values.
  Include 0%, 100%, tiny nonzero segments, missing/invalid values, inconsistent
  totals, unit boundaries, and unavailable metadata.
- Rendered ring/bar/legend values agree. Inspect offscreen PNGs for clipping,
  category visibility, padding, text alignment, and both themes; exercise the
  actual retained renderer as well as the static drawing path.
- For every page, verify measurements printed in the summary/chart card have no
  duplicate latest-value text or key/value rows in lower sections. Preserve the
  card's own legends, historical plots, and distinct detail readings.
- Service tests preserve aggregate 1/2-second and capacity 30-second cadence,
  sleep/resume, baseline resets, per-interface totals, and monitoring behavior.
  Verify metadata does not add per-frame reads or reset histories.
- Rendering tests prove equal/other-page samples perform no summary updates,
  relevant changes reuse layer objects, and layer/cache counts stay bounded.
  Measure content rebuilds separately from full workspace rebuilds. Verify theme
  and resize refresh correctly; hidden, offscreen, modal, and Reduce Motion
  scenarios suppress transitions as specified.
- Accessible summaries announce real values/categories and meaningful unavailable
  states. Native checkbox/radio actions, focus behavior, and cursors remain intact.
- Preserve existing frozen reference checksums and similarity thresholds; add
  deterministic new coverage without overwriting old baselines to hide failures.

During implementation, use focused `stats`, `theme`, `energy`, and `performance`
UI phases as relevant. Final checks run sequentially because Xcode shares
`macos/build`:

```sh
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy python3 scripts/build.py
```

The user verifies actual appearance, transition feel, live reading accuracy,
resize/scroll, theme changes, sleep/wake, monitoring toggles, interface changes,
and energy use. Development uses fakes, hostless/offscreen tests, and unsigned
compilation; do not launch the app or operate VPN/helper/networking as a test.

This planning task creates no implementation, package, commit, push, or PR.
The intended next deliverable is the implemented summary cards plus verified
offscreen previews and actual test/build results. Packaging can follow when
requested. Existing uncommitted Stats work must remain preserved.
