# Stats menu-bar Label / Icon plan

Date: November 2, 2026.

Status: implemented in this workspace; automated outcomes and remaining user-run checks are recorded below.

This addendum extends [STATS_SPEC.md](STATS_SPEC.md) and
[STATS_PLAN.md](STATS_PLAN.md) with the two styles below. Other custom menu-bar
layouts remain out of scope.

## Approved behavior

Each Stats page provides an independent **Menu bar style: Label / Icon** choice
near **Show in menu bar**. Default to Label, save each page's choice, and apply
changes immediately without restarting VueVPN.

| Metric | Label style | Icon style |
| --- | --- | --- |
| CPU | Existing two rows: CPU above percentage, aligned left | One row: `54% [CPU chip icon]` |
| RAM | Existing two rows: RAM above percentage, aligned left | One row: `54% [memory-module icon]` |
| SSD | Existing two rows: SSD above percentage, aligned left | One row: `54% [drive icon]` |
| Network | Existing two rows: download above upload, with arrows and units | Same two rate rows with one green globe to their right, vertically centered across both rows |

Bracketed names describe vector artwork, not literal text or emoji. Reuse the
chip, memory, SSD, and globe shapes already present in VueVPN.

- Only icons become green; values retain a readable menu-bar foreground.
- Use VueVPN's green palette, darker on a light menu bar and lighter on a dark
  menu bar. Resolve against the status button's effective appearance, separately
  from an explicitly selected window theme.
- Preserve Label artwork and visible left-edge alignment, current tray order,
  visibility preferences, click actions, tooltips, and accessibility descriptions.
- Style remains configurable while an item is hidden; showing it restores the
  latest value in its saved style. Missing data remains an em dash with its icon.
- Style changes retain values, totals, histories, baselines, selected interface,
  sampling cadence, and running collection tasks.

## Layout and rendering decisions

Give every metric a fixed width for each style. Percentage Icon style reserves
a fixed value column large enough for `100%`, with visible right edges aligned
and a small visible gap (target 3–4 points) before the fixed icon column. Use tabular digits. The icon and
neighboring items must not move when values change from `9%` to `54%` to `100%`.

Network reserves the current maximum supported rate width, direction indicators,
right-aligns each rate row by its visible edge, and uses one fixed globe column. Keep bounded formatting, including
`999+GB/s`, so unit changes do not resize items. Download/upload remain distinct
rows; the globe is centered vertically beside them.

A style change may resize the affected item once. Subsequent samples must keep
that width. Reuse status items without removing/reinstalling them. Icon style
is not guaranteed to use less width than two-row Label style.

Center percentage text and its icon vertically. The tray uses 20-point vector
boxes within the 22-point row; per-shape horizontal offsets account for the
different source margins. Icons remain static and sidebar sizing is unchanged.

Keep template-image rendering for Label style. Icon style needs explicitly
colored artwork so the icon retains its green. Prefer a compact image using
existing vector helpers, text/icon colors resolved from the status button's
effective appearance, and appropriate highlighted/disabled treatment. If needed,
use a small native drawing surface to separate text and icon; do not introduce
a new window or rendering stack.

Renderer inputs include metric, style, resolved appearance, and relevant control
state. Style/appearance changes refresh visible artwork even when the formatted
value is unchanged. Remove appearance observers with the controller. Cache
reusable icon resources with finite style/appearance/scale keys; do not retain
an image for every sampled value. Skip unchanged and hidden artwork.

## Implementation sequence

### 1. Persist independent style choices

Primary file: `macos/Sources/Core/StatsMenuPresentation.swift`.

- Introduce a Label/Icon value type and injectable preference storage extending
  or sitting alongside the existing visibility boundary.
- Save one style per `StatsPage`; proposed keys are
  `stats.menu.style.<page.rawValue>`. Preserve existing visibility keys.
- Missing/unrecognized values fall back to Label without clearing settings.
- Keep construction inert: no readers, timers, requests, or status items.

Verify with a fake store: defaults, independent choices, restoration, invalid
values, and coexistence with visibility preferences.

### 2. Add the page control and action wiring

Primary files: `StatsPanel.swift`, `WorkspaceChrome.swift`, `WorkspaceScene.swift`,
`WorkspaceView.swift` under `macos/Sources/UI/`, and
`macos/Sources/App/NativeApplication.swift`.

- Add an accessible Label/Icon single-choice control near Show in menu bar,
  available even when that checkbox is off.
- Carry style through workspace presentation and route its action to the
  preference owner and menu controller without invoking VPN operations.
- Fit default 960x720 and minimum 800x600 layouts. Put settings on a second row
  if necessary rather than overlapping the title.
- Preserve keyboard focus/navigation, selected-state accessibility, and cursors.

Verify all four pages offscreen in Light and Dark, including hidden items and
minimum-size layouts.

### 3. Render Icon style and update affected presentation

Primary files: `macos/Sources/Core/StatsMenuPresentation.swift` and
`macos/Sources/UI/StatsMenuBarController.swift`. Reuse `Icons.swift` and
`ThemePalette.swift`; add semantic colors only if needed.

- Separate existing numeric formatting from style-dependent geometry.
- Implement fixed percentage/icon and two-rate/globe columns.
- Refresh the affected item immediately on style change, including its width.
  Refresh visible artwork on effective appearance changes without waiting for
  another sample.
- Retain hidden latest metrics and render them in the saved style when shown.
- Preserve the original VPN menu and click-to-open page mapping.
- Keep `SystemStatsService` and readers independent of the preference: no added
  timers, sampling, probes, or subprocesses.

Verify synthetic artwork for every metric/style, unavailable values, menu-bar
light/dark appearances, and 1x/2x scale.

### 4. Lock down regressions and compile

Extend `macos/CoreTests/SystemStatsTests.swift` and
`macos/VisualTests/StatsPresentationTests.swift` at public behavior seams.

Required coverage:

- Default Label, independent mixed styles, persisted reload, invalid fallback.
- Hidden style changes produce no artwork work and restore the latest reading.
- An unchanged snapshot refreshes after style/effective-appearance changes;
  identical inputs produce no extra redraw.
- Fixed widths/icon positions for `0%`, `9%`, `10%`, `54%`, `99%`, `100%`, and
  unavailable values; Network unit boundaries and maximum rates do not clip.
- Offscreen green icon pixels and readable text on light/dark appearances;
  preserved Label alignment and frozen-reference thresholds.
- Through the application action/presentation seam, style changes retain data,
  history/totals and request no collection work. Extend fake-service tests only
  where needed to exercise this integration behavior.
- Existing page-navigation preservation, hidden-window sampling, Low Power,
  visibility, and VPN-menu regression checks continue to pass.

Update expected runner counts only for tests actually added/removed. If Swift
files are added/removed, run source synchronization and include its project diff.
Run checks sequentially because these commands share `macos/build`:

```sh
rtk proxy python3 scripts/test_core.py
rtk proxy python3 scripts/test_ui.py all
rtk proxy python3 scripts/build.py
```

During implementation, `scripts/test_ui.py stats`, `theme`, or `energy` can
provide focused feedback. Do not repeat the full suite without a new reason.
Preserve frozen references, checksums, and similarity thresholds.

### 5. Document and hand off

- Update README's System Stats section and `docs/MANUAL_TEST.md` with styles,
  per-page persistence, green icons, and fixed columns.
- Report actual test counts/results, compilation result, and output path.
  Earlier checks are not evidence for this adjustment.
- Leave live contrast, highlighted/clicked states, sharpness, spacing, and tray
  position checks to the user. Include mixed styles, hide/show, restart, and
  window Close versus Quit scenarios.

## Testing boundary and completion

Use fakes, hostless/offscreen tests, and unsigned compilation. Do not launch
VueVPN, create live test windows, install real status items, operate helper/VPN,
change networking/Keychain, or contact public-IP/probe services. Packaging,
installation, commits, pushes, and worker dispatch are outside this task.

The plan is ready for implementation handoff when behavior and verification are
clear. Implementation is ready for delivery when automated checks pass, docs are
current, and remaining user-run verification is reported. Actual menu-bar
appearance and battery impact require manual verification. This plan adds no
sampling work and makes no battery-life guarantee.

## Implementation outcome — November 2, 2026

Independent Label/Icon preferences and page controls are implemented. Icon artwork uses the existing vector shapes, fixed columns, and the status button's effective appearance. Hidden items retain their latest values, and presentation changes do not request collection or reset Stats data.

- `scripts/test_core.py`: 116 passed, 0 failed.
- `scripts/test_ui.py all`: 44 passed, 0 failed; frozen visual comparisons remained above their existing thresholds. The first run exposed an overflow in the new pixel test, corrected before the passing run.
- `scripts/build.py`: unsigned Debug compilation passed; output `macos/build/Build/Products/Debug/VueVPN.app`.
- No live app, status items, helper, VPN, or network probes were used. Actual menu-bar contrast, highlighting, placement, sharpness, and battery impact remain user-run checks in `MANUAL_TEST.md`.

## Icon geometry follow-up — November 2, 2026

The earlier 14-point box and left-aligned Icon values made glyphs small and left
a large variable visible gap. The tray now right-aligns visible value edges in
fixed columns and uses 20-point vectors with shape-specific optical offsets.
Label rendering remains unchanged. Network retains both direction-labelled rows
and bounded rates beside its fixed globe.

The strengthened actual-render pixel test first failed against the previous
geometry, then passed for all four metrics, unavailable values, percentage and
rate boundaries, light/dark, and 1x/2x. It checks visible glyph bounds, stable
positions, gaps, and image edges. `scripts/test_ui.py stats` passed 7/7;
`scripts/build.py` passed unsigned Debug compilation. Before/after preview strips
are in `artifacts/migration/stats-icon-strip-{before,after}-{light,dark}.png`.
Live status-bar appearance and interaction remain user-run checks.


## Adjacent item spacing follow-up — November 2, 2026

The fixed status-item length now equals the artwork width, removing the previous
4-point allowance per item while retaining the artwork's ink margins, fixed
value reservations, 20-point icons, and their positions. Four visible items
therefore reserve 16 points less in total. In the synthetic side-by-side strip,
each adjacent visible-ink gap decreased by 4 points; at 1x the mixed
Icon/Label/Icon/Label example measured 7/22/7 points before and 3/18/3 after.
Some gaps remain wider because short right-aligned values leave their fixed
maximum-width reservation empty. Actual AppKit status-button placement and any
system-controlled spacing or minimum cannot be established by this offscreen
model and require the user-run menu-bar check.

`scripts/test_ui.py stats` passed 8/8 and `scripts/build.py` passed unsigned
Debug compilation. Synthetic before/after strips at both scales and appearances
and measurements are in `artifacts/migration/stats-spacing-*`. The test uses
the previous four-point allowance as its before geometry; no live status items
were installed.


## Visible group spacing correction — November 2, 2026

The screenshot has foreground bounds RAM 39–137, SSD 193–284, Network
357–478 and CPU 535–633, giving gaps 55/72/56 pixels. The earlier offscreen
test removed only the former four-point artwork allowance and could not model
macOS spacing between separate status items. Icon artwork also reserves the
maximum rate width: short right-aligned Network values leave empty space before
their visible ink. The screenshot alone does not isolate the system contribution.

A single native Stats status item now contains four individually actionable,
accessible buttons in fixed-width cells, eliminating system spacing between
the metrics without squeezing artwork. Visibility, styles, destinations, and
latest values remain independent; the VPN item remains separate. macOS can
drag/reorder the Stats group as a whole, not its individual metrics.

The matching offscreen case (86%, 76%, ↓995B/s, ↑0B/s, 20%, all Icon)
measured bounds 18–117, 140–232, 272–394, 419–517 at 2x: gaps 22/39/24
pixels. Screenshot and preview group widths are respectively 99/92/122/99 and
100/93/123/99 pixels, supporting but not proving the 2x comparison. The
controlled result is near the requested half gaps; the system's actual final
placement, accessibility navigation, and appearance require manual checks.
The original screenshot and rendered strips are in `artifacts/migration/`
as `stats-compact-screenshot-before.png`,
`stats-compact-screenshot-before-model-{light,dark}-{1,2}x.png`, and
`stats-compact-screenshot-after-{light,dark}-{1,2}x.png`. The before model
places the old independent artworks edge-to-edge without inventing system
spacing, so it resembles the new controlled layout and cannot reproduce the
actual screenshot gaps. The after preview draws the hostless buttons; no live
status items or windows were installed.

Verification for this correction: `scripts/test_ui.py stats` passed 9/9;
`scripts/test_core.py` passed 116/116; `scripts/test_ui.py all` passed 46/46
with existing image thresholds; `scripts/build.py` passed unsigned Debug
compilation at `macos/build/Build/Products/Debug/VueVPN.app`. Hostless checks
do not establish live keyboard/VoiceOver navigation or final status-bar layout.
