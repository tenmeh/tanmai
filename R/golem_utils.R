# Shared UI and reactive helpers.

#' Locate a file installed under inst/
#'
#' @param ... Path components relative to inst/.
#' @return The full path returned by [system.file()] for this package.
app_sys <- function(...) {
  system.file(..., package = "tanmai")
}

#' Register static resource paths and add css/js includes
#'
#' Serves the package's own `www/` assets, plus the bundled cburnett SVGs and
#' any downloaded piece sets so the interactive board can use them as its
#' piece theme.
#'
#' @return A `tags$head` include with the stylesheets and scripts.
golem_add_external_resources <- function() {
  add_resource_path("www", app_sys("app/www"))
  # Piece art for the interactive board: bundled cburnett, plus the cache dir
  # holding any sets the user downloaded.
  add_resource_path("pieces", app_sys("svg"))
  add_resource_path("piecesets", piece_sets_dir())
  # The same chess.js bundle the server uses via V8, served to the browser so
  # both sides agree on the rules.
  add_resource_path("chessjs", app_sys("js"))
  # Cache-bust assets on version and file revision so local changes cannot
  # leave a browser running last version's CSS/JS against new markup.
  assets <- list.files(app_sys("app/www"), full.names = TRUE, pattern = "\\.(css|js)$")
  revision <- as.numeric(max(file.info(assets)$mtime, na.rm = TRUE))
  v <- paste0("?v=", utils::packageVersion("tanmai"), "-", revision)
  tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "www/chessboard-1.0.0.min.css"),
    tags$link(rel = "stylesheet", type = "text/css", href = paste0("www/styles.css", v)),
    tags$script(src = "www/chessboard-1.0.0.min.js"),
    # chess.js is a CommonJS build; give it a module/exports shim before it
    # loads, then hoist the constructor onto window for board.js.
    tags$script(HTML("var module = {exports: {}}; var exports = module.exports;")),
    tags$script(src = "chessjs/chess.js"),
    tags$script(HTML("window.ChessCtor = module.exports.Chess;")),
    tags$script(src = paste0("www/paste.js", v)),
    tags$script(src = paste0("www/capture.js", v)),
    tags$script(src = paste0("www/board.js", v))
  )
}

#' Piece-image URL template for the interactive board
#'
#' @param set A piece-set name, or "custom"/unknown for the bundled default.
#' @return A URL containing a `{piece}` placeholder that chessboard.js fills in,
#'   using whichever image extension the set actually ships.
piece_theme_base <- function(set = "cburnett") {
  if (is.null(set) || is.na(set) || identical(set, "cburnett") ||
    is.null(piece_set_path(set))) {
    return("pieces/{piece}.svg")
  }
  ext <- piece_set_ext(piece_set_path(set))
  if (is.null(ext)) ext <- "svg"
  sprintf("piecesets/%s/{piece}.%s", set, ext)
}

#' Drag-drop file input plus a clipboard-paste zone
#'
#' Produces two Shiny inputs: `{id}_upload` (a fileInput) and `{id}_paste` (a
#' data-URL string set by paste.js). Combine them server-side with
#' [latest_image_input()].
#'
#' @param id An id prefix, namespaced within the module.
#' @param ns The module namespace function.
#' @return A Shiny UI tag list.
image_input_ui <- function(id, ns) {
  tagList(
    fileInput(ns(paste0(id, "_upload")), "Drag & drop or browse",
      accept = c("image/png", "image/jpeg", "image/webp")
    ),
    tags$div(
      class = "paste-zone", tabindex = "0",
      `data-target` = ns(paste0(id, "_paste")),
      "Click here, then Ctrl+V to paste a screenshot"
    )
  )
}

#' Combine upload and paste events into one image reactive
#'
#' Keeps whichever of the two inputs fired most recently. Must be called from
#' within a module server function (it registers observers on that scope).
#'
#' @param input The module's `input` object.
#' @param id The same id prefix passed to [image_input_ui()].
#' @return A reactive returning a magick image, or `NULL` before any input.
latest_image_input <- function(input, id) {
  upload_id <- paste0(id, "_upload")
  paste_id <- paste0(id, "_paste")
  state <- reactiveValues(image = NULL)

  observeEvent(input[[upload_id]], {
    state$image <- image_read(input[[upload_id]]$datapath)
  })
  observeEvent(input[[paste_id]], {
    state$image <- decode_data_url_image(input[[paste_id]])
  })

  reactive(state$image)
}

#' Decode a data-URL image string into a magick image
#'
#' @param data_url A "data:image/...;base64,...." string.
#' @return A magick image.
decode_data_url_image <- function(data_url) {
  b64 <- sub("^data:[^,]+,", "", data_url)
  raw_bytes <- jsonlite::base64_dec(b64)
  image_read(raw_bytes)
}

#' Path for user-calibrated ("custom") templates
#'
#' @return The RDS path where a manual calibration is persisted across
#'   restarts.
custom_templates_path <- function() {
  dir <- tools::R_user_dir("tanmai", "config")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  file.path(dir, "templates_custom.rds")
}

#' Path to the currently active template library
#'
#' @return The user calibration path if one exists, otherwise the bundled
#'   cburnett (Lichess) default.
active_templates_path <- function() {
  custom <- custom_templates_path()
  if (file.exists(custom)) custom else app_sys("app", "templates.rds")
}

#' Draw the evaluation across a game as an inline SVG
#'
#' The drawing half of the evaluation graph; [eval_graph_geometry()] does the
#' arithmetic. This lives in the app layer rather than beside the tracker
#' because it is the one place a UI toolkit is needed, and the core is kept
#' free of one - see `test-core-boundary.R`.
#'
#' @param cp Centipawn evaluations from White's point of view, one per position
#'   (so one more than the number of moves). `NA` where not yet measured.
#' @param click_input Namespaced Shiny input id to report clicks to, or `NULL`
#'   for a static graph. Each point reports its own index as `ply`, counting
#'   the moves played to reach it - so 0 is the opening position, and every
#'   other value names the move that arrived there.
#' @param width,height Pixel size of the graph.
#' @return A `shiny::tags$svg` element, or `NULL` if there is nothing to draw.
eval_graph_svg <- function(cp, click_input = NULL, width = 420, height = 110) {
  g <- eval_graph_geometry(cp, width = width, height = height)
  if (is.null(g)) {
    return(NULL)
  }

  hotspots <- if (is.null(click_input)) {
    list()
  } else {
    lapply(seq_len(g$n), function(i) {
      tags$rect(
        x = max(0, g$xs[i] - g$hit_width / 2), y = 0,
        width = g$hit_width, height = height,
        fill = "transparent", class = "cv-graph-hit",
        onclick = sprintf(
          "Shiny.setInputValue('%s', {ply: %d, nonce: Math.random()}, {priority: 'event'})",
          click_input, i - 1L
        )
      )
    })
  }

  do.call(tags$svg, c(
    list(
      class = "cv-eval-graph", width = width, height = height,
      viewBox = sprintf("0 0 %d %d", as.integer(width), as.integer(height)),
      preserveAspectRatio = "none"
    ),
    list(
      tags$polygon(points = g$area, fill = "#2b6cb0", `fill-opacity` = "0.18"),
      tags$line(
        x1 = 0, y1 = g$mid, x2 = width, y2 = g$mid,
        stroke = "#94a3b8", `stroke-dasharray` = "3 3", `stroke-width` = 1
      ),
      tags$polyline(
        points = g$points, fill = "none", stroke = "#2b6cb0",
        `stroke-width` = 2, `stroke-linejoin` = "round"
      )
    ),
    hotspots
  ))
}
