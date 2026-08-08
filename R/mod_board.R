# Interactive analysis board: explore positions with live engine evaluation.
# Rendered directly beneath the analyze controls, so a recognized screenshot
# lands here automatically and can be explored (or corrected) in place.

#' Interactive board UI
#'
#' @param id The module id.
#' @return A Shiny UI tag list for the interactive analysis board.
mod_board_ui <- function(id) {
  ns <- NS(id)
  tags$section(
    class = "cv-card cv-board-card",
    cv_section_title(
      "Analysis board",
      paste(
        "A recognised screenshot lands here automatically - drag pieces to",
        "explore, or to fix a misread square. The engine re-evaluates",
        "continuously as the search deepens."
      ),
      step = "2"
    ),
    div(
      class = "cv-board-layout",
      div(
        class = "cv-board-col",
        div(
          class = "cv-board-wrap",
          div(
            class = "cv-evalbar",
            div(class = "cv-evalbar-black", id = ns("evalbar_black")),
            div(class = "cv-evalbar-white", id = ns("evalbar_white"))
          ),
          div(id = ns("board"), class = "cv-board")
        ),
        div(
          class = "cv-board-controls",
          actionButton(ns("flip"), "Flip"),
          actionButton(ns("undo"), "Undo"),
          actionButton(ns("reset"), "Start"),
          actionButton(ns("play_best"), "Play best move", class = "btn-primary")
        )
      ),
      div(
        class = "cv-analysis-col",
        div(
          class = "cv-eval-block",
          div(class = "cv-eval-headline", textOutput(ns("score"), inline = TRUE)),
          div(class = "cv-eval-sub", textOutput(ns("depth_line"), inline = TRUE))
        ),
        div(
          class = "cv-subpanel",
          div(class = "cv-panel-label", "Engine lines"),
          uiOutput(ns("lines"))
        ),
        div(
          class = "cv-subpanel cv-radar",
          div(class = "cv-panel-label", "Blunder radar"),
          div(
            class = "cv-radar-controls",
            checkboxInput(ns("radar_on"), "Show what a human would play", value = FALSE),
            conditionalPanel(
              condition = "input.radar_on",
              ns = ns,
              sliderInput(
                ns("rating"), "Opponent rating",
                min = min(MAIA_RATINGS), max = max(MAIA_RATINGS),
                value = 1500L, step = 100L, ticks = FALSE, sep = ""
              )
            )
          ),
          uiOutput(ns("radar"))
        ),
        div(
          class = "cv-subpanel",
          div(class = "cv-panel-label", "Moves"),
          div(class = "cv-movelist", textOutput(ns("movelist")))
        ),
        div(
          class = "cv-subpanel",
          div(class = "cv-panel-label", "FEN"),
          tags$code(class = "fen-code", textOutput(ns("fen"), inline = TRUE))
        )
      )
    )
  )
}

#' Interactive board server
#'
#' Owns a persistent Stockfish process for the session and keeps the eval bar,
#' score, depth and principal variations in sync with the board position.
#'
#' @param id The module id.
#' @param chess_ctx A chess.js V8 context from [new_chess_context()], used to
#'   convert engine moves to SAN.
#' @param incoming A reactive returning a position to load into the board -
#'   either a bare FEN string, or a list with `fen`, an optional `orientation`
#'   ("white"/"black") and an optional `nonce` to force a reload of an
#'   unchanged FEN - or `NULL`.
#' @return Called for its side effects; wires up the board reactives.
mod_board_server <- function(id, chess_ctx, incoming = reactive(NULL)) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    START_FEN <- "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    engine <- engine_session_start(multipv = 3L)
    session$onSessionEnded(function() engine_session_stop(engine))

    # Latest analysis snapshot drained from the engine.
    snap <- reactiveVal(NULL)

    # Human model, started lazily: it is only needed when the radar is on, and
    # it is restarted when the rating changes because each rating is a separate
    # network.
    maia <- reactiveVal(NULL)
    session$onSessionEnded(function() maia_session_stop(isolate(maia())))

    observeEvent(list(input$radar_on, input$rating), {
      maia_session_stop(maia())
      maia(NULL)
      if (isTRUE(input$radar_on) && human_model_available(input$rating)) {
        maia(maia_session_start(input$rating))
      }
    })

    # Ids are resolved once here and passed explicitly to the browser, so the
    # JS never has to guess at Shiny's namespacing.
    board_id <- ns("board")
    state_input <- ns("state")

    # Create the client-side board once the session is up.
    session$onFlushed(
      function() {
        session$sendCustomMessage("tanmai-board-create", list(
          container = board_id,
          stateInput = state_input,
          fen = START_FEN,
          orientation = "white",
          pieceTheme = piece_theme_base("cburnett")
        ))
      },
      once = TRUE
    )

    # Board state reported by the browser after every move.
    board_state <- reactive(input$state)

    current_fen <- reactive({
      st <- board_state()
      if (is.null(st) || is.null(st$fen)) START_FEN else st$fen
    })

    # Restart the search whenever the position changes.
    observeEvent(current_fen(), {
      req(engine)
      engine_session_analyse(engine, current_fen())
      snap(NULL)
    })

    # Load an externally supplied position (a screenshot just recognized
    # above). Accepts either a bare FEN or a list carrying the orientation to
    # show it from - a board read from Black's perspective should stay that
    # way rather than silently flipping - plus a nonce, so re-analysing the
    # same screenshot reloads the board instead of being skipped as "no
    # change".
    observeEvent(incoming(), {
      msg <- incoming()
      req(!is.null(msg))
      fen <- if (is.list(msg)) msg$fen else msg
      req(!is.null(fen))

      # A live tracker sends the move it inferred as well as the position. When
      # the board is genuinely standing where that move was played from, play
      # it: the piece slides, and the browser's own history stays in step so
      # Undo and the move list keep working. Otherwise fall back to setting the
      # position outright.
      ucis <- if (is.list(msg)) msg$ucis %||% msg$uci else NULL
      if (!is.null(ucis) && !is.null(msg$prev_fen) &&
        same_position(isolate(current_fen()), msg$prev_fen)) {
        session$sendCustomMessage("tanmai-board-move", list(
          container = board_id, ucis = as.list(ucis)
        ))
        return()
      }

      session$sendCustomMessage("tanmai-board-set", list(
        container = board_id,
        fen = fen,
        orientation = if (is.list(msg) && !is.null(msg$orientation)) msg$orientation else "white"
      ))
    })

    observeEvent(input$flip, {
      session$sendCustomMessage("tanmai-board-flip", list(container = board_id))
    })
    observeEvent(input$undo, {
      session$sendCustomMessage("tanmai-board-undo", list(container = board_id))
    })
    observeEvent(input$reset, {
      session$sendCustomMessage("tanmai-board-set", list(
        container = board_id, fen = START_FEN, orientation = "white"
      ))
    })
    observeEvent(input$play_best, {
      s <- snap()
      req(!is.null(s), length(s$lines) > 0)
      session$sendCustomMessage("tanmai-board-move", list(
        container = board_id, uci = s$lines[[1]]$first
      ))
    })

    # ---- live evaluation loop -------------------------------------------
    # Non-blocking: drain whatever the engine has emitted, ~4x/second. Shiny is
    # single-threaded, so this must never wait on the engine.
    observe({
      invalidateLater(250, session)
      req(engine)
      s <- engine_session_poll(engine)
      if (!is.null(s) && length(s$lines)) snap(s)
    })

    turn <- reactive({
      st <- board_state()
      if (is.null(st) || is.null(st$turn)) "w" else st$turn
    })

    output$score <- renderText({
      s <- snap()
      if (is.null(s) || !length(s$lines)) {
        return("evaluating...")
      }
      top <- s$lines[[1]]
      format_score(top$cp, top$mate, turn())
    })

    output$depth_line <- renderText({
      s <- snap()
      if (is.null(s) || !length(s$lines)) {
        return("")
      }
      sprintf("depth %d - %d lines", s$depth, length(s$lines))
    })

    # Eval bar: white's share of the height, from White's point of view.
    observe({
      s <- snap()
      pct <- if (is.null(s) || !length(s$lines)) {
        50
      } else {
        eval_bar_pct(s$lines[[1]]$cp, s$lines[[1]]$mate, turn())
      }
      session$sendCustomMessage("tanmai-evalbar", list(
        white_id = ns("evalbar_white"),
        black_id = ns("evalbar_black"),
        pct = pct
      ))
    })

    # Blunder radar for the current position. Recomputed only when the radar is
    # switched on, since it costs an extra engine search.
    radar <- reactive({
      req(isTRUE(input$radar_on))
      m <- maia()
      req(!is.null(m))
      blunder_risk(current_fen(), m, movetime_ms = 700)
    })

    # Arrows: the engine's choice in blue, and what a human of the selected
    # rating would actually play in orange, thickness scaled by probability.
    # Seeing the two disagree is the entire point of the radar.
    observe({
      s <- snap()
      arrows <- list()
      if (!is.null(s) && length(s$lines)) {
        best <- s$lines[[1]]$first
        arrows <- c(arrows, list(list(
          from = substr(best, 1, 2), to = substr(best, 3, 4),
          color = "#2b6cb0", opacity = 0.75, width = 9
        )))
      }
      if (isTRUE(input$radar_on)) {
        rad <- tryCatch(radar(), error = function(e) NULL)
        if (!is.null(rad) && nrow(rad$moves)) {
          shown <- radar_arrow_moves(rad$moves)
          for (i in seq_len(nrow(shown))) {
            mv <- shown$move[i]
            losing <- shown$loss[i] >= 100
            arrows <- c(arrows, list(list(
              from = substr(mv, 1, 2), to = substr(mv, 3, 4),
              color = if (losing) "#c53030" else "#dd6b20",
              opacity = 0.45 + 0.4 * shown$prob[i],
              width = 4 + 12 * shown$prob[i]
            )))
          }
        }
      }
      session$sendCustomMessage("tanmai-board-arrows", list(
        container = board_id, arrows = arrows
      ))
    })

    output$radar <- renderUI({
      if (!isTRUE(input$radar_on)) {
        return(NULL)
      }
      if (is.null(maia())) {
        return(tags$p(
          class = "text-muted",
          sprintf(
            "Human model unavailable (needs lc0 and the maia-%d weights).",
            match_maia_rating(input$rating)
          )
        ))
      }
      rad <- tryCatch(radar(), error = function(e) NULL)
      if (is.null(rad) || is.na(rad$risk) || !nrow(rad$moves)) {
        return(tags$p(class = "text-muted", "Assessing..."))
      }

      level <- if (rad$risk >= 150) {
        list("danger", "high")
      } else if (rad$risk >= 50) {
        list("warning", "moderate")
      } else {
        list("success", "low")
      }

      rows <- lapply(seq_len(min(4, nrow(rad$moves))), function(i) {
        mv <- rad$moves[i, ]
        san <- tryCatch(fen_move_to_san(chess_ctx, current_fen(), mv$move),
          error = function(e) NULL
        )
        tags$div(
          class = "cv-line",
          tags$span(class = "cv-line-score", sprintf("%.0f%%", 100 * mv$prob)),
          tags$span(class = "cv-line-move", san %||% mv$move),
          tags$span(
            class = if (mv$loss >= 100) "cv-risk-bad" else "cv-line-pv",
            if (mv$loss >= 20) sprintf("loses %.1f pawns", mv$loss / 100) else "sound"
          )
        )
      })

      tagList(
        tags$div(
          class = sprintf("alert alert-%s cv-radar-summary", level[[1]]),
          sprintf(
            "%s risk for a %d player: expected loss %.2f pawns, %.0f%% chance of a real mistake.",
            tools::toTitleCase(level[[2]]), match_maia_rating(input$rating),
            rad$risk / 100, 100 * rad$blunder_prob
          )
        ),
        tags$div(
          class = "text-muted cv-radar-caption",
          "Where this player is most likely to go wrong (chance x cost):"
        ),
        do.call(tagList, rows)
      )
    })
    outputOptions(output, "radar", suspendWhenHidden = FALSE)

    output$lines <- renderUI({
      s <- snap()
      if (is.null(s) || !length(s$lines)) {
        return(tags$p(class = "text-muted", "Waiting for the engine..."))
      }
      fen <- current_fen()
      rows <- lapply(s$lines, function(ln) {
        san <- tryCatch(fen_move_to_san(chess_ctx, fen, ln$first),
          error = function(e) NULL
        )
        label <- if (is.null(san)) ln$first else san
        tags$div(
          class = "cv-line",
          tags$span(class = "cv-line-score", format_score(ln$cp, ln$mate, turn())),
          tags$span(class = "cv-line-move", label),
          tags$span(class = "cv-line-pv", paste(utils::head(ln$pv, 6), collapse = " "))
        )
      })
      do.call(tagList, rows)
    })

    output$movelist <- renderText({
      st <- board_state()
      if (is.null(st) || !length(st$history)) {
        return("(no moves yet)")
      }
      hist <- st$history
      nums <- seq_along(hist)
      paste(ifelse(nums %% 2 == 1, paste0((nums + 1) %/% 2, ". "), ""), hist,
        sep = "", collapse = " "
      )
    })

    output$fen <- renderText(current_fen())

    outputOptions(output, "score", suspendWhenHidden = FALSE)
    outputOptions(output, "depth_line", suspendWhenHidden = FALSE)
    outputOptions(output, "lines", suspendWhenHidden = FALSE)
    outputOptions(output, "movelist", suspendWhenHidden = FALSE)
    outputOptions(output, "fen", suspendWhenHidden = FALSE)
  })
}
