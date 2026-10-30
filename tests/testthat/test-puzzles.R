library(testthat)

make_puzzle <- function(id = "fork") {
  Filter(function(item) item$id == id, puzzle_catalog())[[1]]
}

test_that("all eight composed puzzle lines are legal and goals hold", {
  ctx <- new_chess_context()
  items <- puzzle_catalog()
  expect_length(items, 8L)
  expect_length(unique(vapply(items, `[[`, character(1), "id")), 8L)
  for (item in items) {
    expect_true(is_valid_fen(ctx, item$fen), info = item$id)
    fen <- item$fen
    for (move in item$line) {
      expect_true(move %in% legal_moves(ctx, fen), info = paste(item$id, move))
      fen <- fen_after_move(ctx, fen, move)
    }
    ctx$assign("puzzleFinal", fen)
    if (item$topic == "Back rank") {
      expect_equal(ctx$eval("new ChessCtor(puzzleFinal).isCheckmate()"), "true", info = item$id)
    }
    if (item$topic == "Promotion") {
      expect_true(grepl("[Qq]", fen_placement(fen)))
      expect_false(grepl("[Rr]", fen_placement(fen)))
    }
  }
})

test_that("filters combine theme and difficulty and allow zero matches", {
  items <- puzzle_catalog()
  expect_length(puzzle_filter(items, "Fork"), 2L)
  expect_length(puzzle_filter(items, difficulty = "Challenge"), 4L)
  expect_length(puzzle_filter(items, "Fork", "Challenge"), 0L)
  expect_length(puzzle_filter(list()), 0L)
  expect_error(puzzle_filter("wrong"), "must be a list")
  expect_error(puzzle_filter(items, NA_character_), "non-missing")
  expect_error(puzzle_filter(items, difficulty = NA_character_), "non-missing")
})

test_that("wrong moves preserve a step and correct turns include the reply", {
  ctx <- new_chess_context()
  item <- make_puzzle()
  wrong <- puzzle_advance(ctx, item, 1L, "d5b4")
  expect_false(wrong$accepted)
  expect_identical(wrong$fen, item$fen)
  right <- puzzle_advance(ctx, item, 1L, "d5c7")
  expect_true(right$accepted)
  expect_identical(right$reply, "e8d7")
  expect_identical(right$ply, 3L)
  expect_false(right$complete)
  done <- puzzle_advance(ctx, item, 3L, "c7a8")
  expect_true(done$complete)
  expect_null(done$reply)
  expect_identical(done$fen, fen_after_move(ctx, right$fen, "c7a8"))
})

test_that("turn boundary rejects malformed moves and invalid stages", {
  ctx <- new_chess_context()
  item <- make_puzzle()
  expect_error(puzzle_advance(ctx, item, 2L, "d5c7"), "solver turn")
  expect_error(puzzle_advance(ctx, item, NA_real_, "d5c7"), "solver turn")
  expect_error(puzzle_advance(ctx, item, 1L, NA_character_), "UCI")
  expect_error(puzzle_advance(ctx, item, 1L, ""), "UCI")
  expect_error(puzzle_advance(ctx, list(), 1L, "d5c7"), "non-empty")
})

test_that("puzzle module advances a combination once and retry clears the line", {
  shiny::testServer(mod_puzzles_server, args = list(chess_ctx = new_chess_context()), {
    session$setInputs(topic = "Fork", difficulty = "All")
    session$flushReact()
    start <- session$getReturned()()$fen
    session$setInputs(state = list(last_before = start, last_uci = "d5b4", nonce = 1))
    session$flushReact()
    expect_identical(session$getReturned()()$ply, 1L)
    expect_match(output$feedback, "does not complete")
    session$setInputs(hint = 1)
    session$flushReact()
    expect_match(output$feedback, "knight check")
    session$setInputs(state = list(last_before = start, last_uci = "d5c7", nonce = 2))
    session$flushReact()
    state <- session$getReturned()()
    expect_identical(state$ply, 3L)
    expect_false(state$complete)
    session$setInputs(state = list(last_before = state$fen, last_uci = "c7a8", nonce = 3))
    session$flushReact()
    expect_true(session$getReturned()()$complete)
    expect_length(session$getReturned()()$completed, 1L)
    session$setInputs(retry = 1)
    session$flushReact()
    expect_identical(session$getReturned()()$fen, start)
    expect_false(session$getReturned()()$complete)
    expect_length(session$getReturned()()$completed, 1L)
    session$setInputs(next_puzzle = 1)
    session$flushReact()
    expect_identical(session$getReturned()()$puzzle$id, "fork-black")
  })
})

test_that("empty filter combinations cannot score a stale browser event", {
  shiny::testServer(mod_puzzles_server, args = list(chess_ctx = new_chess_context()), {
    session$setInputs(topic = "Fork", difficulty = "Challenge")
    session$flushReact()
    expect_match(output$feedback, "No puzzles match")
    session$setInputs(state = list(last_before = make_puzzle()$fen, last_uci = "d5c7", nonce = 1))
    session$flushReact()
    expect_identical(session$getReturned()()$attempts, 0L)
    session$setInputs(topic = "Promotion", difficulty = "Starter")
    session$flushReact()
    expect_identical(session$getReturned()()$puzzle$id, "promotion")
  })
})
