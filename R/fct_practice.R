#' Small guided lesson catalog
#'
#' @return Named list of exercises with legal starting positions and solutions.
#' @examples
#' names(practice_lessons())
#' @noRd
practice_lessons <- function() {
  lesson <- function(id, level, topic, title, fen, solutions, prompt, hints, why) {
    list(id = id, level = level, topic = topic, title = title, fen = fen,
         solutions = solutions, prompt = prompt, hints = hints, why = why)
  }
  list(
    lesson("beginner-opening", "beginner", "Opening", "Claim the centre",
      CV_START_FEN, c("e2e4", "d2d4"),
      "White to move. Advance a central pawn two squares to give your pieces room.",
      c("The d- and e-pawns can claim central space.", "Try e2 to e4, or d2 to d4."),
      "A central pawn controls useful squares and opens a path for a bishop."),
    lesson("beginner-tactics", "beginner", "Tactics", "Look for loose pieces",
      "q6k/8/8/8/8/8/8/R6K w - - 0 1", "a1a8",
      "White to move. A queen has no defender. Win it with your rook.",
      c("Scan along the rook's open file.", "The rook on a1 can capture on a8."),
      "Before making a quiet move, look for valuable pieces you can take safely."),
    lesson("beginner-endgame", "beginner", "Endgame", "Promote your pawn",
      "7k/P7/8/8/8/8/8/7K w - - 0 1", "a7a8q",
      "White to move. Turn your pawn into a queen. Promotions use a queen here.",
      c("A pawn promotes when it reaches the last rank.", "Move a7 to a8."),
      "A queen is usually the strongest promotion. This board promotes to a queen automatically."),
    lesson("improver-opening", "improver", "Opening", "Put your king to safety",
      "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
      "e1g1", "White to move. Develop your rook and shelter your king in one move.",
      c("The squares between your king and kingside rook are clear.", "Castle: move the king from e1 to g1."),
      "Castling connects king safety with rook development. Always check that the king's path is safe."),
    lesson("improver-tactics", "improver", "Tactics", "A knight's double attack",
      "r3k3/8/8/3N4/8/8/8/6K1 w - - 0 1", "d5c7",
      "White to move. Check the king and attack the rook with the same knight move.",
      c("Look for a checking square that also attacks a8.", "Move the knight from d5 to c7."),
      "Nc7+ forks the king on e8 and the rook on a8. The check gives you time to take the rook next."),
    lesson("improver-endgame", "improver", "Endgame", "Finish with king and queen",
      "7k/8/6K1/6Q1/8/8/8/8 w - - 0 1", "g5d8",
      "White to move. Deliver checkmate with Qd8. Check every escape square first.",
      c("Your king already controls g7 and h7. Cover the back rank.", "Move the queen from g5 to d8."),
      "Qd8 is mate: the queen covers the eighth rank and your king covers the flight squares."),
    lesson("club-opening", "club", "Opening", "Develop with tempo",
      "rnbqkb1r/pp2pppp/3p1n2/2p5/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 2 5",
      "f1b5", "White to move. Develop your light-square bishop with check.",
      c("The d-pawn has moved, leaving a diagonal to the king.", "Move the bishop from f1 to b5."),
      "Bb5+ develops a piece while Black must answer the check. A tempo is useful when it serves development."),
    lesson("club-tactics", "club", "Tactics", "Recognise a back-rank net",
      "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", "a1a8",
      "White to move. Exploit the king's own pawns to deliver mate in one.",
      c("The pawns on f7, g7 and h7 block the king's escape.", "Move the rook from a1 to a8."),
      "Ra8 is mate. Before allowing a rook onto your back rank, look for a safe flight square."),
    lesson("club-endgame", "club", "Endgame", "Create a passed pawn",
      "7k/ppp5/8/PPP5/8/8/8/7K w - - 0 1", "b5b6",
      "White to move. Find the pawn break that forces a passed pawn, even if Black captures it.",
      c("Offer the middle pawn, then break through on the opposite side from Black's capture.", "Play b5 to b6. After ...axb6 play a6; after ...cxb6 play c6."),
      "b6 creates a breakthrough: ...axb6 a6 bxa6 c6, or ...cxb6 c6 bxc6 a6. A passed pawn matters more than the pawn you offer.")
  )
}

#' Choose a computer move with a small local search
#'
#' Used when a local Stockfish process is unavailable. Strength is search depth,
#' not an estimated human rating. The browser and this search share chess.js.
#' @param ctx A chess.js context.
#' @param fen A legal position.
#' @param strength One of casual, club, challenging.
#' @param style One of balanced, attacking, solid.
#' @return A legal UCI move, or NULL in a finished position.
#' @examples
#' \dontrun{practice_computer_move(new_chess_context(), CV_START_FEN)}
#' @noRd
practice_computer_move <- function(ctx, fen, strength = "casual", style = "balanced") {
  stopifnot(strength %in% c("casual", "club", "challenging"),
            style %in% c("balanced", "attacking", "solid"))
  ctx$assign("practiceFen", fen)
  ctx$assign("practiceDepth", match(strength, c("casual", "club", "challenging")))
  ctx$assign("practiceStyle", style)
  result <- ctx$eval("(function() {
    var g = new ChessCtor(practiceFen), values = {p:100,n:320,b:330,r:500,q:900,k:0};
    function score() {
      if (g.isCheckmate()) return -100000;
      if (g.isDraw()) return 0;
      var sum = 0, side = g.turn();
      g.board().forEach(function(row) {row.forEach(function(p) {
        if (p) sum += (p.color === side ? 1 : -1) * values[p.type];
      });});
      return sum;
    }
    function search(depth, alpha, beta) {
      if (!depth || g.isGameOver()) return score();
      var moves = g.moves({verbose:true});
      moves.sort(function(a,b) {return (values[b.captured] || 0) - (values[a.captured] || 0);});
      var best = -Infinity;
      for (var i=0;i<moves.length;i++) {
        g.move(moves[i]); var val = -search(depth-1,-beta,-alpha); g.undo();
        best = Math.max(best,val); alpha = Math.max(alpha,val);
        if (alpha >= beta) break;
      }
      return best;
    }
    var best = -Infinity, chosen = '', moves = g.moves({verbose:true});
    moves.forEach(function(m) {
      g.move(m); var val = -search(practiceDepth-1,-Infinity,Infinity); g.undo();
      var file = m.to.charCodeAt(0)-97, rank = Number(m.to[1])-1;
      val += 3 * (3.5-Math.abs(file-3.5) + 3.5-Math.abs(rank-3.5));
      if (practiceStyle === 'attacking') val += (m.captured ? 24 : 0) + (/[+#]/.test(m.san) ? 18 : 0);
      if (practiceStyle === 'solid') val += (m.flags.indexOf('k') >= 0 || m.flags.indexOf('q') >= 0 ? 35 : 0) + (m.piece === 'p' ? 8 : 0);
      if (val > best) {best = val; chosen = m.from+m.to+(m.promotion || '');}
    });
    return chosen;
  })()")
  if (nzchar(result)) result else NULL
}

#' Reflect a lesson into a second position for the other colour
#' @param item An entry from practice_lessons().
#' @return A lesson position and solutions for the opposite side.
#' @examples
#' practice_transfer(practice_lessons()[[1]])$solutions
#' @noRd
practice_transfer <- function(item) {
  fields <- strsplit(item$fen, " ", fixed = TRUE)[[1]]
  ranks <- rev(strsplit(fields[1], "/", fixed = TRUE)[[1]])
  fields[1] <- paste(chartr("prnbqkPRNBQK", "PRNBQKprnbqk", ranks), collapse = "/")
  fields[2] <- if (fields[2] == "w") "b" else "w"
  rights <- chartr("KQkq", "kqKQ", fields[3])
  fields[3] <- if (rights == "-") "-" else paste(strsplit("KQkq", "")[[1]][strsplit("KQkq", "")[[1]] %in% strsplit(rights, "")[[1]]], collapse = "")
  reflect_square <- function(x) paste0(substr(x, 1, 1), 9L - as.integer(substr(x, 2, 2)))
  if (fields[4] != "-") fields[4] <- reflect_square(fields[4])
  list(fen = paste(fields, collapse = " "), solutions = vapply(item$solutions, function(x) {
    paste0(reflect_square(substr(x, 1, 2)), reflect_square(substr(x, 3, 4)), if (nchar(x) > 4) substr(x, 5, 5) else "")
  }, character(1)))
}

#' Select a computer line by challenge and style
#' @param scores Scores in centipawns, best first or unordered.
#' @param sans Corresponding moves in SAN.
#' @param strength Challenge name.
#' @param style Playing style.
#' @return Index of the selected candidate, or integer(0) without scored lines.
#' @examples
#' practice_choose_candidate(c(50, 30, -50, -200), c("e4", "d4", "Nf3", "a3"), "casual", "balanced")
#' @noRd
practice_choose_candidate <- function(scores, sans, strength, style) {
  stopifnot(strength %in% c("casual", "club", "challenging"),
            style %in% c("balanced", "attacking", "solid"),
            length(scores) == length(sans))
  valid <- which(is.finite(scores))
  if (!length(valid)) return(integer())
  best <- max(scores[valid])
  loss <- best - scores
  tolerance <- c(casual = 450, club = 140, challenging = 35)[strength]
  target <- c(casual = 200, club = 50, challenging = 0)[strength]
  candidates <- valid[loss[valid] <= tolerance]
  # Weaker challenges deliberately accept a larger loss, rather than taking
  # MultiPV's top line and accidentally defeating Stockfish's skill setting.
  bonus <- if (style == "attacking") {
    30 * grepl("x", sans) + 35 * grepl("[+#]", sans)
  } else if (style == "solid") {
    40 * grepl("^O-O", sans) + 10 * !grepl("x", sans)
  } else rep(0, length(scores))
  candidates[which.max(-abs(loss[candidates] - target) + bonus[candidates])]
}
