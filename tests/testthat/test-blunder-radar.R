# Blunder Radar. The engine-dependent tests are skipped when Stockfish or Maia
# are unavailable, so the suite still runs on a bare checkout; the pure scoring
# logic is always exercised.

test_that("mate scores fold onto the centipawn scale with the right sign", {
  expect_equal(score_to_cp(35, NA_integer_), 35)
  expect_gt(score_to_cp(NA_integer_, 3L), 9000) # mating
  expect_lt(score_to_cp(NA_integer_, -3L), -9000) # getting mated
  # A faster mate must score better than a slower one.
  expect_gt(score_to_cp(NA_integer_, 1L), score_to_cp(NA_integer_, 5L))
  expect_true(is.na(score_to_cp(NA_integer_, NA_integer_)))
})

test_that("policy parsing reads lc0 verbose move stats", {
  lines <- c(
    "info string e2e4  (322 ) N:       0 (+ 0) (P: 65.14%) (Q:  0.04)",
    "info string d2d4  (299 ) N:       0 (+ 0) (P: 22.96%) (Q:  0.04)",
    "info string node  (---) N:       1 (+ 0) (P:  0.00%) (Q:  0.04)",
    "bestmove e2e4"
  )
  pol <- parse_policy_lines(lines)

  expect_equal(nrow(pol), 2) # the summary "node" line is not a move
  expect_equal(pol$move[1], "e2e4")
  expect_equal(pol$prob[1], 0.6514)
  expect_true(all(diff(pol$prob) <= 0)) # ordered by probability
})

test_that("policy parsing survives output with no moves", {
  expect_equal(nrow(parse_policy_lines(c("bestmove a1a1"))), 0)
  expect_equal(nrow(parse_policy_lines(character(0))), 0)
})

test_that("a requested rating snaps to an available network", {
  # Every hundred from 1100 to 1900 is a real trained network, so each stop on
  # the slider maps to itself rather than to the nearest of a coarse few.
  for (r in MAIA_RATINGS) expect_equal(match_maia_rating(r), r)
  expect_equal(match_maia_rating(1437), 1400L)
  expect_equal(match_maia_rating(1489), 1500L)

  # Outside the range Maia was trained for, the nearest end is the honest
  # answer - there is no maia-1000 or maia-2000 to fall back to.
  expect_equal(match_maia_rating(400), 1100L)
  expect_equal(match_maia_rating(3000), 1900L)

  expect_equal(match_maia_rating(NA), 1500L)
})

test_that("the slider's grid and the estimator's grid are both real networks", {
  # The two deliberately differ - the estimator's accuracy was calibrated on
  # three networks - but neither may name a network that does not exist.
  expect_true(all(MAIA_ESTIMATOR_RATINGS %in% MAIA_RATINGS))
  expect_equal(MAIA_RATINGS, seq(1100L, 1900L, by = 100L))
  expect_length(MAIA_RATINGS, 9L)
})

test_that("chess.js reports legal moves and the position after one", {
  ctx <- new_chess_context()
  start <- "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

  moves <- legal_moves(ctx, start)
  expect_length(moves, 20) # 16 pawn moves + 4 knight moves
  expect_true("e2e4" %in% moves)

  after <- fen_after_move(ctx, start, "e2e4")
  expect_match(after, "^rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b")
  expect_true(is.na(fen_after_move(ctx, start, "e2e5"))) # illegal
})

test_that("a known trap scores far above a quiet position", {
  skip_if_not(human_model_available(1100), "Maia weights/lc0 not installed")
  skip_if(is.null(tryCatch(ensure_stockfish(), error = function(e) NULL)),
    "Stockfish not available"
  )

  maia <- maia_session_start(1100)
  skip_if(is.null(maia), "could not start Maia")
  on.exit(maia_session_stop(maia), add = TRUE)

  # Black to move; Nf6 is natural and allows mate on f7.
  scholars <- "r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3"
  quiet <- "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

  trap_res <- blunder_risk(scholars, maia, movetime_ms = 600)
  calm_res <- blunder_risk(quiet, maia, movetime_ms = 600)

  expect_false(is.na(trap_res$risk))
  # The whole premise: a human-plausible catastrophe must dominate a position
  # where nothing can go wrong. This fails if the metric is flat or inverted.
  expect_gt(trap_res$risk, 50)
  expect_lt(calm_res$risk, 25)
  expect_gt(trap_res$risk, calm_res$risk * 5)

  # And the losing move must be the one driving the score.
  expect_equal(trap_res$moves$move[1], "g8f6")
  expect_gt(trap_res$blunder_prob, 0)
})

test_that("the overlay draws the dangerous move, not just the likely ones", {
  # Modelled on the Scholar's-mate trap: the losing move (g8f6) is only the
  # fourth most likely, so selecting arrows by probability would hide it.
  moves <- data.frame(
    move = c("g7g6", "d8f6", "d8e7", "g8f6", "g8h6"),
    prob = c(0.466, 0.282, 0.134, 0.061, 0.030),
    loss = c(0, 56, 27, 1000, 40),
    contribution = c(0, 15.9, 3.6, 62.1, 1.2),
    stringsAsFactors = FALSE
  )
  shown <- radar_arrow_moves(moves, n = 3L)

  expect_equal(shown$move[1], "g8f6") # the trap leads
  expect_true("g7g6" %in% shown$move) # likeliest kept for context
  expect_true(any(shown$loss >= 100)) # so a danger arrow is drawn
  expect_false(any(duplicated(shown$move)))

  # When the likeliest move is also the riskiest it must not be drawn twice.
  one <- moves[moves$move == "g8f6", ]
  expect_equal(nrow(radar_arrow_moves(one)), 1)
  expect_equal(nrow(radar_arrow_moves(moves[0, ])), 0)
})

test_that("risk is capped so a forced mate cannot swamp the average", {
  skip_if_not(human_model_available(1100), "Maia weights/lc0 not installed")
  skip_if(is.null(tryCatch(ensure_stockfish(), error = function(e) NULL)),
    "Stockfish not available"
  )
  maia <- maia_session_start(1100)
  skip_if(is.null(maia), "could not start Maia")
  on.exit(maia_session_stop(maia), add = TRUE)

  scholars <- "r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3"
  res <- blunder_risk(scholars, maia, movetime_ms = 600, max_loss_cp = 1000)

  expect_lte(max(res$moves$loss), 1000)
  expect_lte(res$risk, 1000) # a weighted mean of capped values
})
