# Variant-shaped leaf via I() + Switch
#
# Some state values have a variant-dependent shape — a form result that is
# either `list(success = TRUE)` or
# `list(success = FALSE, reasons = list(...))`. None of the basic store
# shapes fits cleanly:
#
#   - A bare named list at a leaf position auto-classifies as a *branch*,
#     fixed in shape at construction. It can't grow `reasons` on entering
#     the failure variant.
#
#   - An atomic list leaf (unnamed list) holds a *collection*, not a single
#     record. The wrong abstraction.
#
# Pattern: store the value as an I()-leaf and consume it with Switch.
# I() opts out of branch classification — the leaf accepts any shape on
# write. Switch projects the leaf as a mini-store over the current variant
# and tears it down + remounts on discriminator change. `reasons` (when
# present) is itself an unnamed list, so it can be Each'd for per-reason
# reactivity inside the matching Case.

library(irid)

SubmissionApp <- function() {
  state <- reactiveStore(list(
    # I() at construction — without it, list(success = TRUE) would become a
    # fixed-shape branch that couldn't grow `reasons`. Subsequent writes
    # don't need I() — the leaf is already classified.
    result = I(list(success = TRUE))
  ))

  set_success <- function() {
    state$result(list(success = TRUE))
  }

  set_failure <- function(reasons) {
    state$result(list(success = FALSE, reasons = reasons))
  }

  page_fluid(
    Switch(state$result,
      Case(\(r) r$success, \() {
        tags$p(class = "ok", "Submitted successfully.")
      }),
      Case(\(r) !r$success, \(r) {
        tags$div(
          class = "errors",
          tags$h4("Please fix the following:"),
          tags$ul(
            Each(r$reasons, \(reason, i) tags$li(\() reason()))
          )
        )
      })
    ),
    tags$div(
      tags$button("Mark success", onClick = set_success),
      tags$button(
        "Mark failure",
        onClick = \() set_failure(list(
          "Email is required",
          "Password too short"
        ))
      )
    )
  )
}

iridApp(SubmissionApp)
