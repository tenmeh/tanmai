#' Original composed tactical starter collection
#'
#' Four patterns, each shown from both colours. These are exercises, not
#' rated game positions. Replies follow a selected legal training line.
#' @return A list of eight puzzle records.
#' @examples
#' length(puzzle_catalog())
#' @noRd
puzzle_catalog <- function() {
  puzzle <- function(id, topic, difficulty, title, fen, line, goal, hints, reasons, why) {
    list(id = id, topic = topic, difficulty = difficulty, title = title,
      fen = fen, line = line, goal = goal, hints = hints, reasons = reasons, why = why)
  }
  originals <- list(
    puzzle("fork", "Fork", "Starter", "Check, then collect",
      "r3k3/8/8/3N4/8/8/8/6K1 w - - 0 1",
      c("d5c7", "e8d7", "c7a8"),
      "Win the rook with a checking knight fork.",
      c("Look for a knight check that attacks another valuable piece.",
        "The king has moved. Take the rook that your knight also attacked."),
      c("The knight checks the king and attacks the rook at once.",
        "The rook falls while the king has no way to recapture your knight."),
      "A checking fork wins time: the king must answer the check, leaving the other target behind."),
    puzzle("back-rank", "Back rank", "Challenge", "Remove the last defender",
      "5rk1/5ppp/8/8/8/8/4Q3/4R1K1 w - - 0 1",
      c("e2e8", "f8e8", "e1e8"),
      "Deliver mate in two moves.",
      c("The rook guards the back rank. Look for a forcing queen sacrifice.",
        "The defender has been drawn onto your rook's open file."),
      c("The queen gives check. The defending rook must capture it.",
        "The rook recaptures with mate; the king's pawns block its escape."),
      "The queen sacrifice removes the back-rank defender. The second rook check then leaves no safe square."),
    puzzle("breakthrough", "Pawn breakthrough", "Challenge", "Open the other lane",
      "7k/ppp5/8/PPP5/8/8/8/7K w - - 0 1",
      c("b5b6", "a7b6", "a5a6", "b7a6", "c5c6"),
      "Create a passed pawn against the shown defence.",
      c("Offer the middle pawn to split the pawn wall.",
        "The first capture opens a lane on the other side. Offer that outside pawn.",
        "Two defenders have moved away. Advance the remaining pawn into the gap."),
      c("The middle pawn pulls an outside defender away.",
        "The second offer pulls the central defender away too.",
        "The remaining pawn is passed: no enemy pawn can stop it from the front or adjacent files."),
      "The two pawn offers create a passed pawn. Against the other first capture, the plan works on the other side. This puzzle follows one defensive line."),
    puzzle("promotion", "Promotion", "Starter", "Promote with a capture",
      "r6k/1P6/8/8/8/8/8/7K w - - 0 1",
      "b7a8q",
      "Capture the rook and promote. Promotions use a queen.",
      "Check the pawn's diagonal captures on the last rank.",
      "The pawn captures a rook and becomes a queen in the same move.",
      "Promotion can happen on a capture. The queen gives check along the back rank while winning the rook.")
  )
  mirrored <- lapply(originals, function(item) {
    other <- practice_transfer(list(fen = item$fen, solutions = item$line))
    item$id <- paste0(item$id, "-black")
    item$title <- paste(item$title, "(Black)")
    item$fen <- other$fen
    item$line <- unname(other$solutions)
    item
  })
  c(originals, mirrored)
}

#' Filter the starter collection without inventing ratings
#' @param catalog Puzzle records.
#' @param topic A topic or All.
#' @param difficulty Starter, Challenge or All.
#' @return The matching records, possibly empty.
#' @examples
#' length(puzzle_filter(puzzle_catalog(), "Fork"))
#' @noRd
puzzle_filter <- function(catalog, topic = "All", difficulty = "All") {
  if (!is.list(catalog)) stop("`catalog` must be a list.", call. = FALSE)
  if (!is.character(topic) || length(topic) != 1L || is.na(topic)) {
    stop("`topic` must be one non-missing string.", call. = FALSE)
  }
  if (!is.character(difficulty) || length(difficulty) != 1L || is.na(difficulty)) {
    stop("`difficulty` must be one non-missing string.", call. = FALSE)
  }
  Filter(function(item) {
    (topic == "All" || item$topic == topic) &&
      (difficulty == "All" || item$difficulty == difficulty)
  }, catalog)
}

#' Advance one solver turn and the selected opponent response
#'
#' Rebuilds the expected position from the catalog; browser FEN and outcome
#' claims are never trusted. A wrong move leaves the current step unchanged.
#' @param ctx A chess.js context.
#' @param item A record from puzzle_catalog().
#' @param ply Odd index of the next solver move.
#' @param move The attempted UCI move.
#' @return Accepted flag, next ply, authoritative FEN, response and completion.
#' @examples
#' \dontrun{puzzle_advance(new_chess_context(), puzzle_catalog()[[1]], 1L, "d5c7")}
#' @noRd
puzzle_advance <- function(ctx, item, ply, move) {
  if (!is.list(item) || !is.character(item$line) || !length(item$line)) {
    stop("`item` must contain a non-empty move line.", call. = FALSE)
  }
  if (!is.numeric(ply) || length(ply) != 1L || is.na(ply) ||
      ply != as.integer(ply) || ply < 1L || ply > length(item$line) || ply %% 2L != 1L) {
    stop("`ply` must identify a solver turn in the line.", call. = FALSE)
  }
  if (!is.character(move) || length(move) != 1L || is.na(move) ||
      !grepl("^[a-h][1-8][a-h][1-8][qrbn]?$", move)) {
    stop("`move` must be one UCI move.", call. = FALSE)
  }
  fen <- item$fen
  if (ply > 1L) for (previous in item$line[seq_len(ply - 1L)]) {
    fen <- fen_after_move(ctx, fen, previous)
  }
  if (!identical(move, item$line[[ply]])) {
    return(list(accepted = FALSE, ply = ply, fen = fen, reply = NULL, complete = FALSE))
  }
  fen <- fen_after_move(ctx, fen, move)
  if (is.null(fen) || is.na(fen)) stop("Puzzle move is not legal.", call. = FALSE)
  reply <- if (ply < length(item$line)) item$line[[ply + 1L]] else NULL
  if (!is.null(reply)) fen <- fen_after_move(ctx, fen, reply)
  if (is.null(fen) || is.na(fen)) stop("Puzzle reply is not legal.", call. = FALSE)
  list(accepted = TRUE, ply = ply + 2L, fen = fen, reply = reply,
    complete = ply >= length(item$line))
}
