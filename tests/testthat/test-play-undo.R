library(testthat)

test_that("Undo requires a previous player decision", {
  for (n in 0:4) {
    state <- list(history = rep("move", n))
    expect_identical(play_undo_available(state, "w"), n >= 1L)
    expect_identical(play_undo_available(state, "b"), n >= 2L)
  }
  expect_identical(play_undo_available(NULL, "w"), FALSE)
  expect_identical(play_undo_available(list(history = "e4"), NA_character_), FALSE)
  expect_identical(play_undo_available(list(history = "e4"), character()), FALSE)
})

test_that("Undo cancels a pending search and waits for authoritative state", {
  shiny::testServer(mod_practice_server,
    args = list(chess_ctx = new_chess_context(), mode = "play"), {
      game_settings(list(side = "w", strength = "casual", style = "balanced"))
      undo_pending(-1L)
      session$setInputs(state = list(fen = "pending-position", turn = "b",
        history = "e4", revision = 4L))
      thinking(list(fen = "pending-position", revision = 4L, start = Sys.time()))
      undo_pending(NULL)
      session$setInputs(undo_turn = 1)
      expect_null(thinking())
      expect_equal(undo_pending(), 1L)
      session$setInputs(review_game = 1)
      expect_null(session$getReturned()()$review_request)
      expect_match(output$undo_control$html, "disabled")
      expect_identical(play_reply("pending-position", "e7e5", 4L), FALSE)
      session$setInputs(state = list(fen = CV_START_FEN, turn = "w",
        history = character(), revision = 5L,
        undo_ack = list(request = 1L, undone = TRUE)))
      expect_null(undo_pending())
      expect_match(session$getReturned()()$feedback, "choose again")
      expect_match(output$undo_control$html, "disabled")
      expect_identical(play_reply(CV_START_FEN, "e2e4", 4L), FALSE)
    })
})

test_that("Undo keeps review pause and existing snapshots intact", {
  shiny::testServer(mod_practice_server,
    args = list(chess_ctx = new_chess_context(), mode = "play"), {
      game_settings(list(side = "b", strength = "club", style = "solid"))
      paused(TRUE)
      review_request(list(pgn = "1. e4 e5 2. Nf3", nonce = 7L))
      session$setInputs(state = list(history = c("e4", "e5", "Nf3"),
        game_over = TRUE, revision = 8L))
      session$setInputs(undo_turn = 1)
      session$setInputs(state = list(history = "e4", game_over = FALSE,
        turn = "b", revision = 9L, undo_ack = list(request = 1L, undone = TRUE)))
      expect_equal(session$getReturned()()$paused, TRUE)
      expect_identical(session$getReturned()()$review_request$pgn, "1. e4 e5 2. Nf3")
      expect_match(session$getReturned()()$feedback, "stays paused")
      expect_match(output$undo_control$html, "disabled")
    })
})
