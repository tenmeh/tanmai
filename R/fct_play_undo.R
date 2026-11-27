#' Check whether a standard-start computer game has a player decision to undo
#' @param state Browser board state with move history.
#' @param side Player colour, w or b.
#' @return TRUE when the player has made at least one move.
#' @examples
#' play_undo_available(list(history = c("e4", "e5")), "b")
#' @noRd
play_undo_available <- function(state, side) {
  if (length(side) != 1L || is.na(side) || !side %in% c("w", "b")) {
    return(FALSE)
  }
  length(state$history) >= if (side == "w") 1L else 2L
}
