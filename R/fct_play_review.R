#' Validate a computer game snapshot for direct review
#' @param ctx A chess.js context.
#' @param state Browser board state including PGN, history and FEN.
#' @param settings Active computer game settings.
#' @return A complete review request, or a list with a safe error message.
#' @noRd
play_review_snapshot <- function(ctx, state, settings) {
  if (is.null(settings) || !length(state$history)) {
    return(list(error = "Play at least one move before opening Review."))
  }
  parsed <- game_from_pgn(ctx, state$pgn %||% "")
  if (!is.null(parsed$error)) {
    return(list(error = "The game could not be copied to Review. Your game is still available here."))
  }
  if (!identical(tail(parsed$game$fens, 1), state$fen) ||
      !identical(parsed$game$sans, as.character(unlist(state$history)))) {
    return(list(error = "The board is still updating. Wait for the move to finish, then try Review again."))
  }
  list(pgn = state$pgn, fen = state$fen, game = parsed$game,
    game_id = settings$game_id %||% 0L,
    side = settings$side, orientation = if (settings$side == "b") "black" else "white",
    opponent = settings$engine, strength = settings$strength, style = settings$style,
    finished = isTRUE(state$game_over), checkmate = isTRUE(state$checkmate))
}

#' Score terminal positions without waiting for an engine principal variation
#' @param ctx A chess.js context.
#' @param fen A legal FEN.
#' @return A White-perspective centipawn score, or NA for a nonterminal position.
#' @noRd
review_terminal_score <- function(ctx, fen) {
  ctx$assign("reviewTerminalFen", fen)
  value <- ctx$eval("(function(){var g=new ChessCtor(reviewTerminalFen); return g.isCheckmate() ? (g.turn()==='w' ? -100000 : 100000) : g.isDraw() ? 0 : 'pending';})()")
  if (identical(value, "pending")) NA_real_ else as.numeric(value)
}
