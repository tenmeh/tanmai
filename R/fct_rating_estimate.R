# Opponent rating estimation: infer how strong a player is from the moves they
# actually chose, rather than asking the user to guess.
#
# The Blunder Radar needs to know which Maia network models the opponent. Until
# now that came from a slider, which asks the user for something they usually
# do not know and cannot easily find out. But the moves are evidence: each Maia
# network is a probability distribution over moves for a rating, so a played
# move is more or less likely depending on which network generated it.
#
# So treat it as inference. For a game where the opponent played moves
# m_1..m_n from positions p_1..p_n:
#
#   log L(r) = sum_i log P_maia_r(m_i | p_i)
#
# and with a uniform prior over the available networks, the posterior is just
# the softmax of those log-likelihoods. The most likely rating is the one whose
# network was least surprised by what actually happened.
#
# Two things this must not do. It must not collapse to a single hypothesis on
# one unusual move - hence the probability floor below. And it must not present
# a guess from three forced recaptures as knowledge - hence `evidence`, which
# measures how much the observed moves actually discriminated between networks
# rather than how many there were.

# A move the network considers impossible would contribute log(0) = -Inf and
# veto that rating outright, however well it explained everything else. Maia's
# policy head assigns some probability to every legal move, but it is reported
# to two decimal places and rounds to zero for genuine outsiders, so the floor
# is about the reporting precision rather than the model.
MAIA_MIN_POLICY <- 1e-4

#' Start one Maia session per rating
#'
#' Estimating a rating means scoring the same move under every network, so all
#' of them have to be live at once. Three lc0 processes cost about 23 MB
#' resident in total, which is affordable next to the app itself.
#'
#' @param ratings Ratings to open sessions for.
#' @return A named list of sessions (names are the ratings), or `NULL` if any
#'   of them could not be started - a partial pool would silently bias the
#'   estimate towards whichever networks happened to load.
maia_pool_start <- function(ratings = MAIA_ESTIMATOR_RATINGS) {
  pool <- lapply(ratings, maia_session_start)
  names(pool) <- as.character(ratings)
  if (any(vapply(pool, is.null, logical(1)))) {
    lapply(pool, maia_session_stop)
    return(NULL)
  }
  pool
}

#' Stop a pool of Maia sessions
#'
#' @param pool A pool from [maia_pool_start()].
#' @return Invisibly `NULL`.
maia_pool_stop <- function(pool) {
  if (!is.null(pool)) lapply(pool, maia_session_stop)
  invisible(NULL)
}

#' Log-probability of one played move under each rating's network
#'
#' @param pool A pool from [maia_pool_start()].
#' @param fen The position the move was played from.
#' @param uci The move that was actually played.
#' @param floor_prob Lower bound applied before taking logs.
#' @return A named numeric vector of log-probabilities, one per rating.
move_log_likelihood <- function(pool, fen, uci, floor_prob = MAIA_MIN_POLICY) {
  vapply(pool, function(sess) {
    pol <- human_move_probabilities(sess, fen)
    if (!nrow(pol)) {
      return(NA_real_)
    }
    p <- pol$prob[match(uci, pol$move)]
    if (is.na(p)) p <- 0
    log(max(p, floor_prob))
  }, numeric(1))
}

#' Posterior over ratings from accumulated log-likelihoods
#'
#' A uniform prior over the available networks, so the posterior is the softmax
#' of the log-likelihoods. Computed by subtracting the maximum first, because
#' the log-likelihood of a long game is a large negative number and
#' `exp()` of it underflows to zero.
#'
#' @param loglik A named numeric vector of total log-likelihoods per rating.
#' @return A named numeric vector summing to 1, or all `NA` if nothing is known.
rating_posterior <- function(loglik) {
  ok <- !is.na(loglik)
  if (!any(ok)) {
    return(stats::setNames(rep(NA_real_, length(loglik)), names(loglik)))
  }
  w <- rep(0, length(loglik))
  names(w) <- names(loglik)
  w[ok] <- exp(loglik[ok] - max(loglik[ok]))
  w / sum(w)
}

#' Which side is to move in a FEN
#'
#' @param fen A FEN string.
#' @return "w" or "b".
fen_turn <- function(fen) {
  tok <- strsplit(trimws(fen), "\\s+")[[1]]
  if (length(tok) >= 2 && tok[2] %in% c("w", "b")) tok[2] else "w"
}

#' Estimate an opponent's rating from the moves they played
#'
#' Scores every move the given side played under each Maia network and returns
#' the posterior over ratings.
#'
#' `evidence` is the part worth reading before the estimate. It is the summed
#' spread of per-move log-probabilities across networks, in nats: how much the
#' observed moves actually distinguished one network from another. A game of
#' forced recaptures and obvious developing moves can run twenty plies and
#' carry almost none, because every network would have played the same thing.
#' Move count alone does not tell you that.
#'
#' @param pool A pool from [maia_pool_start()].
#' @param fens Positions before each move, as recorded by the game tracker.
#' @param ucis Moves played, aligned with `fens`.
#' @param side Which side to model, "w" or "b"; `NULL` scores every move.
#' @return A list with `posterior` (named, sums to 1), `rating` (the MAP
#'   estimate), `n_moves` scored, `evidence` in nats, and `loglik` per rating.
estimate_rating <- function(pool, fens, ucis, side = NULL) {
  empty <- list(
    posterior = stats::setNames(rep(NA_real_, length(pool)), names(pool)),
    rating = NA_integer_, n_moves = 0L, evidence = 0,
    loglik = stats::setNames(rep(NA_real_, length(pool)), names(pool))
  )
  if (is.null(pool) || !length(ucis)) {
    return(empty)
  }

  n <- min(length(ucis), length(fens))
  keep <- if (is.null(side)) {
    seq_len(n)
  } else {
    which(vapply(fens[seq_len(n)], fen_turn, character(1)) == side)
  }
  if (!length(keep)) {
    return(empty)
  }

  total <- stats::setNames(rep(0, length(pool)), names(pool))
  evidence <- 0
  for (i in keep) {
    ll <- move_log_likelihood(pool, fens[i], ucis[i])
    if (anyNA(ll)) next
    total <- total + ll
    evidence <- evidence + (max(ll) - min(ll))
  }

  post <- rating_posterior(total)
  list(
    posterior = post,
    rating = if (all(is.na(post))) NA_integer_ else as.integer(names(post)[which.max(post)]),
    n_moves = length(keep),
    evidence = evidence,
    loglik = total
  )
}

#' Is a rating estimate strong enough to act on?
#'
#' Raw accuracy of the MAP estimate is only around 72-75% across the three
#' networks - better than the 33% of guessing, but not something to state as
#' fact. It also barely improves with more moves, because the limit is how
#' similar Maia's networks are, not how much data there is. What does work is
#' declining to answer: requiring enough moves, enough discriminating evidence
#' and a concentrated posterior trades coverage for precision.
#'
#' Calibrated on 103 estimates from games sampled from a known network (the
#' opposing side driven by a different one, so this is not a distribution
#' recognising itself):
#'
#' \preformatted{
#'   moves  evidence  posterior | fires  correct when it fires
#'       6         4       0.50 |   59%                    77%
#'       6         6       0.70 |   35%                    94%
#'       6         8       0.70 |   24%                    96%
#' }
#'
#' The defaults take the middle row: silent about two thirds of the time, and
#' right about 94% of the time it does speak. Percentages come from a corpus of
#' 103, so treat them as approximate.
#'
#' The move minimum is not redundant with the evidence one. A single sharp move
#' can clear 2 nats on its own, which is how an earlier version of this managed
#' to declare a confident rating from one move of a game.
#'
#' @param est An estimate from [estimate_rating()].
#' @param min_moves Minimum opponent moves observed.
#' @param min_evidence Minimum discriminating evidence, in nats.
#' @param min_posterior Minimum posterior mass on the leading rating.
#' @return `TRUE` when the estimate is worth showing as an answer.
rating_estimate_is_confident <- function(est, min_moves = 6, min_evidence = 6,
                                         min_posterior = 0.7) {
  !is.na(est$rating) &&
    est$n_moves >= min_moves &&
    est$evidence >= min_evidence &&
    max(est$posterior, na.rm = TRUE) >= min_posterior
}
