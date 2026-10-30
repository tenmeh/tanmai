#' Top-level Shiny server
#'
#' @param input,output,session Standard Shiny server arguments.
#' @return Called for its side effects; wires up the module servers.
app_server <- function(input, output, session) {
  # One chess.js (V8) context per session, reused across analyses/calibrations.
  chess_ctx <- new_chess_context()

  mod_practice_server("learn", chess_ctx, mode = "learn")
  from_play <- mod_practice_server("play", chess_ctx, mode = "play")
  mod_puzzles_server("puzzles", chess_ctx)
  play_review <- reactiveVal(NULL)
  last_handoff <- reactiveVal(NULL)
  observeEvent(from_play()$review_request, {
    request <- from_play()$review_request
    req(request, !identical(request$nonce, last_handoff()))
    last_handoff(request$nonce); play_review(request)
    bslib::nav_select("main_tabs", "review", session = session)
  })
  output$review_context <- renderUI({
    request <- play_review(); req(request)
    div(class = "cv-card", h2("Your computer game"),
      p(sprintf("You played %s against %s (%s, %s). %s",
        if (request$side == "b") "Black" else "White", request$opponent,
        request$strength, request$style,
        if (request$finished) "Game complete. Explore the key moments below." else "Game paused. Resume it from Play when you are ready.")),
      actionButton("return_to_play", "Back to Play"))
  })
  observeEvent(input$return_to_play, bslib::nav_select("main_tabs", "play", session = session))

  # Two things can put a position on the board: a screenshot just analysed, and
  # the live tracker following a game. Whichever spoke last wins - they are
  # both the user acting, and neither should be able to yank the board away
  # from the other retrospectively.
  from_analyze <- mod_analyze_server("analyze", chess_ctx)
  from_live <- mod_live_server("live", chess_ctx, incoming = play_review)

  to_board <- reactiveVal(NULL)
  observeEvent(from_analyze(), {
    play_review(NULL)
    to_board(from_analyze())
  })
  observeEvent(from_live(), {
    msg <- from_live()
    request <- play_review()
    if (!is.null(request) && !identical(msg$pgn, request$pgn)) play_review(NULL)
    to_board(msg)
  })

  mod_board_server("board", chess_ctx, incoming = to_board)
  mod_calibrate_server("calibrate", chess_ctx)
}
