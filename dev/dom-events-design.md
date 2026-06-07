# DOM events — `.event` keys, naming, and optional extensions

**Status:** Plain-tag `.event` work for 0.3.0; §5 items optional and undated
**Date:** May 2026

---

## 1. The remaining gap

irid maps `tags$*` event handler args to DOM event types by stripping
`on` and lowercasing the remainder: `onCursorChanged` →
`cursorchanged`. `.event` timing config on plain tags still keys on
the resulting wire name:

```r
tags$div(
  onCursorChanged = handler,
  .event = list(cursorchanged = event_debounce(100))   # wire name
)
```

That's a mental-model leak: authors write `onCursorChanged` to
register the handler, then re-spell the same event in wire form to
configure timing.

---

## 2. Where we are — widget side (landed)

`IridWidget` already solved the per-event coupling problem via
`widget_event()`. Each event's name, handler, and timing live together
in one record:

```r
CodeMirror <- function(content,
                       onChange        = NULL,
                       onCursorChanged = NULL,
                       .event          = NULL) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content),
    events = list(
      widget_event(
        name    = "change",
        handler = write_back(content, "content", then = onChange),
        timing  = event_pick(.event, "change", event_debounce(200, coalesce = TRUE))
      ),
      widget_event(
        name    = "cursor-changed",
        handler = onCursorChanged,
        timing  = event_pick(.event, "cursor-changed", event_throttle(100, coalesce = TRUE))
      )
    )
  )
}
```

The wrapper's R param name (`onChange`) and its wire name
(`name = "change"`) sit side-by-side in the same record — the
on*↔wire mapping is declared once, no parallel slots to keep in sync.
`IridWidget` has no `.event` slot of its own; timing is per-event.

Caller-side `.event` keys (passed to the wrapper) are still **wire
names** today (`list(change = ..., \`cursor-changed\` = ...)`),
matching the plain-tag `.event` convention. `event_pick(user, key,
default)` is a small helper defined **locally inside each widget
wrapper** (not exported from the package) that resolves per-event
timing with scalar-broadcast support — both `event_pick` and scalar
broadcast are slated for removal in 0.3.0 in favor of inline
`.event[[key]] %||% default`.

---

## 3. Target shape — plain tags

Bring plain tags in line with what widgets already do conceptually:
the caller writes `on*` once, on both the handler and the timing
config:

```r
tags$div(
  onCursorChanged = handler,
  .event = list(onCursorChanged = event_debounce(100))
)
```

---

## 4. Changes for 0.3.0

### 4a. Flip plain-tag `.event` keys to `on*`

`normalize_element_event` in `process_tags` currently expects
wire-name keys. Update it to apply the same `on*` → wire resolution
that `tags$*` already applies to event-handler arg names (strip `on`,
lowercase the remainder).

Every existing plain-tag `.event` key migrates from wire-name to
`on*` form. Breaking change for every call site.

### 4b. Drop scalar-broadcast `.event`

`.event = event_throttle(100)` currently broadcasts the scalar to
*every* event on the element — both at the framework floor (plain-tag
`.event` via `normalize_element_event`) and inside the per-wrapper
`event_pick()` helper. It's a convenience that costs surface area:
the helper exists almost entirely to forward the scalar; without it,
wrappers could write the simpler `.event$onChange %||% default` pattern
directly.

In 0.3.0, drop scalar broadcast everywhere. `.event` accepts only a
named list (or `NULL`); callers who want "throttle every event"
enumerate each one. Once that lands:

- Each wrapper's local `event_pick()` collapses to
  `.event[[key]] %||% default` and can be deleted.
- Plain-tag `normalize_element_event` drops its scalar branch.
- Widget wrappers shrink:

  ```r
  widget_event(
    name    = "change",
    handler = ...,
    timing  = .event$onChange %||% event_debounce(200, coalesce = TRUE)
  )
  ```

### 4c. Rename `.event` → `.timing`

See [listener-opts-design.md §5](listener-opts-design.md). `.event`
is the misfit name in the emerging `.timing` / `.listener` /
`.filter` family — it carries timing, not "the event." Renaming
before `.listener` lands locks in the dot-prefix-plus-aspect naming
rule across the family.

Bundles cheaply with 4a/4b — same release, single migration entry in
the CHANGELOG.

---

## 5. Optional follow-ons (undated)

Two extensions to the event surface that aren't required for 0.3.0
but are natural successors to the `on*` normalization rule. Both
expand the event vocabulary beyond standard DOM and can land
independently once there's demand.

### 5a. `on:` verbatim escape hatch for non-standard events

The "strip `on`, lowercase" rule covers standard DOM events on
standard HTML elements. Custom events fired on standard elements
(jQuery plugins, Stimulus, bubbled `CustomEvent`s, vendor prefixes)
need a different path. An `on:` prefix would mean "use the rest of
this string verbatim as the event name":

```r
tags$div(
  `on:webkit-fullscreen-change` = handler,
  `on:library:custom.event`     = handler2,
  .timing = list(`on:webkit-fullscreen-change` = event_debounce(50))
)
```

Backticks are required for the colon, which doubles as a visual signal
that the name is the literal wire form. Works uniformly as a `tags$*`
arg name and as a `.timing` key.

### 5b. `custom_tag()` for declaring Web Components

Custom elements (hyphen-named Web Components per the spec) come from
outside the platform's standard vocabulary. Rather than guessing event
names from camelCase transformation, irid would ask users to declare
the element's event and property vocabulary once via `custom_tag()`:

```r
SlInput <- custom_tag(
  "sl-input",
  events     = c(
    onInput  = "sl-input",
    onChange = "sl-change"
  ),
  properties = c("value"),         # set as JS property, not attribute
  bind       = c(value = "onInput") # two-way bind value via the onInput event
)

# Callers get the same ergonomics as plain HTML form-element autobind:
SlInput(value = my_reactive, onChange = handle)
```

`custom_tag()` returns a function that acts like a `tags$*`
constructor with the element's vocabulary baked in. Three related
concerns:

**Attribute vs property.** Many Web Components can't accept rich
values (arrays, objects) as HTML attributes — they need JS properties
set directly. The `properties =` arg declares which names are
properties; callers can also use a per-arg `.prop` prefix:

```r
tags$"sl-select"(.value = my_reactive_array, ...)   # set as JS property
```

This mirrors the existing `.event` / `.timing` dot-prefix convention.

**Autobind for custom elements.** Plain-tag autobind (`<input
value=reactive>`) works because irid hardcodes "for `<input>`, value
lives in the `value` IDL property and changes are signaled by
`input`/`change` events." Web Components have no universal convention,
so `custom_tag()` lets the author declare it: `bind = c(<prop> =
<on-event>)` says "when the caller passes a reactive to `<prop>`,
synthesize a [write_back()] handler on `<on-event>` that writes the
payload back through that reactive." Under the hood this uses the
same `write_back()` primitive IridWidget wrappers call inline — the
only difference is that `custom_tag()` runs before any caller exists,
so the wiring must be *declared* at element-type level rather than
*called* per-instance.

**Ceremony levels.** Three ways to interact with non-trivial JS,
depending on need:

| Need | Use |
|---|---|
| Listen to a one-off custom event on a standard HTML element | `` tags$div(`on:foo-bar` = handler) `` |
| Wire a Web Component (events + properties + autobind, no JS lifecycle) | `custom_tag()` |
| Reactive props with init/update/destroy lifecycle | `IridWidget` |

---

## 6. Test plan

- `tags$div(onClick = h, .timing = list(onClick = event_throttle(50)))`
  → throttle applies to the `click` listener.
- Wire-name `.event` keys on plain tags produce a clear deprecation
  message during migration.
- Scalar `.timing` errors with a message pointing at the per-event
  named-list form.
- Widget wrappers using inline `.event$onChange %||% default` (no
  local `event_pick`) merge correctly with `on*`-keyed caller input.
- CHANGELOG migration entry covers the rename + scalar-broadcast drop
  + key-form flip together.
