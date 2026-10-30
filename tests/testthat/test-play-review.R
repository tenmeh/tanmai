library(testthat)

make_review_snapshot <- function(ctx, pgn = "1. e4 e5 2. Nf3 Nc6") {
  parsed <- game_from_pgn(ctx, pgn)
  list(pgn = pgn, fen = tail(parsed$game$fens, 1), history = parsed$game$sans,
    turn = strsplit(tail(parsed$game$fens, 1), " ")[[1]][2], game_over = FALSE)
}

make_review_settings <- function() {
  list(side = "b", engine = "Stockfish", strength = "club", style = "solid")
}

test_that("review snapshots retain complete moves, custom starts and side", {
  ctx <- new_chess_context()
  pgns <- c("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. O-O",
    '[SetUp "1"]\n[FEN "7k/P7/8/8/8/8/8/7K w - - 0 1"]\n\n1. a8=Q+')
  for (pgn in pgns) {
    state <- make_review_snapshot(ctx, pgn)
    request <- play_review_snapshot(ctx, state, make_review_settings())
    expect_identical(request$pgn, pgn)
    expect_identical(request$fen, state$fen)
    expect_identical(request$game$sans, state$history)
    expect_identical(request$orientation, "black")
    expect_identical(request$side, "b")
  }
  expect_match(play_review_snapshot(ctx, NULL, NULL)$error, "at least one move")
  state <- make_review_snapshot(ctx)
  state$fen <- CV_START_FEN
  expect_match(play_review_snapshot(ctx, state, make_review_settings())$error, "still updating")
  state$pgn <- "not a game"
  expect_match(play_review_snapshot(ctx, state, make_review_settings())$error, "could not be copied")
})

test_that("terminal positions are scored without engine retry loops", {
  ctx <- new_chess_context()
  expect_identical(review_terminal_score(ctx, CV_START_FEN), NA_real_)
  expect_equal(review_terminal_score(ctx, "3Q3k/8/6K1/8/8/8/8/8 b - - 1 1"), 100000)
  expect_equal(review_terminal_score(ctx, "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"), 0)
})

test_that("Play pauses for review and repeated handoffs have distinct identity", {
  ctx <- new_chess_context()
  shiny::testServer(mod_practice_server, args = list(chess_ctx = ctx, mode = "play"), {
    settings <- make_review_settings(); settings$side <- "w"
    game_settings(settings)
    state <- make_review_snapshot(ctx)
    # Black's turn would invoke the computer only when the player chose White.
    state$turn <- "b"
    session$setInputs(state = state)
    session$setInputs(review_game = 1)
    expect_equal(session$getReturned()()$paused, TRUE)
    first <- session$getReturned()()$review_request
    expect_identical(first$fen, state$fen)
    session$setInputs(review_game = 2)
    expect_equal(session$getReturned()()$review_request$nonce, first$nonce + 1L)
    session$setInputs(resume = 1)
    expect_equal(session$getReturned()()$paused, FALSE)
  })
})

test_that("Review accepts direct handoffs with full history and orientation", {
  ctx <- new_chess_context()
  request <- play_review_snapshot(ctx, make_review_snapshot(ctx), make_review_settings())
  incoming <- shiny::reactiveVal(request)
  shiny::testServer(mod_live_server, args = list(chess_ctx = ctx, incoming = incoming,
      engine_factory = function(...) NULL), {
    session$flushReact()
    msg <- session$getReturned()()
    expect_identical(msg$pgn, request$pgn)
    expect_identical(msg$fen, request$fen)
    expect_identical(msg$orientation, "black")
    expect_length(game()$sans, 4L)
    expect_match(output$review_status$html, "Engine unavailable")
    session$setInputs(goto = list(ply = 3L))
    expect_identical(session$getReturned()()$pgn, request$pgn)
    expect_equal(session$getReturned()()$ply, 2L)
    expect_identical(session$getReturned()()$fen, request$game$fens[3])
  })
})

test_that("app wiring routes a Play snapshot into Review exactly once", {
  shiny::testServer(app_server, {
    session$setInputs(`play-strength` = "casual", `play-style` = "balanced",
      `play-side` = "w", `play-new_game` = 1)
    state <- make_review_snapshot(new_chess_context())
    session$setInputs(`play-state` = state, `play-review_game` = 1)
    session$flushReact()
    expect_identical(play_review()$pgn, state$pgn)
    expect_identical(to_board()$pgn, state$pgn)
    expect_match(output$review_context$html, "Your computer game")
    first <- play_review()$nonce
    session$setInputs(`play-review_game` = 2)
    expect_equal(play_review()$nonce, first + 1L)
  })
})
