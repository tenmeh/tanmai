#' Board-first learning or computer play workspace
#' @param id Module id.
#' @param mode Either learn or play.
#' @return A Shiny tag list.
#' @noRd
mod_practice_ui <- function(id, mode = "learn") {
  ns <- NS(id)
  div(class = paste("cv-practice cv-practice-", mode, sep = ""),
    div(class = "cv-practice-board-area",
      div(class = "cv-practice-topline",
        span(class = "cv-eyebrow", if (mode == "learn") "YOUR DAILY PRACTICE" else "A GAME AT YOUR PACE"),
        span(textOutput(ns("turn"), inline = TRUE))),
      div(class = "cv-practice-board-frame", div(id = ns("board"), class = "cv-board")),
      div(class = "cv-practice-board-footer",
        span("Tap a piece, then a square. Or drag to move."),
        actionButton(ns("flip"), "Flip board", class = "btn-sm")),
      if (mode == "play") div(class = "cv-practice-moves", textOutput(ns("moves")))
    ),
    tags$aside(class = "cv-task-panel",
      if (mode == "learn") tagList(
        span(class = "cv-eyebrow", "LEARN BY DOING"),
        selectInput(ns("level"), "Your level", c("Beginner" = "beginner", "Improver" = "improver", "Club" = "club"), selectize = FALSE),
        radioButtons(ns("topic"), "Focus", c("Opening", "Tactics", "Endgame"), inline = TRUE),
        uiOutput(ns("lesson")),
        div(class = "cv-actions", actionButton(ns("demo"), "Show example"), actionButton(ns("start_exercise"), "Try it yourself", class = "btn-primary")),
        div(class = "cv-task-feedback", `aria-live` = "polite", textOutput(ns("feedback"))),
        div(class = "cv-actions",
          actionButton(ns("hint"), "Give me a hint"),
          actionButton(ns("retry"), "Try again"),
          actionButton(ns("next_lesson"), "Next topic", class = "btn-primary")),
        uiOutput(ns("explanation")),
        div(class = "cv-progress-card",
          span(class = "cv-eyebrow", "YOUR PRACTICE"),
          textOutput(ns("progress")),
          p(class = "small text-muted", "Saved on this browser. This records practice, not a rating or proof of mastery."),
          actionButton(ns("clear_progress"), "Reset practice record", class = "btn-sm"))
      ) else tagList(
        span(class = "cv-eyebrow", "PLAY THE COMPUTER"),
        h1("Make room to think."),
        p(class = "cv-task-intro", "Choose a challenge and a style. Play an untimed game without hints."),
        selectInput(ns("strength"), "Challenge", c("Casual" = "casual", "Club" = "club", "Challenging" = "challenging"), selectize = FALSE),
        selectInput(ns("style"), "Style", c("Balanced" = "balanced", "Attacking" = "attacking", "Solid" = "solid"), selectize = FALSE),
        selectInput(ns("side"), "Play as", c("White" = "w", "Black" = "b"), selectize = FALSE),
        p(class = "small text-muted", "Challenge controls search effort, not a calibrated Elo. Style favours checks and captures, or castling and quieter moves, among similar choices."),
        actionButton(ns("new_game"), "Start new game", class = "btn-primary"),
        p(class = "small text-muted", "Choices apply when you start a new game. Promotions use a queen."),
        div(class = "cv-task-feedback", `aria-live` = "polite", textOutput(ns("feedback"))),
        textOutput(ns("opponent")),
        downloadButton(ns("pgn"), "Save game as PGN", class = "btn-sm"),
        uiOutput(ns("game_actions"))
      )
    )
  )
}

#' Guided exercise and computer game server
#' @param id Module id.
#' @param chess_ctx Chess.js context for legal moves.
#' @param mode Either learn or play.
#' @return A reactive snapshot for tests and integration.
#' @noRd
mod_practice_server <- function(id, chess_ctx, mode = "learn") {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    catalog <- practice_lessons()
    current <- reactiveVal(catalog[[1]])
    solved <- reactiveVal(FALSE)
    stage <- reactiveVal("study")
    exercise <- reactive({
      if (stage() == "transfer") practice_transfer(current()) else list(fen = current()$fen, solutions = current()$solutions)
    })
    hint_index <- reactiveVal(0L)
    feedback <- reactiveVal(if (mode == "learn") "Your turn. Try the idea on the board." else "Start a game when you are ready.")
    progress <- reactiveVal(list(completed = character(), attempts = 0L, hints = 0L))
    ready <- reactiveVal(FALSE)
    game_settings <- reactiveVal(NULL)
    engine <- NULL
    thinking <- reactiveVal(NULL)
    paused <- reactiveVal(FALSE)
    review_request <- reactiveVal(NULL)
    review_sequence <- 0L
    game_sequence <- 0L
    last_event <- reactiveVal(NULL)
    session$onSessionEnded(function() engine_session_stop(engine))

    policy <- function(side = "w", locked = FALSE) {
      session$sendCustomMessage("tanmai-board-policy", list(container = ns("board"), side = side, locked = locked, practice = TRUE))
    }
    set_board <- function(fen, side = "w", locked = FALSE) {
      session$sendCustomMessage("tanmai-board-set", list(container = ns("board"), fen = fen,
        orientation = if (side == "b") "black" else "white", side = side, locked = locked, practice = TRUE))
    }
    save_progress <- function() {
      session$sendCustomMessage("tanmai-progress-save", list(value = progress(), input = ns("storage_error")))
    }
    load_lesson <- function() {
      level <- input$level %||% "beginner"
      topic <- input$topic %||% "Opening"
      item <- Filter(function(x) x$level == level && x$topic == topic, catalog)[[1]]
      current(item); solved(FALSE); stage("study"); hint_index(0L); last_event(NULL)
      feedback("Read the idea, watch the example, then try it yourself.")
      if (ready()) set_board(item$fen, locked = TRUE)
    }
    session$onFlushed(function() {
      session$sendCustomMessage("tanmai-board-create", list(container = ns("board"), stateInput = ns("state"),
        fen = if (mode == "learn") catalog[[1]]$fen else CV_START_FEN,
        orientation = "white", pieceTheme = piece_theme_base("cburnett"),
        side = "w", locked = TRUE, practice = TRUE))
      ready(TRUE)
      if (mode == "learn") session$sendCustomMessage("tanmai-progress-load", list(input = ns("saved_progress")))
    }, once = TRUE)

    observeEvent(input$flip, {
      session$sendCustomMessage("tanmai-board-flip", list(container = ns("board")))
    })

    if (mode == "learn") {
      observeEvent(list(input$level, input$topic), load_lesson())
      observeEvent(input$retry, load_lesson())
      observeEvent(input$demo, {
        stage("demo"); solved(FALSE); hint_index(0L)
        set_board(current()$fen, locked = TRUE)
        session$sendCustomMessage("tanmai-board-move", list(container = ns("board"), uci = current()$solutions[1]))
        feedback(paste("Watch the move.", current()$why, "Select Try it yourself to practise."))
      })
      observeEvent(input$start_exercise, {
        if (stage() == "ready-transfer") {
          stage("transfer"); hint_index(0L)
          position <- practice_transfer(current())
          set_board(position$fen, side = "b")
          feedback("Now apply the same idea as Black. Find the matching move without the example.")
        } else {
          stage("practice"); solved(FALSE); hint_index(0L)
          set_board(current()$fen)
          feedback(current()$prompt)
        }
      })
      observeEvent(input$next_lesson, {
        topics <- c("Opening", "Tactics", "Endgame")
        updateRadioButtons(session, "topic", selected = topics[match(input$topic, topics) %% 3L + 1L])
      })
      observeEvent(input$saved_progress, {
        p <- input$saved_progress
        if (isTRUE(p$storage_error)) showNotification("Browser storage is unavailable. Progress lasts for this session only.", type = "warning")
        ids <- vapply(catalog, `[[`, character(1), "id")
        valid_count <- function(x) if (is.numeric(x) && length(x) == 1 && is.finite(x) && x >= 0) as.integer(min(x, 1000000)) else 0L
        progress(list(completed = intersect(as.character(p$completed), ids), attempts = valid_count(p$attempts), hints = valid_count(p$hints)))
      })
      observeEvent(input$storage_error, showNotification("Browser storage is unavailable. Progress lasts for this session only.", type = "warning"))
      observeEvent(input$clear_progress, {
        progress(list(completed = character(), attempts = 0L, hints = 0L)); save_progress()
      })
      observeEvent(input$hint, {
        if (!stage() %in% c("practice", "transfer")) {
          feedback("Select Try it yourself to start the exercise before asking for a hint."); return()
        }
        i <- min(hint_index() + 1L, 2L); hint_index(i)
        feedback(if (stage() == "transfer") {
          if (i == 1L) "Use the same idea for Black. Think about the goal, then check your legal moves." else paste0("Try ", exercise()$solutions[1], ".")
        } else current()$hints[i])
        p <- progress(); p$hints <- p$hints + 1L; progress(p); save_progress()
        if (i == 2L) session$sendCustomMessage("tanmai-board-arrows", list(container = ns("board"),
          arrows = list(list(from = substr(exercise()$solutions[1], 1, 2), to = substr(exercise()$solutions[1], 3, 4), color = "#a26927", width = 8))))
      })
      observeEvent(input$state, {
        st <- input$state
        req(stage() %in% c("practice", "transfer"), !is.null(st$last_uci), identical(st$last_before, exercise()$fen))
        event <- paste(st$last_before, st$last_uci, st$nonce)
        req(!identical(last_event(), event)); last_event(event)
        p <- progress(); p$attempts <- p$attempts + 1L
        if (st$last_uci %in% exercise()$solutions) {
          policy(locked = TRUE)
          if (stage() == "transfer") {
            solved(TRUE); stage("done")
            feedback("Lesson complete. You used the idea for both colours.")
            p$completed <- union(p$completed, current()$id)
          } else {
            stage("ready-transfer")
            feedback("You found the idea. Select Try as Black for a second position.")
          }
        } else {
          reasons <- c(
            "beginner-opening" = "This move does not advance a central pawn two squares.",
            "beginner-tactics" = "The loose queen is still on the board. Look for a rook capture.",
            "beginner-endgame" = "The pawn has not reached the last rank yet.",
            "improver-opening" = "The king is still in the centre. Look for castling.",
            "improver-tactics" = "This move does not check the king and attack the rook together.",
            "improver-endgame" = "The king and queen must cover all escape squares while giving check. Find the demonstrated queen move.",
            "club-opening" = "Find a developing bishop move that also gives check.",
            "club-tactics" = "A back-rank rook check closes all the king's escape squares.",
            "club-endgame" = "Moving an outside pawn first lets Black keep the pawn wall. Offer the middle pawn."
          )
          feedback(paste(reasons[[current()$id]], "Try again, or ask for a hint."))
          set_board(exercise()$fen, side = if (stage() == "transfer") "b" else "w")
        }
        progress(p); save_progress()
      })
    } else {
      start_game <- function(settings) {
        game_sequence <<- game_sequence + 1L
        settings$game_id <- game_sequence
        thinking(NULL); paused(FALSE)
        engine_session_stop(engine); engine <<- NULL
        local <- find_local_engine()
        if (!is.null(local)) engine <<- engine_session_start(multipv = 5L, engine_path = local)
        if (!is.null(engine)) engine$process$write_input(sprintf("setoption name Skill Level value %d\n", c(casual = 0L, club = 6L, challenging = 14L)[settings$strength]))
        settings$engine <- if (is.null(engine)) "Built-in computer" else "Stockfish"
        game_settings(settings); last_event(NULL)
        feedback(if (settings$side == "w") "You are White. Make your first move." else "You are Black. The computer moves first.")
        set_board(CV_START_FEN, side = settings$side)
      }
      observeEvent(input$new_game, start_game(list(
        strength = input$strength, style = input$style, side = input$side)))
      observeEvent(input$rematch, {
        req(game_settings())
        start_game(game_settings())
      })
      observeEvent(input$review_game, {
        request <- play_review_snapshot(chess_ctx, input$state, game_settings())
        if (!is.null(request$error)) {feedback(request$error); return()}
        paused(TRUE); thinking(NULL)
        if (!is.null(engine)) try(engine$process$write_input("stop\n"), silent = TRUE)
        policy(side = game_settings()$side, locked = TRUE)
        review_sequence <<- review_sequence + 1L
        request$nonce <- review_sequence
        review_request(request)
        feedback(if (request$finished) "Your game is ready in Review." else "Game paused for review. Resume here when you are ready.")
      }, priority = 100)
      observeEvent(input$resume, {
        req(game_settings(), !isTRUE(input$state$game_over))
        paused(FALSE); last_event(NULL)
        policy(side = game_settings()$side)
        feedback("Game resumed. Take your time.")
        session$sendCustomMessage("tanmai-board-sync", list(container = ns("board")))
      })
      output$game_actions <- renderUI({
        st <- input$state
        if (is.null(game_settings()) || !length(st$history)) {
          return(p(class = "small text-muted", "After your first move, you can pause and review this game directly."))
        }
        finished <- isTRUE(st$game_over)
        div(class = "cv-subpanel",
          h3(if (finished) "Game complete" else if (paused()) "Game paused" else "Explore your game"),
          p(if (finished) "Review the key moments, or play the same opponent again." else "Pause and review the moves played so far. Your game stays here."),
          div(class = "cv-actions",
            actionButton(ns("review_game"), if (finished) "Review game" else "Pause and review", class = "btn-primary"),
            if (paused() && !finished) actionButton(ns("resume"), "Resume game"),
            if (finished) actionButton(ns("rematch"), "Rematch")))
      })
      play_reply <- function(fen, move) {
        if (is.null(move) || !move %in% legal_moves(chess_ctx, fen)) {
          feedback("The computer could not choose a move. Start a new game to try again."); policy(locked = TRUE)
          return()
        }
        session$sendCustomMessage("tanmai-board-move", list(container = ns("board"), uci = move))
        feedback("Your turn. Take your time.")
      }
      observeEvent(input$state, {
        st <- input$state; settings <- game_settings(); req(settings, !paused())
        if (isTRUE(st$game_over)) {
          thinking(NULL); policy(locked = TRUE)
          feedback(if (isTRUE(st$checkmate)) {
            if (st$turn == settings$side) "Checkmate. The computer wins. Select Review game to explore it." else "Checkmate. You win. Select Review game to explore it."
          } else "Game drawn. Select Review game to explore it.")
          return()
        }
        req(identical(st$turn, if (settings$side == "w") "b" else "w"))
        req(!identical(last_event(), st$fen)); last_event(st$fen)
        feedback("The computer is thinking...")
        if (is.null(engine)) {
          move <- tryCatch(practice_computer_move(chess_ctx, st$fen, settings$strength, settings$style), error = function(e) {
            message("WARN code=ERR-PLAY-001 ", conditionMessage(e)); NULL
          })
          play_reply(st$fen, move)
        } else {
          ok <- tryCatch(engine_session_analyse(engine, st$fen), error = function(e) {
            message("WARN code=ERR-PLAY-002 ", conditionMessage(e)); FALSE
          })
          if (isTRUE(ok)) thinking(list(fen = st$fen, start = Sys.time())) else {
            feedback("Stockfish is unavailable. Start a new game to retry."); policy(locked = TRUE)
          }
        }
      })
      observe({
        pending <- thinking(); req(pending, !paused())
        invalidateLater(100, session)
        settings <- game_settings()
        elapsed <- as.numeric(difftime(Sys.time(), pending$start, units = "secs"))
        limit <- c(casual = .25, club = .5, challenging = .9)[settings$strength]
        snap <- tryCatch(engine_session_poll(engine), error = function(e) {
          message("WARN code=ERR-PLAY-003 ", conditionMessage(e)); NULL
        })
        if (elapsed < limit || (elapsed < 3 && (is.null(snap) || !length(snap$lines)))) return()
        thinking(NULL)
        if (!is.null(engine)) engine$process$write_input("stop\n")
        if (is.null(snap) || !length(snap$lines)) {
          feedback("The computer search stopped. Start a new game to retry."); policy(locked = TRUE); return()
        }
        lines <- snap$lines
        score <- vapply(lines, function(x) score_to_cp(x$cp, x$mate), numeric(1))
        sans <- vapply(lines, function(x) fen_move_to_san(chess_ctx, pending$fen, x$first) %||% "", character(1))
        selected <- practice_choose_candidate(score, sans, settings$strength, settings$style)
        if (!length(selected)) {
          feedback("The computer search had no scored moves. Start a new game to retry.")
          policy(locked = TRUE); return()
        }
        play_reply(pending$fen, lines[[selected]]$first)
      })
      output$opponent <- renderText({
        s <- game_settings()
        if (is.null(s)) "Ready when you are." else paste(s$engine, "-", tools::toTitleCase(s$strength), "/", s$style,
          if (s$engine == "Built-in computer") "(local search; Stockfish not available)" else "")
      })
      output$pgn <- downloadHandler(filename = function() "tanmai-practice.pgn", content = function(file) {
        writeLines(input$state$pgn %||% "", file)
      })
    }
    if (mode == "learn") observe({
      updateActionButton(session, "start_exercise", label = if (stage() == "ready-transfer") "Try as Black" else "Try it yourself")
    })
    output$turn <- renderText({
      st <- input$state
      if (is.null(st)) "White to move" else if (isTRUE(st$game_over)) "Game complete" else if (st$turn == "b") "Black to move" else "White to move"
    })
    output$lesson <- renderUI({
      item <- current()
      concepts <- c(
        "beginner-opening" = "The four middle squares are useful territory. A central pawn moved two squares controls space and opens a line for a bishop.",
        "beginner-tactics" = "Rooks travel along ranks and files. Before a quiet move, scan those lines for enemy pieces that have no defender.",
        "beginner-endgame" = "A pawn that reaches the last rank becomes a new piece. A queen is usually the strongest choice; this board promotes to a queen automatically.",
        "improver-opening" = "Castling moves the king two squares toward a rook, then brings the rook beside it. The path must be clear, and the king cannot start in check or cross an attacked square.",
        "improver-tactics" = "A knight fork attacks two pieces at once. A checking fork is powerful because the opponent must save the king before the other piece.",
        "improver-endgame" = "A queen alone can check, but the king helps close escape squares. For mate, check the king, cover every flight square and keep the queen safe.",
        "club-opening" = "Developing with tempo means improving a piece while making a threat the opponent must answer. Check can do both when the king's diagonal has opened.",
        "club-tactics" = "A king behind its own pawns can be trapped on the back rank. An invading rook gives mate if it covers the rank and no defender can capture or block it.",
        "club-endgame" = "A pawn breakthrough sacrifices material to create a passed pawn. Offer the middle pawn, then use Black's capture to open a path on the other side."
      )
      tagList(span(class = "cv-lesson-number", paste(tools::toTitleCase(item$level), "/", item$topic)),
        h2(item$title), p(concepts[[item$id]]),
        tags$ol(class = "cv-lesson-steps", tags$li("Study the idea and example"), tags$li("Practise the move as White"), tags$li("Apply the idea as Black")),
        p(if (stage() == "done") "Lesson complete. Review the idea below, retry it, or move to the next topic." else if (stage() == "transfer") "Black to move. Apply the idea to this second position." else item$prompt))
    })
    output$feedback <- renderText(feedback())
    output$explanation <- renderUI({
      if (stage() %in% c("demo", "ready-transfer", "done")) div(class = "cv-lesson-explanation", h3("Why it works"), p(current()$why))
    })
    output$progress <- renderText({
      p <- progress()
      sprintf("%d / %d lessons completed | %d attempts | %d hints", length(p$completed), length(catalog), p$attempts, p$hints)
    })
    output$moves <- renderText({
      moves <- input$state$history
      if (!length(moves)) return("Your moves will appear here.")
      paste(vapply(seq_along(moves), function(i) paste0(if (i %% 2L == 1L) paste0((i + 1L) %/% 2L, ". ") else "", moves[[i]]), character(1)), collapse = " ")
    })
    reactive(list(lesson = current(), stage = stage(), solved = solved(), progress = progress(), settings = game_settings(), feedback = feedback(),
      paused = paused(), review_request = review_request()))
  })
}
