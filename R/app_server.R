#' Top-level Shiny server
#'
#' @param input,output,session Standard Shiny server arguments.
#' @return Called for its side effects; wires up the module servers.
app_server <- function(input, output, session) {
  # One chess.js (V8) context per session, reused across analyses/calibrations.
  chess_ctx <- new_chess_context()

  mod_practice_server("learn", chess_ctx, mode = "learn")
  mod_practice_server("play", chess_ctx, mode = "play")

  # Two things can put a position on the board: a screenshot just analysed, and
  # the live tracker following a game. Whichever spoke last wins - they are
  # both the user acting, and neither should be able to yank the board away
  # from the other retrospectively.
  from_analyze <- mod_analyze_server("analyze", chess_ctx)
  from_live <- mod_live_server("live", chess_ctx)

  to_board <- reactiveVal(NULL)
  observeEvent(from_analyze(), to_board(from_analyze()))
  observeEvent(from_live(), to_board(from_live()))

  mod_board_server("board", chess_ctx, incoming = to_board)
  mod_calibrate_server("calibrate", chess_ctx)
}
