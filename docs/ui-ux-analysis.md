# AgentBar UI/UX analysis

A comprehensive review of the app's UI (the popover in `QueueView.swift` /
`FeedComponents.swift`, the menu-bar label in `AgentBarApp.swift`, the Settings pane in
`SettingsView.swift`, and the notification banners in `NotificationManager.swift`), with
prioritized UX improvements and feature candidates. Everything proposed here respects the
notify-only contract: no reply channel, never blocks a session, fail-open.

## What already works well

- **A coherent, distinctive visual identity.** The phosphor-terminal design is executed
  consistently — one palette (`FeedComponents.swift`), one font helper, status colors that
  carry through tags, group headers, the dashboard strip, and the mascot.
- **Honest affordances.** The design's `y allow / n deny` deliberately became
  focus/dismiss; nothing in the UI pretends to answer for you.
- **The read-only dashboard** (summary strip → grouped roster → activity line → elapsed
  timers → drill-in trail) makes parallel sessions genuinely legible, and the meta line
  (model · mode · context %) surfaces data no other tool shows at a glance.
- **Keyboard navigation** (j/k/↵/d/m/t/esc) with a visible selection rail, plus careful
  window management (top-pinning, multi-display re-anchoring, on-screen clamping).
- **Careful notification lifecycle** — auto-clearing answered prompts, snooze, per-event
  toggles, DND window, per-project mute.

The issues below are mostly about *trust* (states that mislead), *reachability* (things
the code already knows but never shows), and *accessibility*.

---

## P0 — Trust and table-stakes gaps

### 1. There is no way to quit the app

No quit control exists anywhere (no hit in the sources for `terminate`). AgentBar is an
`LSUIElement` accessory app: it has no Dock icon and never activates, so the default menu's
⌘Q is effectively unreachable — the local key monitor in `QueueView.installKeyMonitor()`
even passes ⌘-chords through to an app that is never active. Today the only way out is
Activity Monitor / `kill`.

**Fix:** add a quit affordance — simplest is a `q · quit` entry in the title bar next to the
settings gear, and/or handle ⌘Q in the key monitor (`NSApp.terminate(nil)`). A small
About/version line in Settings would help too (there is currently no way to see the
installed version, which matters for a brew-cask-updated app).

### 2. The hero can say "TASK COMPLETE" when nothing ever ran

`QueueStore.headline`/`subline`/`mood` derive only from live `items`
(`QueueStore.swift:155-214`), while the dashboard strip and roster derive from
`sessionRows`. Consequences:

- Fresh launch, zero sessions: feed shows "NO SESSIONS YET" while the hero above it says
  "TASK COMPLETE · Recent activity below." — contradictory and unearned.
- A session inferred *working* from the transcript (no hooks caught, e.g. AgentBar started
  mid-turn) shows a blue WORKING group while the hero says "Task complete".
- Copy hard-codes Claude ("Claude's on it", "Claude has a question") even when the only
  active session is Copilot-tagged.

**Fix:** derive the hero from the same merged `sessionRows` the strip uses, with an explicit
zero-state ("STANDING BY · start a session to watch it here"), a roster-aware quiet state
("ALL QUIET · 3 idle sessions"), and source-aware copy (the `AgentSource` is already on
every item/row).

### 3. No setup/health visibility — a broken pipeline looks identical to a quiet one

If the plugin isn't installed, notification permission was denied, or Accessibility (for
window-precise focus) isn't granted, AgentBar shows the same calm empty state forever and
the user has no way to tell why nothing notifies. All the signals exist internally
(HookServer port/token, `sessionsLastSeen`, `UNUserNotificationCenter` auth status,
`AXIsProcessTrusted()`).

**Fix:** a "Setup" section (Settings, and referenced from the empty state) with live checks:

- ✓ local server listening (port from `server.json`)
- ✓ plugin heard from — "last hook 2m ago" / ✗ "never — install: `/plugin install agentbar@agentbar`"
- ✓ notification permission granted / ✗ with a deep link to System Settings
- ✓ Accessibility granted (window-precise focus) / ○ optional, with explanation
- ○ Copilot hooks installed (check `~/.copilot/hooks/agentbar.json`)

This converts the most common support failure ("I installed it and nothing happens") into a
self-diagnosable screen.

### 4. Errored sessions are filed under "IDLE"

`groupOf(_:)` buckets `.error` into group 2, whose header renders `○ IDLE`
(`QueueView.swift:436-453`), so a session whose turn just failed sits under a dim header
named for the least interesting state — directly under a red ERROR tag. The dashboard strip
has the same framing (errors counted as "idle").

**Fix:** either a fourth `⚠ ATTENTION`/`ERRORS` bucket ranked between WORKING and quiet, or
rename the bucket `QUIET` and tint the header when it contains errors. The strip's third
stat could read `○ 2 quiet · 1 err` when errors are present.

### 5. Accessibility is currently an afterthought

No `accessibilityLabel`, no Reduce Motion handling, no text selection anywhere in the
sources. Specific problems:

- **VoiceOver:** the ASCII mascot (`MascotView`) reads as box-drawing noise; keycap buttons
  read as "↵ focus" fragments; status tags/source pills are unlabeled text. Add
  `.accessibilityLabel` ("status: needs permission", "focus terminal", mascot hidden or
  labeled by mood) and `.accessibilityElement(children: .combine)` per row.
- **Motion:** the LIVE badge blinks forever (`LiveBadge`, 0.7s period) and scanlines
  shimmer over everything. Respect
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (freeze the badge) and offer
  a "CRT effects" toggle in Settings (scanlines off = better contrast too).
- **Type size & contrast:** body copy runs 8.5–11pt monospaced; `feedDim` (#3a7a52 on
  #080d0a) at 9.5pt is well below WCAG contrast for the timestamps/meta it's used on, and
  the scanline overlay multiplies everything darker still. Offer a text-size setting
  (S/M/L multiplier through `feedFont`) and consider brightening `feedDim` a step.

---

## P1 — Friction in daily use

### 6. Longest-waiting prompts sink to the bottom

Rows are sorted newest-activity-first globally, and grouping preserves that order
(`sessionRows` sort at `QueueStore.swift:342`, `groupedRows`). Inside NEEDS YOU that is
backwards: the prompt that has been waiting 10 minutes — the one you most need to see —
sits *below* the one that arrived 5 seconds ago. The hero shortcut (`focusLatestAttention`,
`QueueView.swift:363-373`) has the same bias: it focuses the *most recently raised* item.

**Fix:** sort the NEEDS YOU bucket by attention age descending (oldest `createdAt` first)
and make the hero jump to the longest-waiting item. Keep newest-first for the other groups.

### 7. The list reshuffles under the cursor

The popover rescans every 4s and re-sorts by `lastActivity`; every hook event also mutates
`items`. A row you're moving toward can jump groups or positions mid-click, and trail
expansion keeps pointing at a row that moved. Consider: (a) suppressing re-sorts while the
pointer is inside the feed (apply pending order on exit), or (b) animating moves so the eye
can track them (carefully — implicit animations leak in `MenuBarExtra(.window)`, as the
code already documents; an explicit `withAnimation` around the reorder is the safe form).

### 8. The command box is display-only

The banner offers "Copy command" (`NotificationManager`), but the popover's `$` command box
(`QueueView.swift:594-607`) can't be copied — no text selection, no button, `lineLimit(5)`
with no way to see an overflowing command. **Fix:** click-to-copy on the box (with a brief
"copied" flash), `.textSelection(.enabled)`, and click-to-expand past 5 lines. A `c` key
binding fits the existing keycap vocabulary.

### 9. Rich prompt data is parsed but never shown

- `AskQuestion.options` (labels + descriptions, multiSelect) are parsed in `Models.swift`
  but the row shows only the question text — yet *what the options are* is usually what
  decides whether you switch to the terminal now. Show options as a compact read-only list
  under the ask line (collapsed behind the existing trail-style toggle if space is a concern).
- `ElicitationRequest.fields` (typed fields, choices, required flags) similarly collapse to
  one message line. Render field names/kinds read-only.
- The banner for a multi-question ask shows only the first question; append "(+N more)"
  (the summary line already does this — reuse it).

### 10. No context menus

Everything is left-click keycaps. A right-click menu on rows is the native expectation and
a free home for lower-frequency actions without adding visual noise: Focus · Dismiss ·
Mute project · Copy command · Copy working directory · Copy session id · **Reveal
transcript in Finder** — the last one is already plumbed (`ClaudeSession.fileURL` exists
"so the row can reveal it in Finder") but never surfaced; `SessionRow` doesn't even carry
it. History rows deserve the same (focus that project / copy summary).

### 11. Mutes can become unmanageable

Mute is toggled from a row and stored by exact `cwd`. Once a project's row ages out of the
roster there is no way to see or undo its mute — the Settings footer even says "Mute a
project from its row in the popover". **Fix:** a "Muted projects" list in Settings with
remove buttons (the data is already in `UserDefaults`). Consider matching by
path-prefix so `repo` and `repo/subdir` mute together, or at least show the full path in
the list.

### 12. Two different session counts are shown at once

The title bar says "agentbar — 12 sessions" (`queue.sessionRows.count` — everything
scanned on disk, deduped) while the footer says "◉ watching 3 sessions" (`sessionCount` —
live-hook sessions within TTL). When they disagree, which is most of the time, it reads as
a bug. **Fix:** one number with two facets, e.g. title "12 sessions · 3 live", footer keeps
"notify-only". Also, when the live-only filter is active the title count doesn't change —
count `displayedRows` instead.

### 13. Hidden interactions have no affordances

- The hero is tappable (focus what needs you) but nothing signals it beyond a hover
  tooltip. Give it a subtle chevron/keycap (e.g. `⇥ jump`) or hover highlight.
- The bottom resize handle is 4pt tall and easy to never discover; a short first-run hint
  or slightly larger hover target would help.
- Keyboard help lives in a tooltip on "↑↓ ↵ d m"; a `?` binding that overlays the full
  cheat-sheet would make the keyboard mode self-teaching.

### 14. Density: quiet rows cost as much as loud ones

Every row renders its full stack (header, meta, title, activity, keycap row), so a healthy
roster of idle sessions pushes the one row that needs you below the fold. Options that keep
the current design language:

- Collapse IDLE-group rows to a single line (time · project · status · title), expanding
  on hover/selection; keycaps appear on hover only (they're all reachable via keyboard and
  the future context menu anyway).
- Or a Settings "compact mode" doing the same globally.
- Drop the "N msgs" counter in compact contexts — it's the least actionable datum on the row.

---

## P2 — Polish

- **Menu-bar legibility.** The mood faces (`^_^` → `o_o` → `O_O`) are charming but subtle
  at menu-bar size, and text-only. Offer an optional template-icon mode (SF Symbol +
  numeric badge) for crowded menu bars, and consider color: the count next to the face
  doesn't distinguish "permission waiting" (urgent) from "question waiting".
- **Context gauge as a micro-bar.** `ctx 148k · 21%` already colors by threshold; a 3px
  bar under the meta line reads faster than parsing numbers, and an amber tick at ~80%
  would pre-warn auto-compaction.
- **History improvements.** The log is in-memory (`historyLimit = 60`) and lost on
  relaunch — persist it (a small JSON file), make rows focus their project on click, add a
  per-project filter, and show a date divider when entries cross midnight (timestamps are
  `HH:mm:ss` only).
- **Sound preview.** With "Distinct sound per event type" on, Settings could play the
  sound when hovering/choosing — currently you learn the mapping only from the help text.
- **DND granularity.** Hour-only pickers; minutes would be cheap. (System Focus already
  gates the banners since they go through `UNUserNotificationCenter`, so this is
  complementary — worth a footnote in the Settings help text.)
- **Snooze from the popover.** Snooze exists only as a banner action; add it to the row's
  context menu / an `s` key for parity.

---

## Feature candidates (contract-compatible)

Ranked by value-for-effort; all read-only / notify-only.

1. **Setup & health panel** — see P0 #3. Highest-leverage feature on the list.
2. **Global hotkey** — a configurable shortcut (e.g. ⌥⇧A) that opens the popover, and a
   second one for "focus whatever needs me" (the hero action without opening the popover
   at all). For a keyboard-driven audience this collapses the whole interaction loop.
3. **Escalating reminders** — optional "remind me again if a prompt is still unanswered
   after N minutes" (re-post the banner, maybe with the elapsed wait in the title). The
   snooze re-post machinery in `NotificationManager.snooze` is 90% of the implementation.
4. **Read-only question options / elicitation fields** — see P1 #9.
5. **Reveal transcript in Finder / copy session id** — plumbing exists; context-menu item.
6. **Per-project preferences** — grow mute into a small per-project policy: banners
   off / attention-only / everything (the roster's project keying makes this natural).
7. **Waiting-time in the menu bar** — optional: when something needs you, append the
   longest wait to the badge ("O_O 2 · 4m"). Cheap glanceable urgency; off by default to
   respect menu-bar space.
8. **Daily digest (stretch)** — a history-derived summary ("today: 14 turns across 5
   projects, 3 permissions, median wait 40s"). Only worth it once history persists.

## Suggested sequencing

| Slice | Contents |
|---|---|
| 1 — Trust | Quit (+ About/version), hero/roster consistency + zero state, error bucket, unified session counts |
| 2 — Reachability | Context menus (incl. reveal-in-Finder, copy), command-box copy/expand, question options, mute list in Settings, snooze parity |
| 3 — Health | Setup/health panel + empty-state pointer, notification-permission warning |
| 4 — Access | VoiceOver labels, Reduce Motion + CRT-effects toggle, text-size setting, contrast pass on `feedDim` |
| 5 — Flow | NEEDS-YOU ordering by wait, reorder stability, global hotkeys, escalating reminders |
| 6 — Polish | Compact/hover density mode, context micro-bar, history persistence/filtering, menu-bar icon mode, sound preview |
