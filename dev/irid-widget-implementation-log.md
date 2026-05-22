# Irid Widget Implementation Log

**Date:** May 2026  
**Spec:** [irid-widget-spec.md](irid-widget-spec.md)

---

## Summary

Implemented all four slices of the widget mechanism. The implementation went
smoothly for Slices 1–3 (unit-tested via mock Shiny sessions). Slice 4 (the
CodeMirror example) revealed two subtle runtime bugs that only manifest in a
live browser with dynamically-inserted scripts.

---

## What was built

### Slice 1 — `irid.sendEvent()` JS primitive

**Files:** `inst/js/irid.js`, `tests/testthat/test-sendEvent.R`

Added `irid.sendEvent(elementId, eventName, payload)` to `irid.js`. It shares
the `sequences` counter and `sendPayload()` path with DOM events, so sequence-
based optimistic-update tracking and the stale-indicator mechanism work
identically for programmatic events.

22 tests covering payload construction, sequence incrementing, R-side handler
dispatch, force-send, and edge cases (null payload, unknown input).

### Slice 2 — Client-side init, channel, destroy handlers

**Files:** `inst/js/irid.js`, `tests/testthat/test-widget-client.R`

Added to `irid.js`:

- `irid.widgets` registry and `irid.registerWidget(name, initFn)`
- `deepEqual()` helper for nested-object comparison
- `Shiny.addCustomMessageHandler('irid-widget-init', …)` — dispatches to
  registered init function, queues if not yet registered
- `Shiny.addCustomMessageHandler('irid-widget-channel', …)` — dispatches
  `CustomEvent('irid-widget-channel')` with `detail.channel`, `detail.value`,
  `detail.isRender`
- `Shiny.addCustomMessageHandler('irid-widget-destroy', …)` — dispatches
  `CustomEvent('irid-widget-destroy')`
- `irid.trackChannel(el)` — per-element tracker with `recordSent()` /
  `receiveChannel()` for snap-back correction

76 tests (JS syntax, deep_equal algorithm, message contract shapes, widget
lifecycle ordering, TrackChannel state machine).

### Slice 3 — `IridWidget()` R-side constructor and mount wiring

**Files:** `R/irid_widget.R`, `R/process_tags.R`, `R/mount.R`,
`tests/testthat/test-widget-mount.R`

- `IridWidget(dep, container, ..., .config, .event, .render, .widget_name)`
  constructor in `R/irid_widget.R`
- `irid_widget` branch in `process_tags` walk function — splits named args
  into channels (reactive), events (`on*`), and static config
- Widget lifecycle in `irid_mount_processed` — init message, one `observe()`
  per reactive channel (with `isRender` flag for the render channel), destroy
  message on unmount

74 tests covering constructor validation, process_tags extraction, mount
messages, channel observers, destroy lifecycle, and end-to-end counter widget.

### Slice 4 — CodeMirror example

**Files:** `examples/codemirror/` (codemirror.js, codemirror.R, app.R),
`tests/testthat/test-widget-example.R`

A complete working example demonstrating the full pattern: htmlDependency,
irid.registerWidget, irid.sendEvent, IridWidget, reactive channels, event
handlers, and composition inside `When`.

33 tests (component construction, channel/event splitting, init/channel message
shapes, event dispatch, When lifecycle, JS syntax, multi-instance).

---

## Bugs found and fixed during Slice 4

### Bug 1: `htmlDependency` scripts stripped by `as.character()`

**Symptom:** Widget div is empty in the browser. No CodeMirror scripts appear
in the DOM. The `irid-widget-init` message is queued but the widget JS never
loads, so `irid.registerWidget` is never called, and the init is never
flushed.

**Root cause:** `htmltools::as.character()` on a `shiny.tag` strips all
`html_dependency` metadata — the output HTML contains no `<script>` or
`<link>` tags. Dependencies are metadata that Shiny's output pipeline
(`renderUI`, etc.) acts on, but irid's control flow (`When`/`Each`/`Match`)
bypasses that pipeline by sending raw HTML over custom messages
(`irid-swap`, `irid-mutate`). The `as.character(processed$tag)` calls at all
four serialization sites were silently discarding every dependency.

**Fix:** Added `render_tag_html()` helper in `R/mount.R` that calls
`htmltools::findDependencies()` + `htmltools::renderDependencies()` to
generate proper `<script>` / `<link>` tags, then prepends them to the tag
HTML. Applied at all four serialization sites:
- When observer (`irid-swap`)
- Each keyed inserts (`irid-mutate`)
- Each positional inserts (`irid-mutate`)
- Match observer (`irid-swap`)

### Bug 2: `irid-widget-init` races with widget script loading

**Symptom:** Even with scripts in the HTML, the widget never initializes.
The init message finds `irid.widgets['codemirror']` undefined and is silently
skipped. The widget JS registers later but the init message is already lost.

**Root cause:** `irid-widget-init` fires synchronously in the same Shiny
message batch as `irid-swap`, before the browser has loaded the widget JS
script. The init was a one-shot with no retry mechanism.

**Fix:** Added a deferred init queue in `irid.js`. When `irid-widget-init`
fires and the widget isn't registered yet, the init message is stored in
`irid._pendingInits`. When `irid.registerWidget()` is called (after the
script loads), it flushes any queued inits for that widget name.

### Bug 3: Mode scripts crash because they load before `codemirror.min.js`

**Symptom:** ReferenceErrors for `CodeMirror is not defined` in every mode
script (`javascript.min.js`, `python.min.js`, etc.), followed by a secondary
TypeError in `codemirror.min.js` itself (`can't access property "split", e is
null` in `setValue`).

**Root cause:** Dynamically-inserted `<script src="...">` tags via
`createContextualFragment` load and execute in arbitrary order, not document
order. The mode scripts all do `CodeMirror.defineMode(...)` at the top level,
requiring the `CodeMirror` global to exist. When they load before
`codemirror.min.js`, `CodeMirror` is undefined and they crash. The main
library then crashes too, likely because the mode failures leave internal
state inconsistent.

**Fix:** Combined all scripts into a single request using jsdelivr's
`combine` endpoint. The server concatenates `codemirror.min.js` + all mode
scripts in order into one response. One `<script>` tag, guaranteed execution
order. Used the `head` field of `htmlDependency` (raw HTML) to avoid URL
encoding issues with `@` and `,` in the combine URL.

### Bug 4: Codemirror content echo causes cursor jumping (mitigated)

**Symptom:** When the user types, the content channel echoes the value back
from the server and calls `editor.setValue()`, snapping the cursor.

**Root cause:** The `content` reactive channel observer fires whenever the
`code` reactiveVal changes, including when the change was initiated by the
user's own typing (via `onChange` handler).

**Fix:** Added two guards in the `irid-widget-channel` listener:
- Skip content updates while `editor.hasFocus()` (user is actively editing)
- Skip content updates that match `lastSentContent` (echo from our own
  `irid.sendEvent` call)

### Bug 5: Mode read from `msg.config` instead of `msg.channels`

**Symptom:** Initial editor mode is always `'javascript'` regardless of the
`language` reactiveVal (defaults to `'python'`).

**Root cause:** `mode` is passed as a reactive channel (`mode = language`),
so it appears in `msg.channels.mode`, not `msg.config.mode`. The init code
read `msg.config.mode`.

**Fix:** Changed to `msg.channels.mode || msg.config.mode || 'javascript'`.

---

## Key architectural insight

`htmltools::as.character()` strips `html_dependency` metadata from tags.
This is by design — Shiny's output pipeline processes dependencies
separately. But irid's control flow sends raw HTML over custom messages,
bypassing that pipeline. Every tag rendered to a string for `irid-swap` or
`irid-mutate` must have its dependencies manually rendered via
`renderDependencies()`. The `render_tag_html()` helper in `mount.R` exists
for this reason.

---

## Session 2 — Test audit and widget event timing fix

**Date:** 22 May 2026

### Test suite audit

Reviewed all 205 existing widget tests across four files. Found three tests
that passed but didn't actually test what they claimed:

- **`test-widget-mount.R`: When-deactivation destroy** — captured `msgs`
  before deactivation, so the destroy filter was checking stale data.
  The assertion was commented out, so the test passed vacuously.

- **`test-widget-example.R`: codemirror.js syntax check** — all four path
  candidates were wrong (`system.file()` returned `""` because
  `examples/` lives at repo root, not `inst/examples/`). The test silently
  skipped via `skip()`.

- **`test-widget-example.R`: CodeMirror When destroy** — called
  `handle$destroy()` manually after deactivation, testing the manual
  teardown path instead of the automatic When-deactivation destroy.

Added 12 new tests covering gaps:

- `render_tag_html()` dependency script rendering
- `.config` vs static `...` arg merge precedence
- Multi-widget destroy sends all IDs
- Channel message ID targeting (isolation between instances)
- Widget inside keyed `Each` (add/keep/remove lifecycle)
- Static mode value goes to `config`, not `channels` (covers Bug 5 root cause)
- `irid-events` message structure verification for widget events
- Managed-state dispatch contract (R mirror of JS `sendEvent` routing)
- `sendEvent` with throttle/debounce config reaches R handler

Final tally: **256 tests, 0 failures.**

### Widget event timing config fix

**Problem:** Widget JS calls `irid.sendEvent()` directly, which called
`sendPayload()` directly — completely bypassing the throttle/debounce/immediate
managed state set up by the `irid-events` message. The `.event` timing config
on `IridWidget` was dead code for widget events.

**Fix:** Extracted the first-send timing logic from the DOM listener closures
into a `s.submit(payload)` method on each managed state object (throttle,
debounce, immediate-with-coalesce). Then:

- DOM listeners in `setupThrottle`/`setupDebounce`/`setupImmediate` now call
  `s.submit(buildPayload(e, el, msg.id))` — a one-liner instead of inline
  timing logic.
- `irid.sendEvent()` checks `managed[inputId]` and routes through
  `s.submit(payload)` when managed state exists; falls back to direct
  `sendPayload` when no managed state (immediate without coalesce, or events
  on elements with no `irid-events` setup).

Stored timing parameters (`inputId`, `ms`, `leading`, `coalesce`, `mode`) on
the state object itself (previously captured via closure). No new timing logic
— the same code, just repositioned to be callable from both paths.

**Files changed:** `inst/js/irid.js` (4 functions refactored),
`tests/testthat/test-widget-client.R` (+5 tests, dispatch contract mirror),
`tests/testthat/test-widget-mount.R` (+3 tests, irid-events message shape),
`tests/testthat/test-sendEvent.R` (+2 tests, integration).

### Impact on client-event-queue-design.md

The [client event queue design](client-event-queue-design.md) proposes a
per-element slot queue to enforce ordering across events on the same element
(e.g. `onInput` debounce vs `onKeyDown` immediate). This session's change is
orthogonal and preparatory:

- **Before this change:** `irid.sendEvent` bypassed all client-side event
  machinery — it would also have bypassed the slot queue.
- **After this change:** `irid.sendEvent` routes through the same `managed`
  state and `submit` pipeline as DOM events. When the slot queue is
  implemented, `irid.sendEvent` will naturally participate in per-element
  ordering because it feeds through the same entry points.

Concretely, `s.submit(payload)` is where slot-claiming logic would be added
in a future implementation of the queue design.
