#' Top-level Shiny UI
#'
#' The board is the centre of this app, so it gets the top of the page and the
#' width to be read comfortably. Everything that feeds it - the screenshot, the
#' capture controls, the calibration - is arranged around that, rather than the
#' board being the third thing down a stack of forms.
#'
#' @param request The Shiny request object (unused; present for the golem
#'   bookmarking signature).
#' @return A Shiny UI tag list.
app_ui <- function(request) {
  bslib::page_navbar(
    title = cv_brand(),
    id = "main_tabs",
    theme = cv_theme(),
    window_title = "Tanmai Chess - learn, play, review",
    fillable = FALSE,
    # Stylesheets, the chessboard/chess.js bundles and the resource paths they
    # are served from. This has to hang off the page itself: `page_navbar()`
    # does not take a bare tag list the way `fluidPage()` did, so dropping it
    # leaves every asset unloaded and the app renders as unstyled HTML.
    header = golem_add_external_resources(),

    bslib::nav_panel("Learn", value = "learn",
      div(class = "cv-page cv-workspace", mod_practice_ui("learn", "learn"))),
    bslib::nav_panel("Play", value = "play",
      div(class = "cv-page cv-workspace", mod_practice_ui("play", "play"))),
    bslib::nav_panel("Review", value = "review",
      div(class = "cv-page",
        mod_board_ui("board"),
        tags$details(class = "cv-settings cv-review-import", open = NA,
          tags$summary("Import and review a game"),
          mod_live_ui("live")),
        tags$details(class = "cv-settings",
          tags$summary("Read a position from a screenshot"),
          mod_analyze_ui("analyze")))),
    bslib::nav_panel("Settings", value = "calibrate",
      div(class = "cv-page", mod_calibrate_ui("calibrate"))),
    bslib::nav_spacer(),
    bslib::nav_item(
      tags$a(
        class = "cv-navlink",
        href = "https://github.com/tenmeh/tanmai",
        target = "_blank", rel = "noopener",
        "Source"
      )
    ),
    bslib::nav_item(bslib::input_dark_mode(id = "colour_mode"))
  )
}

#' Wordmark for the navbar
#'
#' "Tanmai" is Tanmay and Maia run together - the author, and the human-move
#' network the Blunder Radar and the rating estimator are both built on. The
#' package, the repository and the Cloud Run service all carry it, so there is
#' one name rather than three.
#'
#' The package was called `chessvision` until 1.2.0. That collided with
#' Chessvision.ai, a well-known browser extension doing the same job - board
#' recognition from a screenshot - which is a poor name to publish under.
#'
#' @return A Shiny tag.
cv_brand <- function() {
  tags$span(
    class = "cv-brand",
    tags$span(class = "cv-brand-mark", HTML("&#9822;")), # knight
    tags$span(
      class = "cv-brand-name",
      "Tanmai", tags$span(class = "cv-brand-sub", "chess")
    )
  )
}

#' A section heading with an optional lead paragraph
#'
#' Used instead of bare `h4()` + `p()` so every section on the page shares one
#' rhythm rather than each module inventing its own spacing.
#'
#' @param title Heading text.
#' @param lead Optional supporting sentence.
#' @param step Optional short marker shown before the title.
#' @return A Shiny tag.
cv_section_title <- function(title, lead = NULL, step = NULL) {
  tags$div(
    class = "cv-section-head",
    tags$div(
      class = "cv-section-titleline",
      if (!is.null(step)) tags$span(class = "cv-step", step),
      tags$h2(class = "cv-section-title", title)
    ),
    if (!is.null(lead)) tags$p(class = "cv-section-lead", lead)
  )
}
