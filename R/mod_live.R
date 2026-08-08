# Live game tracking: follow a game as it is played, not one frozen position.
#
# Two ways in, both real:
#
#   * Screen capture. getDisplayMedia gives the page a live video of a screen,
#     window or tab the user picks once in the browser's own dialog. Frames are
#     filtered in the browser (see capture.js) and only a settled, changed
#     picture is sent here.
#   * Paste. Ctrl+V after each move. No permission, no setup, works anywhere,
#     and goes through exactly the same gate.
#
# What it deliberately is not: there is no way for a web page to read the
# screen unprompted, watch the clipboard while another window has focus, or
# see inside another site. Anything of that sort would need a helper process
# or a browser extension, and is not pretended at here.
#
# Nothing recognized is trusted on its own. Every frame is put to the gate in
# fct_game_tracker.R, which accepts it only if exactly one short sequence of
# legal moves explains it. Rejections are counted and shown rather than hidden,
# because a tracker that quietly invents moves is worse than one that admits
# it lost the thread.

#' Live game tracking UI
#'
#' @param id The module id.
#' @return A Shiny UI tag list.
mod_live_ui <- function(id) {
  ns <- NS(id)
  tags$section(
    class = "cv-card",
    cv_section_title(
      "Follow a live game",
      paste(
        "Share the window you are playing in and mark the board once, or",
        "paste a fresh screenshot after each move. A position joins the game",
        "only when a single legal move explains it, so misreads and half-drawn",
        "animation frames are discarded instead of corrupting the record."
      ),
      step = "3"
    ),
    div(
      class = "cv-live-layout",
      div(
        class = "cv-live-capture",
        div(
          class = "cv-capture",
          `data-frame-input` = ns("frame"),
          `data-status-input` = ns("cap_status"),
          `data-video` = ns("video"),
          `data-canvas` = ns("preview"),
          `data-interval-input` = ns("interval"),
          div(
            class = "cv-board-controls",
            tags$button(class = "btn btn-primary cv-cap-start", "Share a screen"),
            tags$button(class = "btn btn-default cv-cap-shot", "Grab now"),
            tags$button(class = "btn btn-default cv-cap-whole", "Whole area"),
            tags$button(class = "btn btn-default cv-cap-stop", "Stop")
          ),
          tags$video(id = ns("video"), class = "cv-hidden-video", muted = NA, playsinline = NA),
          tags$canvas(id = ns("preview"), class = "cv-capture-preview"),
          div(class = "cv-capture-hint", uiOutput(ns("cap_state")))
        ),
        tags$div(
          class = "paste-zone cv-live-paste", tabindex = "0",
          `data-target` = ns("paste"),
          tags$span(class = "cv-dropzone-title", "...or paste after each move"),
          tags$span(class = "cv-dropzone-hint", "Click here, then Ctrl+V")
        ),
        # A finished game is the same object as a watched one, so importing it
        # belongs here rather than in a section of its own: everything below -
        # the graph, the turning points, the radar review - then works on it
        # unchanged.
        tags$details(
          class = "cv-settings cv-pgn-entry",
          tags$summary("...or import a game from PGN"),
          div(
            class = "cv-settings-body",
            textAreaInput(
              ns("pgn_text"), NULL,
              placeholder = "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 ...",
              rows = 5, width = "100%", resize = "vertical"
            ),
            div(
              class = "cv-actions",
              actionButton(ns("load_pgn"), "Import game", class = "btn-primary")
            ),
            uiOutput(ns("pgn_status"))
          )
        ),
        tags$details(
          class = "cv-settings",
          tags$summary("Tracking settings"),
          div(
            class = "cv-settings-body cv-choices",
            radioButtons(
              # Named for the button it configures: without a game running, the
              # first position read is adopted either way, and a label reading
              # "start the game from" would promise otherwise.
              ns("anchor"), "\"New game\" starts from",
              c("Standard start" = "start", "Whatever I first read" = "frame"),
              selected = "start"
            ),
            sliderInput(ns("interval"), "Check every (seconds)", 0.5, 5, 1.2, step = 0.1),
            # selectize = FALSE deliberately. Shiny's selectize widget pulls in
            # selectize.min.js *and* selectize-plugin-a11y.min.js, and if either
            # 404s the binding throws out of initShiny() before it opens the
            # websocket - so the whole app silently dies with an empty board.
            # That is not hypothetical: on Cloud Run the a11y plugin
            # intermittently 404s, because Shiny registers those asset prefixes
            # when it renders the UI and a freshly-started instance that has not
            # served a UI request yet does not have them. A two-option dropdown
            # gains nothing from selectize; a plain <select> cannot fail this way.
            selectInput(
              ns("max_plies"), "Tolerate missing",
              c("nothing - one move at a time" = "1", "one frame - up to two plies" = "2"),
              selected = "2", selectize = FALSE
            )
          )
        )
      ),
      div(
        class = "cv-live-game",
        div(
          class = "cv-actions",
          actionButton(ns("new_game"), "New game", class = "btn-primary"),
          actionButton(ns("resync"), "Re-anchor here")
        ),
        uiOutput(ns("summary")),
        uiOutput(ns("graph")),
        div(class = "cv-live-moves", uiOutput(ns("moves"))),
        div(
          class = "cv-subpanel",
          div(class = "cv-panel-label", "Where the game turned"),
          uiOutput(ns("turning"))
        ),
        uiOutput(ns("review"))
      )
    )
  )
}

#' Live game tracking server
#'
#' @param id The module id.
#' @param chess_ctx A chess.js V8 context from [new_chess_context()].
#' @return A reactive carrying a position for the interactive board: a list
#'   with `fen`, `orientation`, `nonce` and, when a single move was inferred,
#'   `uci` and `prev_fen` so the board can play it rather than jump.
mod_live_server <- function(id, chess_ctx) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    game <- reactiveVal(NULL)
    # NULL until an observation confirms which way round the board is; fixed
    # for the rest of the game once it does.
    pinned_flip <- reactiveVal(NULL)
    to_board <- reactiveVal(NULL)
    review <- reactiveVal(NULL)
    cap_status <- reactiveVal(list(state = "idle", message = ""))
    # A rolling account of what was done with recent frames, so a stalled
    # tracker is visibly stalled and says why.
    ledger <- reactiveVal(data.frame(
      status = character(0), reason = character(0), stringsAsFactors = FALSE
    ))

    # Its own engine: the board's runs `go infinite`, and interrupting that to
    # score each move would reset its search on every move of the game.
    scorer <- engine_session_start(multipv = 1L)
    session$onSessionEnded(function() engine_session_stop(scorer))

    # 38 piece sets is a few dozen RDS reads. Load once, not once per frame.
    libs <- local({
      cache <- NULL
      function() {
        if (is.null(cache)) cache <<- load_all_template_libraries()
        cache
      }
    })

    note <- function(status, reason) {
      df <- rbind(
        data.frame(status = status, reason = reason, stringsAsFactors = FALSE),
        ledger()
      )
      ledger(utils::head(df, 12))
    }

    observeEvent(input$cap_status, {
      cap_status(list(
        state = input$cap_status$state %||% "idle",
        message = input$cap_status$message %||% ""
      ))
    })

    observeEvent(input$new_game, {
      pinned_flip(NULL)
      review(NULL)
      ledger(ledger()[0, ])
      if (identical(input$anchor, "start")) {
        g <- scored(game_new(CV_START_FEN, turn_pinned = TRUE))
        game(g)
        note("new", "tracking from the standard starting position")
        push_board(g, NULL)
      } else {
        game(NULL)
        note("new", "waiting for a first position to read")
      }
    })

    # Throw away the game so far and take the next frame as the new starting
    # point. The honest escape hatch for when the thread is lost - a piece was
    # dragged back, a puzzle was reset, the wrong window was shared.
    observeEvent(input$resync, {
      game(NULL)
      pinned_flip(NULL)
      review(NULL)
      note("new", "re-anchoring on the next position read")
    })

    max_plies <- reactive(as.integer(input$max_plies %||% "2"))

    # ---- importing a finished game ---------------------------------------

    pgn_note <- reactiveVal(NULL)

    observeEvent(input$load_pgn, {
      res <- game_from_pgn(chess_ctx, input$pgn_text %||% "")
      if (!is.null(res$error)) {
        pgn_note(list(ok = FALSE, text = res$error))
        return()
      }

      pinned_flip(NULL)
      review(NULL)
      ledger(ledger()[0, ])
      # Deliberately not scored inline: an imported game arrives entirely
      # unevaluated, and `scored()` takes only a budget's worth before handing
      # the rest to the observer above. The board and the move list appear at
      # once; the graph fills in behind them.
      g <- scored(res$game)
      game(g)
      pgn_note(list(ok = TRUE, text = pgn_summary(res$headers, res$n_moves)))
      note("new", sprintf("imported %d plies from PGN", res$n_moves))
      # Set the final position outright rather than replaying the game move by
      # move. Playing them exists to keep the browser's move history in step
      # when plies are appended to a game already on the board; an import
      # replaces the board entirely, so there is nothing to stay in step with -
      # and animating forty-five moves to arrive somewhere the user can reach
      # by clicking any move in the list is just a delay.
      push_board(g, NULL)
    })

    output$pgn_status <- renderUI({
      n <- pgn_note()
      if (is.null(n)) {
        return(NULL)
      }
      tags$div(
        class = sprintf(
          "alert alert-%s cv-radar-summary", if (isTRUE(n$ok)) "success" else "warning"
        ),
        n$text
      )
    })
    outputOptions(output, "pgn_status", suspendWhenHidden = FALSE)

    # ---- evaluation ------------------------------------------------------

    # How many positions one pass through the scorer may evaluate. Watching a
    # game live adds a ply or two at a time, so the cap never bites there. It
    # exists for imports: a PGN arrives with the whole game unscored at once,
    # and Shiny is single-threaded, so evaluating fifty positions in one call
    # would freeze the entire app for the duration - about eleven seconds for a
    # forty-move game. Capped, each pass is well under a second and the graph
    # fills in visibly while everything stays usable.
    SCORE_BUDGET <- 6L

    #' Score up to `SCORE_BUDGET` unevaluated positions, oldest first.
    #'
    #' Returns the game and whether anything is still outstanding, so the
    #' caller can come back for the rest rather than blocking here.
    score_positions <- function(g) {
      if (is.null(g) || is.null(scorer)) {
        return(list(game = g, pending = FALSE))
      }
      todo <- which(is.na(g$cp))
      if (!length(todo)) {
        return(list(game = g, pending = FALSE))
      }
      for (i in utils::head(todo, SCORE_BUDGET)) {
        e <- tryCatch(engine_session_eval(scorer, g$fens[i], movetime_ms = 250L),
          error = function(err) NULL
        )
        if (is.null(e) || is.na(e$cp)) next
        turn <- strsplit(g$fens[i], " ", fixed = TRUE)[[1]][2]
        # Store from White's point of view so the graph has one fixed meaning.
        g$cp[i] <- if (identical(turn, "b")) -e$cp else e$cp
        g$best[i] <- e$best
      }
      list(game = g, pending = anyNA(g$cp))
    }

    # Whether positions are still waiting to be scored. Drives the observer
    # below, which comes back for the rest.
    scoring_pending <- reactiveVal(FALSE)

    scored <- function(g) {
      res <- score_positions(g)
      scoring_pending(isTRUE(res$pending))
      res$game
    }

    # Keep working through an import a budget at a time. Reads `game()` under
    # isolate() deliberately: depending on it as well would make every write
    # here re-trigger this observer immediately, and the pair would spin
    # instead of stepping. The only real dependency is the pending flag, and
    # each pass either clears it or leaves strictly less to do.
    observe({
      if (!isTRUE(scoring_pending())) {
        return()
      }
      invalidateLater(120, session)
      g <- isolate(game())
      if (is.null(g)) {
        scoring_pending(FALSE)
        return()
      }
      game(scored(g))
    })

    push_board <- function(g, moves) {
      msg <- list(
        fen = game_current_fen(g),
        orientation = if (isTRUE(pinned_flip())) "black" else "white",
        nonce = stats::runif(1)
      )
      # Let the board play the moves rather than jump to the position: the
      # pieces slide, and the browser's own history stays in step so the move
      # numbers there agree with the ones here. Inferred plies are sent
      # individually for the same reason - a jump would silently reset the
      # board's history and renumber the game from the middle.
      if (!is.null(moves) && length(moves)) {
        msg$ucis <- as.list(moves)
        msg$prev_fen <- g$fens[length(g$fens) - length(moves)]
      }
      to_board(msg)
    }

    # ---- the ingestion path ----------------------------------------------

    ingest <- function(img) {
      g <- game()

      # No game yet: this frame becomes the anchor. Orientation is whatever the
      # recognizer decides, and the side to move stays unpinned - a screenshot
      # cannot show whose turn it is, so the first move settles it.
      if (is.null(g)) {
        res <- tryCatch(
          recognize_position(img, libs(), chess_ctx, turn = "w", autocrop = TRUE),
          error = function(e) NULL
        )
        if (is.null(res)) {
          return(note("invalid", "the frame could not be read as a board"))
        }
        if (!isTRUE(res$set_confident)) {
          return(note("invalid", sprintf(
            "piece set not recognized (closest: %s) - calibrate it, or share a Lichess board",
            res$set
          )))
        }
        if (!isTRUE(res$valid)) {
          return(note("invalid", "the position read is not a legal one"))
        }
        pinned_flip(isTRUE(res$flip))
        g <- scored(game_new(res$fen, turn_pinned = FALSE))
        game(g)
        note("anchor", sprintf("anchored on the position read (%s on the bottom)",
          if (res$flip) "black" else "white"
        ))
        return(push_board(g, NULL))
      }

      res <- tryCatch(
        recognize_position(img, libs(), chess_ctx,
          turn = "w", autocrop = TRUE,
          orientation = if (is.null(pinned_flip())) "auto" else if (pinned_flip()) "black" else "white"
        ),
        error = function(e) NULL
      )
      if (is.null(res)) {
        return(note("invalid", "the frame could not be read as a board"))
      }
      if (!isTRUE(res$set_confident)) {
        return(note("invalid", sprintf("piece set not recognized (closest: %s)", res$set)))
      }

      # Until the orientation is pinned, both readings of the same squares are
      # put to the gate. A board is not symmetric, so at most one of them can
      # be a legal continuation - which makes the game itself decide which way
      # round it is, rather than a pixel heuristic.
      flips <- if (is.null(pinned_flip())) c(FALSE, TRUE) else pinned_flip()
      cands <- lapply(flips, function(fl) {
        fen <- build_fen(res$symbols, turn = "w", flip = fl)$fen
        c(list(flip = fl), track_observation(chess_ctx, g, fen, max_plies()))
      })

      statuses <- vapply(cands, function(x) x$status, character(1))
      moved <- cands[statuses == "move"]

      if (length(moved) > 1L) {
        return(note("ambiguous", "the position fits the game either way round"))
      }
      if (length(moved) == 1L) {
        acc <- moved[[1]]
        pinned_flip(acc$flip)
        g <- scored(game_accept(chess_ctx, g, acc))
        game(g)
        note("move", sprintf(
          "%s (%s)",
          paste(utils::tail(g$sans, length(acc$moves)), collapse = " "), acc$reason
        ))
        return(push_board(g, acc$moves))
      }

      # No move, but a settled reading still tells us which way round we are.
      settled <- which(statuses %in% c("unchanged", "stale"))
      if (length(settled) == 1L && is.null(pinned_flip())) {
        pinned_flip(cands[[settled[1]]]$flip)
      }
      pick <- cands[[if (length(settled)) settled[1] else 1L]]
      note(pick$status, pick$reason)
    }

    observeEvent(input$frame, {
      req(input$frame$img)
      img <- tryCatch(decode_data_url_image(input$frame$img), error = function(e) NULL)
      if (is.null(img)) {
        return(note("invalid", "the captured frame could not be decoded"))
      }
      ingest(img)
    })

    observeEvent(input$paste, {
      img <- tryCatch(decode_data_url_image(input$paste), error = function(e) NULL)
      if (is.null(img)) {
        return(note("invalid", "the pasted image could not be decoded"))
      }
      ingest(img)
    })

    # ---- readouts --------------------------------------------------------

    output$cap_state <- renderUI({
      st <- cap_status()
      label <- switch(st$state,
        capturing = "Capturing.",
        ready = "Screen shared.",
        stopped = "Capture stopped.",
        error = "Capture failed.",
        "Not capturing."
      )
      tagList(
        tags$span(class = if (identical(st$state, "error")) "cv-risk-bad" else NULL, label),
        if (nzchar(st$message %||% "")) tags$span(" ", st$message),
        if (st$state %in% c("idle", "stopped")) {
          tags$div(
            class = "cv-capture-hint",
            "Share the window with the game in it, then drag on the preview to ",
            "mark the board - a little outside it is fine, and better than ",
            "cutting into it. Keep this window visible: browsers slow timers ",
            "down in a hidden tab."
          )
        }
      )
    })
    outputOptions(output, "cap_state", suspendWhenHidden = FALSE)

    output$summary <- renderUI({
      g <- game()
      led <- ledger()
      if (is.null(g)) {
        return(tags$p(class = "text-muted", if (nrow(led)) led$reason[1] else "No game yet."))
      }
      rejected <- sum(led$status %in% c("unexplained", "ambiguous", "invalid"))
      tagList(
        tags$div(
          class = "cv-live-summary",
          sprintf("%d moves tracked.", game_ply(g)),
          if (nrow(led)) sprintf(" Last: %s - %s", led$status[1], led$reason[1])
        ),
        if (rejected > 0) {
          tags$div(
            class = "text-muted cv-radar-caption",
            sprintf(
              "%d of the last %d readings were not accepted. If that keeps happening, the board region or the piece set is probably wrong.",
              rejected, nrow(led)
            )
          )
        }
      )
    })
    outputOptions(output, "summary", suspendWhenHidden = FALSE)

    output$graph <- renderUI({
      g <- game()
      req(!is.null(g))
      eval_graph_svg(g$cp, click_input = ns("goto"))
    })
    outputOptions(output, "graph", suspendWhenHidden = FALSE)

    output$moves <- renderUI({
      g <- game()
      req(!is.null(g))
      if (!game_ply(g)) {
        return(tags$p(class = "text-muted", "No moves yet."))
      }
      losses <- game_move_losses(g)
      quality <- move_quality(losses)
      items <- lapply(seq_along(g$sans), function(i) {
        tagList(
          if (i %% 2 == 1) tags$span(class = "cv-move-no", sprintf("%d.", (i + 1) %/% 2)),
          tags$a(
            href = "#",
            class = paste("cv-move", paste0("cv-q-", quality[i])),
            onclick = sprintf(
              "Shiny.setInputValue('%s', {ply: %d, nonce: Math.random()}, {priority: 'event'}); return false;",
              ns("goto"), i
            ),
            title = if (!is.na(losses[i]) && losses[i] >= 50) {
              sprintf("%s: %s", quality[i], format_loss(losses[i]))
            } else {
              "click to review"
            },
            g$sans[i]
          )
        )
      })
      do.call(tagList, items)
    })
    outputOptions(output, "moves", suspendWhenHidden = FALSE)

    # Clicking a move - in the move list, on the graph, or in the turning
    # points - rewinds the board to just *before* it. That is the position the
    # player was actually looking at when they went wrong, and the only one the
    # engine and the radar can say anything useful about. `ply` is the move
    # under review throughout; 0 means the opening position, which no move
    # led to.
    observeEvent(input$goto, {
      g <- game()
      req(!is.null(g))
      i <- as.integer(input$goto$ply)
      req(!is.na(i), i >= 0, i <= game_ply(g))
      review(if (i == 0) NULL else i)
      to_board(list(
        fen = g$fens[max(1L, i)],
        orientation = if (isTRUE(pinned_flip())) "black" else "white",
        nonce = stats::runif(1)
      ))
    })

    output$turning <- renderUI({
      g <- game()
      req(!is.null(g))
      tp <- game_turning_points(g, min_loss = 100)
      if (!nrow(tp)) {
        return(tags$p(
          class = "text-muted",
          if (game_ply(g)) "Nothing has gone badly wrong yet." else "Nothing to show yet."
        ))
      }
      rows <- lapply(seq_len(nrow(tp)), function(i) {
        r <- tp[i, ]
        tags$a(
          href = "#", class = "cv-line cv-turning",
          onclick = sprintf(
            "Shiny.setInputValue('%s', {ply: %d, nonce: Math.random()}, {priority: 'event'}); return false;",
            ns("goto"), r$ply
          ),
          tags$span(class = "cv-line-score cv-risk-bad", format_loss(r$loss)),
          tags$span(class = "cv-line-move", sprintf(
            "%d%s %s", r$move_no, if (identical(r$mover, "w")) "." else "...", r$san
          )),
          tags$span(class = "cv-line-pv", r$quality)
        )
      })
      do.call(tagList, rows)
    })
    outputOptions(output, "turning", suspendWhenHidden = FALSE)

    output$review <- renderUI({
      i <- review()
      g <- game()
      if (is.null(i) || is.null(g)) {
        return(NULL)
      }
      losses <- game_move_losses(g)
      loss <- losses[i]
      best <- g$best[i]
      best_san <- if (!is.na(best)) {
        tryCatch(fen_move_to_san(chess_ctx, g$fens[i], best), error = function(e) NULL)
      } else {
        NULL
      }
      mover <- strsplit(g$fens[i], " ", fixed = TRUE)[[1]][2]

      tagList(
        tags$hr(),
        tags$div(
          class = sprintf(
            "alert alert-%s",
            if (!is.na(loss) && loss >= 200) "danger" else if (!is.na(loss) && loss >= 100) "warning" else "info"
          ),
          tags$strong(sprintf(
            "%d%s %s ", (i + 1L) %/% 2L, if (identical(mover, "w")) "." else "...", g$sans[i]
          )),
          if (is.na(loss)) {
            "has not been evaluated yet."
          } else if (loss >= 5000) {
            "walks into forced mate."
          } else if (loss >= 1000) {
            "loses the game outright."
          } else if (loss < 50) {
            sprintf("was fine (%.1f pawns).", loss / 100)
          } else {
            sprintf("cost %.1f pawns.", loss / 100)
          },
          if (!is.null(best_san) && !identical(best_san, g$sans[i])) {
            sprintf(" The engine wanted %s.", best_san)
          }
        ),
        div(
          class = "cv-radar-controls",
          selectInput(ns("review_rating"), "Explain it for a player rated",
            c(
              stats::setNames("auto", "Estimated from this game"),
              stats::setNames(as.character(MAIA_RATINGS), as.character(MAIA_RATINGS))
            ),
            selected = "auto", width = "260px"
          ),
          actionButton(ns("explain"), "Was this predictable?")
        ),
        uiOutput(ns("explanation"))
      )
    })
    outputOptions(output, "review", suspendWhenHidden = FALSE)

    # The Blunder Radar, pointed at a move that has already been played. It
    # cost you something - the question this answers is whether it was the kind
    # of mistake a player of this strength walks into, which is what makes it
    # worth learning from rather than shrugging off.
    # One pool of Maia networks per session for rating estimation, built on
    # first use and kept. Estimating means scoring the same moves under every
    # network, so they all have to be live at once; three lc0 processes cost
    # about 23 MB resident between them.
    rating_pool <- reactiveVal(NULL)
    session$onSessionEnded(function() maia_pool_stop(isolate(rating_pool())))

    estimated <- function(g, i) {
      pool <- rating_pool()
      if (is.null(pool)) {
        pool <- maia_pool_start()
        rating_pool(pool)
      }
      if (is.null(pool)) {
        return(NULL)
      }
      # Model whoever actually played the move being reviewed, judged on every
      # move they made in this game. Nothing needs to ask which side the user
      # is: the move under review already says whose habits are in question.
      estimate_rating(pool, g$fens, g$ucis, side = fen_turn(g$fens[i]))
    }

    explanation <- eventReactive(input$explain, {
      i <- review()
      g <- game()
      req(!is.null(i), !is.null(g))

      auto <- identical(input$review_rating, "auto")
      est <- if (auto) estimated(g, i) else NULL
      confident <- !is.null(est) && rating_estimate_is_confident(est)

      # Falling back to 1500 when the game has not yet said anything is the
      # honest move, but it must be visible - silently analysing for a rating
      # the user did not choose and the game does not support would be the
      # worst of both.
      rating <- if (auto) {
        if (confident) est$rating else 1500L
      } else {
        as.integer(input$review_rating)
      }

      if (!human_model_available(rating)) {
        return(list(error = sprintf(
          "The human model is unavailable (it needs lc0 and the maia-%d weights).",
          match_maia_rating(rating)
        )))
      }
      m <- maia_session_start(rating)
      if (is.null(m)) {
        return(list(error = "The human model could not be started."))
      }
      on.exit(maia_session_stop(m), add = TRUE)
      rad <- tryCatch(blunder_risk(g$fens[i], m, movetime_ms = 700),
        error = function(e) NULL
      )
      if (is.null(rad) || is.na(rad$risk)) {
        return(list(error = "The radar could not assess this position."))
      }
      list(
        radar = rad, played = g$ucis[i], fen = g$fens[i],
        rating = match_maia_rating(rating),
        estimate = est, auto = auto, estimated_ok = confident
      )
    })

    output$explanation <- renderUI({
      ex <- tryCatch(explanation(), error = function(e) NULL)
      req(!is.null(ex))
      if (!is.null(ex$error)) {
        return(tags$p(class = "text-muted", ex$error))
      }
      rad <- ex$radar
      hit <- which(rad$moves$move == ex$played)
      played_san <- tryCatch(fen_move_to_san(chess_ctx, ex$fen, ex$played),
        error = function(e) NULL
      ) %||% ex$played

      # Where the rating came from, stated plainly. An estimate is evidence,
      # not a measurement: it is right about 94% of the time when it clears
      # the confidence bar, and it declines to answer roughly two thirds of
      # the time, so saying which of those happened matters more than the
      # number itself.
      provenance <- if (!isTRUE(ex$auto)) {
        NULL
      } else if (isTRUE(ex$estimated_ok)) {
        est <- ex$estimate
        tags$p(
          class = "text-muted cv-radar-caption",
          sprintf(
            "Rating estimated at %d from %d of their moves in this game (%.0f%% of the posterior; right about 94%% of the time it is this sure).",
            est$rating, est$n_moves, 100 * max(est$posterior)
          )
        )
      } else {
        n <- if (is.null(ex$estimate)) 0L else ex$estimate$n_moves
        tags$p(
          class = "text-muted cv-radar-caption",
          sprintf(
            paste0(
              "Their moves so far (%d) do not pin down a rating - either too few, or the kind ",
              "any strength would have played. Explained for 1500 instead; pick a rating above to override."
            ),
            n
          )
        )
      }

      verdict <- if (!length(hit)) {
        tags$div(
          class = "alert alert-info cv-radar-summary",
          sprintf(
            "The radar did not expect %s here at all - a %d player almost never plays it. An unlucky one-off rather than a habit.",
            played_san, ex$rating
          )
        )
      } else {
        row <- rad$moves[hit[1], ]
        rank <- which(order(-rad$moves$contribution) == hit[1])
        tags$div(
          class = sprintf(
            "alert alert-%s cv-radar-summary",
            if (row$loss >= 100) "danger" else "warning"
          ),
          sprintf(
            "A %d player plays %s here %.0f%% of the time, and it is the %s largest source of risk in this position. This was predictable, not unlucky.",
            ex$rating, played_san, 100 * row$prob,
            c("single", "second", "third", "fourth")[min(4, rank)]
          )
        )
      }

      rows <- lapply(seq_len(min(4, nrow(rad$moves))), function(i) {
        mv <- rad$moves[i, ]
        san <- tryCatch(fen_move_to_san(chess_ctx, ex$fen, mv$move), error = function(e) NULL)
        tags$div(
          class = "cv-line",
          tags$span(class = "cv-line-score", sprintf("%.0f%%", 100 * mv$prob)),
          tags$span(
            class = if (identical(mv$move, ex$played)) "cv-line-move cv-risk-bad" else "cv-line-move",
            san %||% mv$move
          ),
          tags$span(
            class = if (mv$loss >= 100) "cv-risk-bad" else "cv-line-pv",
            if (mv$loss >= 20) sprintf("loses %.1f pawns", mv$loss / 100) else "sound"
          )
        )
      })

      tagList(
        provenance,
        verdict,
        tags$div(
          class = "text-muted cv-radar-caption",
          "What a player of that strength would consider here:"
        ),
        do.call(tagList, rows)
      )
    })
    outputOptions(output, "explanation", suspendWhenHidden = FALSE)

    to_board
  })
}
