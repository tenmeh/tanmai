#' Standalone tactical puzzle workspace
#' @param id Module identifier.
#' @return Shiny UI tags.
#' @noRd
mod_puzzles_ui <- function(id) {
  ns <- NS(id)
  div(class = "cv-practice cv-practice-puzzles",
    div(class = "cv-practice-board-area",
      div(class = "cv-practice-topline",
        span(class = "cv-eyebrow", "FIND THE COMBINATION"),
        textOutput(ns("turn"), inline = TRUE)),
      div(class = "cv-practice-board-frame", div(id = ns("board"), class = "cv-board")),
      div(class = "cv-practice-board-footer",
        span("Tap or drag to move. Promotions use a queen."),
        actionButton(ns("flip"), "Flip board", class = "btn-sm"))),
    tags$aside(class = "cv-task-panel",
      span(class = "cv-eyebrow", "PUZZLES"),
      p(class = "small text-muted",
        "8 composed positions: 4 patterns, each from both colours. A starter set, without ratings."),
      div(class = "cv-puzzle-filters",
        selectInput(ns("topic"), "Theme",
          c("All", "Fork", "Back rank", "Pawn breakthrough", "Promotion"), selectize = FALSE),
        selectInput(ns("difficulty"), "Difficulty",
          c("All", "Starter", "Challenge"), selectize = FALSE)),
      uiOutput(ns("challenge")),
      div(class = "cv-task-feedback", role = "status", textOutput(ns("feedback"))),
      div(class = "cv-actions",
        actionButton(ns("hint"), "Hint"),
        actionButton(ns("retry"), "Retry"),
        actionButton(ns("next_puzzle"), "Next puzzle", class = "btn-primary")),
      uiOutput(ns("explanation")),
      textOutput(ns("progress")),
      p(class = "small text-muted",
        "Replies follow a selected training line. Completion records practice in this session, not mastery. Learn introduces ideas; Puzzles asks you to find the moves.")))
}

#' Solve a small composed puzzle collection on the shared board
#' @param id Module identifier.
#' @param chess_ctx Session chess.js context.
#' @return A reactive puzzle state for integration tests.
#' @noRd
mod_puzzles_server <- function(id, chess_ctx) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    catalog <- puzzle_catalog()
    matches <- reactive(puzzle_filter(catalog, input$topic %||% "All", input$difficulty %||% "All"))
    current <- reactiveVal(catalog[[1]])
    ply <- reactiveVal(1L)
    position <- reactiveVal(catalog[[1]]$fen)
    complete <- reactiveVal(FALSE)
    completed <- reactiveVal(character())
    attempts <- reactiveVal(0L)
    hints <- reactiveVal(0L)
    feedback <- reactiveVal(catalog[[1]]$goal)
    ready <- reactiveVal(FALSE)
    last_event <- reactiveVal(NULL)

    # Every reset carries the play policy: no engine hints and only the solver's side.
    side <- function() strsplit(current()$fen, " ", fixed = TRUE)[[1]][2]
    set_board <- function(locked = FALSE) {
      session$sendCustomMessage("tanmai-board-set", list(container = ns("board"),
        fen = position(), orientation = if (side() == "b") "black" else "white",
        side = side(), locked = locked, practice = TRUE))
    }
    load <- function(item) {
      current(item); ply(1L); position(item$fen); complete(FALSE)
      hints(0L); last_event(NULL); feedback(item$goal)
      if (ready()) set_board()
    }
    session$onFlushed(function() {
      session$sendCustomMessage("tanmai-board-create", list(container = ns("board"),
        stateInput = ns("state"), fen = isolate(position()), orientation = "white",
        pieceTheme = piece_theme_base("cburnett"), side = "w", locked = FALSE, practice = TRUE))
      ready(TRUE)
    }, once = TRUE)
    observeEvent(list(input$topic, input$difficulty), {
      items <- matches()
      if (length(items)) load(items[[1]]) else {
        complete(TRUE)
        feedback("No puzzles match both filters. Choose All for one filter.")
        if (ready()) set_board(locked = TRUE)
      }
    })
    observeEvent(input$retry, {
      req(length(matches()))
      load(current())
    })
    observeEvent(input$next_puzzle, {
      items <- matches(); req(length(items))
      ids <- vapply(items, `[[`, character(1), "id")
      index <- match(current()$id, ids)
      if (is.na(index)) index <- 0L
      load(items[[index %% length(items) + 1L]])
    })
    observeEvent(input$flip, {
      session$sendCustomMessage("tanmai-board-flip", list(container = ns("board")))
    })
    observeEvent(input$hint, {
      req(!complete(), length(matches()))
      count <- hints() + 1L; hints(count)
      step <- (ply() + 1L) %/% 2L
      if (count %% 2L == 1L) {
        feedback(current()$hints[[step]])
      } else {
        move <- current()$line[[ply()]]
        feedback("The arrow shows the next move. Try it on the board.")
        session$sendCustomMessage("tanmai-board-arrows", list(container = ns("board"),
          arrows = list(list(from = substr(move, 1, 2), to = substr(move, 3, 4),
            color = "#46b8df", width = 8))))
      }
    })
    observeEvent(input$state, {
      st <- input$state
      req(!complete(), length(matches()), !is.null(st$last_uci))
      req(identical(st$last_before, position()))
      event <- paste(st$last_before, st$last_uci, st$nonce)
      req(!identical(event, last_event())); last_event(event)
      result <- tryCatch(puzzle_advance(chess_ctx, current(), ply(), st$last_uci),
        error = function(e) {
          incident <- paste0(format(Sys.time(), "%Y%m%dT%H%M%S"), "-", sample.int(999999L, 1L))
          message("ERROR code=ERR-PUZZLE-001 incident=", incident, " ", conditionMessage(e))
          feedback(paste("This puzzle could not continue. Select Retry. Reference:", incident))
          NULL
        })
      if (is.null(result)) {
        session$sendCustomMessage("tanmai-board-policy", list(container = ns("board"),
          side = side(), locked = TRUE, practice = TRUE))
        return()
      }
      attempts(attempts() + 1L)
      if (!result$accepted) {
        feedback(paste("That move does not complete this step.", current()$hints[[(ply() + 1L) %/% 2L]],
          "The position is restored; try again."))
        set_board()
        return()
      }
      reason <- current()$reasons[[(ply() + 1L) %/% 2L]]
      position(result$fen); ply(result$ply); hints(0L)
      if (!is.null(result$reply)) {
        session$sendCustomMessage("tanmai-board-move",
          list(container = ns("board"), uci = result$reply))
      }
      complete(result$complete)
      if (result$complete) {
        completed(union(completed(), current()$id))
        feedback(paste("Puzzle solved.", reason))
        session$sendCustomMessage("tanmai-board-policy", list(container = ns("board"),
          side = side(), locked = TRUE, practice = TRUE))
      } else feedback(paste(reason, "The opponent has replied. Find your next move."))
    })
    output$challenge <- renderUI({
      if (!length(matches())) return(p("No matching positions."))
      item <- current()
      tagList(span(class = "cv-lesson-number", paste(item$difficulty, "/", item$topic)),
        h2(item$title), p(item$goal),
        p(class = "small text-muted", paste("Your move",
          min((ply() + 1L) %/% 2L, ceiling(length(item$line) / 2L)), "of",
          ceiling(length(item$line) / 2L))))
    })
    output$turn <- renderText({
      if (!length(matches())) "Choose a filter" else if (complete()) "Puzzle solved" else
        if (side() == "w") "White to move" else "Black to move"
    })
    output$feedback <- renderText(feedback())
    output$explanation <- renderUI({
      if (complete() && length(matches())) div(class = "cv-lesson-explanation",
        h3("Why it works"), p(current()$why))
    })
    output$progress <- renderText(sprintf("%d / 8 positions solved this session | %d attempts",
      length(completed()), attempts()))
    reactive(list(puzzle = current(), ply = ply(), fen = position(), complete = complete(),
      completed = completed(), attempts = attempts()))
  })
}
