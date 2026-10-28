library(testthat)

test_that("every lesson has a legal and playable solution", {
  ctx <- new_chess_context()
  lessons <- practice_lessons()
  expect_length(lessons, 9L)
  expect_length(unique(vapply(lessons, `[[`, character(1), "id")), 9L)
  for (lesson in lessons) {
    expect_equal(is_valid_fen(ctx, lesson$fen), TRUE, info = lesson$id)
    expect_equal(all(lesson$solutions %in% legal_moves(ctx, lesson$fen)), TRUE, info = lesson$id)
    transfer <- practice_transfer(lesson)
    expect_equal(all(transfer$solutions %in% legal_moves(ctx, transfer$fen)), TRUE, info = lesson$id)
  }
  mates <- Filter(function(x) x$id %in% c("club-tactics", "improver-endgame"), lessons)
  for (lesson in mates) {
    after <- fen_after_move(ctx, lesson$fen, lesson$solutions[1])
    ctx$assign("mateFen", after)
    expect_equal(ctx$eval("new ChessCtor(mateFen).isCheckmate()"), "true", info = lesson$id)
  }
})

test_that("fallback computer chooses legal moves at each strength and style", {
  ctx <- new_chess_context()
  fen <- "7k/8/8/8/8/8/6P1/6K1 b - - 0 1"
  for (strength in c("casual", "club", "challenging")) {
    for (style in c("balanced", "attacking", "solid")) {
      move <- practice_computer_move(ctx, fen, strength, style)
      expect_equal(move %in% legal_moves(ctx, fen), TRUE)
    }
  }
  expect_null(practice_computer_move(ctx, "3Q3k/8/6K1/8/8/8/8/8 b - - 1 1"))
  expect_error(practice_computer_move(ctx, CV_START_FEN, NA_character_))
  expect_error(practice_computer_move(ctx, CV_START_FEN, ""))
})

test_that("lesson module checks attempts and counts unique completions", {
  shiny::testServer(mod_practice_server, args = list(chess_ctx = new_chess_context()), {
    session$setInputs(level = "beginner", topic = "Opening")
    session$flushReact()
    session$setInputs(start_exercise = 1)
    session$setInputs(state = list(last_uci = "g1f3", last_before = CV_START_FEN, nonce = 1))
    session$flushReact()
    expect_equal(session$getReturned()()$solved, FALSE)
    expect_equal(session$getReturned()()$progress$attempts, 1L)
    session$setInputs(hint = 1)
    session$flushReact()
    expect_equal(session$getReturned()()$progress$hints, 1L)
    session$setInputs(state = list(last_uci = "e2e4", last_before = CV_START_FEN, nonce = 2))
    session$flushReact()
    expect_equal(session$getReturned()()$stage, "ready-transfer")
    session$setInputs(start_exercise = 2)
    transfer <- practice_transfer(practice_lessons()[[1]])
    session$setInputs(state = list(last_uci = "e7e5", last_before = transfer$fen, nonce = 3))
    session$flushReact()
    expect_equal(session$getReturned()()$solved, TRUE)
    expect_length(session$getReturned()()$progress$completed, 1L)
    session$setInputs(retry = 1)
    session$setInputs(start_exercise = 3)
    session$setInputs(state = list(last_uci = "d2d4", last_before = CV_START_FEN, nonce = 3))
    session$flushReact()
    expect_length(session$getReturned()()$progress$completed, 1L)
    session$setInputs(level = "club", topic = "Tactics")
    session$flushReact()
    expect_equal(session$getReturned()()$lesson$id, "club-tactics")
  })
})


test_that("challenge changes line selection and style stays within its budget", {
  scores <- c(50, 30, -50, -200, -500)
  sans <- c("e4", "d4", "Nf3", "a3", "h3")
  expect_equal(practice_choose_candidate(scores, sans, "casual", "balanced"), 4L)
  expect_equal(practice_choose_candidate(scores, sans, "club", "balanced"), 2L)
  expect_equal(practice_choose_candidate(scores, sans, "challenging", "balanced"), 1L)
  expect_equal(practice_choose_candidate(c(50, 45), c("e4", "Nxf7+"), "challenging", "attacking"), 2L)
  expect_equal(practice_choose_candidate(c(50, 45), c("e4", "O-O"), "challenging", "solid"), 2L)
  expect_equal(practice_choose_candidate(c(50, -500), c("e4", "Qxf7+"), "challenging", "attacking"), 1L)
  expect_length(practice_choose_candidate(c(NA_real_), "e4", "casual", "balanced"), 0L)
})
