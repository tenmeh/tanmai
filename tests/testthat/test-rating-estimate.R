# Opponent rating estimation. The pure scoring logic runs everywhere; the
# parts that need three live Maia networks skip on a bare checkout.

test_that("the posterior is a softmax of the log-likelihoods", {
  ll <- c("1100" = -10, "1500" = -10, "1900" = -10)
  post <- rating_posterior(ll)
  expect_equal(unname(post), rep(1 / 3, 3)) # equal evidence -> prior
  expect_equal(sum(post), 1)

  ll2 <- c("1100" = -5, "1500" = -10, "1900" = -15)
  post2 <- rating_posterior(ll2)
  expect_equal(names(post2)[which.max(post2)], "1100")
  expect_true(all(diff(post2) < 0)) # ordered by likelihood
  expect_equal(sum(post2), 1)
})

test_that("a long game's log-likelihood does not underflow to nothing", {
  # exp(-4000) is 0 in double precision. Subtracting the max first is what
  # keeps a 200-move game from producing NaN across the board.
  ll <- c("1100" = -4000, "1500" = -4002, "1900" = -4010)
  post <- rating_posterior(ll)

  expect_false(anyNA(post))
  expect_equal(sum(post), 1)
  expect_equal(names(post)[which.max(post)], "1100")
})

test_that("an unknown rating contributes nothing rather than poisoning the rest", {
  expect_true(all(is.na(rating_posterior(c(a = NA_real_, b = NA_real_)))))

  post <- rating_posterior(c("1100" = -3, "1500" = NA_real_, "1900" = -9))
  expect_equal(sum(post), 1)
  expect_equal(unname(post["1500"]), 0)
  expect_equal(names(post)[which.max(post)], "1100")
})

test_that("the side to move is read from the FEN", {
  expect_equal(fen_turn("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"), "w")
  expect_equal(fen_turn("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1"), "b")
  expect_equal(fen_turn("  8/8/8/8/8/8/8/8   b - - 0 1  "), "b")
  expect_equal(fen_turn("garbage"), "w") # degrade, do not error
})

test_that("confidence needs moves, evidence and a concentrated posterior", {
  strong <- list(rating = 1100L, n_moves = 12, evidence = 11,
    posterior = c("1100" = 0.9, "1500" = 0.07, "1900" = 0.03))
  expect_true(rating_estimate_is_confident(strong))

  # One sharp move can clear the evidence bar by itself. An earlier version
  # had no move minimum and duly announced a confident rating from a single
  # move of a game; that is the regression this pins.
  one_move <- list(rating = 1100L, n_moves = 1, evidence = 9,
    posterior = c("1100" = 0.85, "1500" = 0.1, "1900" = 0.05))
  expect_false(rating_estimate_is_confident(one_move))

  # Plenty of moves, but every network would have played them: no evidence.
  no_signal <- list(rating = 1100L, n_moves = 30, evidence = 0.4,
    posterior = c("1100" = 0.34, "1500" = 0.33, "1900" = 0.33))
  expect_false(rating_estimate_is_confident(no_signal))

  # Evidence, but split between two hypotheses - not an answer.
  split <- list(rating = 1100L, n_moves = 12, evidence = 12,
    posterior = c("1100" = 0.5, "1500" = 0.45, "1900" = 0.05))
  expect_false(rating_estimate_is_confident(split))

  expect_false(rating_estimate_is_confident(
    list(rating = NA_integer_, n_moves = 0, evidence = 0, posterior = c(a = NA_real_))
  ))
})

test_that("estimating from no moves yields nothing, not a guess", {
  skip_if_not(human_model_available(1100), "Maia weights/lc0 not installed")
  pool <- maia_pool_start()
  skip_if(is.null(pool), "could not start a Maia pool")
  on.exit(maia_pool_stop(pool), add = TRUE)

  est <- estimate_rating(pool, character(0), character(0))
  expect_equal(est$n_moves, 0L)
  expect_true(is.na(est$rating))
  expect_false(rating_estimate_is_confident(est))

  # Asking for a side that never moved is also "no data", not an error.
  start <- "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  est_b <- estimate_rating(pool, start, "e2e4", side = "b")
  expect_equal(est_b$n_moves, 0L)
  expect_true(is.na(est_b$rating))
})

test_that("the networks disagree enough for a played move to carry signal", {
  skip_if_not(human_model_available(1100), "Maia weights/lc0 not installed")
  pool <- maia_pool_start()
  skip_if(is.null(pool), "could not start a Maia pool")
  on.exit(maia_pool_stop(pool), add = TRUE)

  # Black to move against the Scholar's-mate setup; Nf6 is the losing move.
  scholars <- "r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3"
  ll <- move_log_likelihood(pool, scholars, "g8f6")

  expect_length(ll, length(MAIA_ESTIMATOR_RATINGS))
  expect_false(anyNA(ll))
  expect_true(all(ll < 0)) # log of a probability
  # If every network assigned this the same probability, no game could ever
  # discriminate between them and the whole feature would be pointless.
  expect_gt(max(ll) - min(ll), 0.2)
})

test_that("a move no network expects is floored, not treated as impossible", {
  skip_if_not(human_model_available(1100), "Maia weights/lc0 not installed")
  pool <- maia_pool_start()
  skip_if(is.null(pool), "could not start a Maia pool")
  on.exit(maia_pool_stop(pool), add = TRUE)

  start <- "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  ll <- move_log_likelihood(pool, start, "a2a3") # legal, rarely played

  expect_false(anyNA(ll))
  expect_true(all(is.finite(ll))) # -Inf here would veto a rating outright
  expect_true(all(ll >= log(MAIA_MIN_POLICY) - 1e-9))
})

test_that("games played by a known network are attributed to it", {
  skip_if_not(human_model_available(1100), "Maia weights/lc0 not installed")
  skip_on_ci() # sampling whole games is too slow for CI
  pool <- maia_pool_start()
  skip_if(is.null(pool), "could not start a Maia pool")
  on.exit(maia_pool_stop(pool), add = TRUE)
  ctx <- new_chess_context()

  # Sample a game, one side driven by `black_r` and the other by `white_r`, so
  # this is never a single distribution recognising itself.
  play <- function(black_r, white_r, plies = 40) {
    fen <- "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    fens <- character(0)
    ucis <- character(0)
    for (i in seq_len(plies)) {
      r <- if (fen_turn(fen) == "b") black_r else white_r
      pol <- human_move_probabilities(pool[[as.character(r)]], fen)
      if (!nrow(pol) || sum(pol$prob) <= 0) break # mate/stalemate
      mv <- sample(pol$move, 1, prob = pol$prob)
      fens <- c(fens, fen)
      ucis <- c(ucis, mv)
      nxt <- fen_after_move(ctx, fen, mv)
      if (is.na(nxt)) break
      fen <- nxt
    }
    list(fens = fens, ucis = ucis)
  }

  # Pooled over four games rather than judged on one, and with the opposing
  # side alternating so no single opponent shapes the positions.
  #
  # A single game identifies the right network only about 75% of the time -
  # the networks are 400 Elo apart but frequently agree - so a one-game
  # assertion is a weighted coin flip that fails on an unlucky seed. Measured
  # over 12 seeds at this configuration, maia-1100 and maia-1900 were both
  # recovered 12/12. maia-1500 manages only 11/12 and does not improve with
  # more games: it sits between the other two, so its ambiguity is a property
  # of the networks rather than a shortage of data. Hence an extreme is used
  # here - this asserts the estimator works, not that it is infallible.
  set.seed(8113)
  truth <- 1100L
  others <- setdiff(MAIA_ESTIMATOR_RATINGS, truth)
  total <- stats::setNames(rep(0, length(pool)), names(pool))
  moves <- 0L
  for (g in 1:4) {
    s <- play(truth, others[1 + (g %% length(others))])
    est <- estimate_rating(pool, s$fens, s$ucis, side = "b")
    if (!anyNA(est$loglik)) {
      total <- total + est$loglik
      moves <- moves + est$n_moves
    }
  }

  expect_gt(moves, 20)
  expect_equal(names(total)[which.max(total)], as.character(truth))
  expect_gt(total[["1100"]], total[["1900"]])

  post <- rating_posterior(total)
  expect_equal(sum(post), 1)
  expect_equal(names(post)[which.max(post)], as.character(truth))
})
