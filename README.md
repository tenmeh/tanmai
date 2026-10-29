# Tanmai Chess

Screenshot a chess board, get the best move - and, more unusually, get told
where a player of a given strength is about to go wrong.

Named for Tanmay and [Maia](https://github.com/CSSLab/maia-chess), the
human-move network most of the interesting parts are built on. The R package
inside is called `tanmai`.

<!-- badges: start -->
[![R-CMD-check](https://github.com/tenmeh/tanmai/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/tenmeh/tanmai/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

A [golem](https://thinkr-open.github.io/golem/)-structured R Shiny app.

Three ways in, one analysis behind them:

```
screenshot -> 64 squares -> recognize pieces --+
FEN --------------------------------------->  +--> position --> Stockfish --> best move
                                                                          +-> blunder radar
PGN ----------------------------------------------> whole game -----------+-> eval graph,
                                                                              turning points
```

A screenshot needs recognising; a FEN skips straight past it. A PGN produces a
whole game, which is the same object the live tracker builds - so the graph, the
turning points and the radar review work on an imported game without knowing it
was imported.

## The Blunder Radar

An engine tells you what is *best*. This tells you what is likely to go
*wrong*, which is a different and often more useful question.

For an opponent of a chosen strength, every legal move is scored by

```
risk = SUM over moves of  P(a human plays it) x centipawns it loses
```

combining Maia's human-move probabilities with Stockfish's evaluations. A move
that hangs a queen but no human would play carries no risk; a natural move that
quietly drops a pawn carries a lot. That distinction is invisible to an engine
alone.

Measured against known traps, with a quiet position as the control:

| position | risk (1100) | risk (1900) |
| --- | ---: | ---: |
| Legal's mate | 6724 cp | 9192 cp |
| Scholar's mate | 1673 cp | 998 cp |
| Blackburne | 90 cp | - |
| **starting position** | **3.0 cp** | **3.6 cp** |

Roughly 2000x separation between a trap and a position where nothing can go
wrong. The control is what makes the number meaningful - a metric that fired
everywhere would say nothing.

A result worth noting: Legal's mate scores *higher* at 1900 than at 1100. The
stronger player is more confident about grabbing the queen, so the trap works
better on them.

On the board, the engine's choice is drawn in blue and the moves a human is
likely to get wrong in orange and red. Arrows are chosen by **risk
contribution**, not raw probability - in a trap the dangerous move is by
construction not the most likely one. After `3.Qh5` the losing `Nf6` is only
the fourth most probable reply, and picking by probability would never draw it.

## Following a live game

Share the window you are playing in and mark the board once, or paste a fresh
screenshot after each move. The app keeps the running game: move list,
evaluation per move, a graph across the game, and the moves where it turned.

The rule that makes this work is that **a position joins the game only when
exactly one sequence of legal moves explains how it got there.** That single
gate replaces a pile of ad-hoc filters: it discards misread squares, ignores
frames caught mid-animation, recovers a ply that was never seen on screen, and
gets castling, en passant and promotion right because chess.js generates the
moves rather than a square-by-square diff guessing at them. Readings that
cannot be explained are counted and shown, not quietly appended - a tracker
that invents moves is worse than one that admits it lost the thread.

Which way round the board is, and whose turn it is, are settled the same way:
both readings go through the gate, and the one that continues the game legally
was the right one.

Capture is the browser's own `getDisplayMedia`, so there is a real permission
prompt and a real choice of screen, window or tab. Frames are compared in the
browser and only a settled, changed picture is sent - about one recognition per
move rather than one per tick. A web page cannot read the screen unprompted or
watch the clipboard while another window has focus; neither is pretended at,
and pasting after each move is a first-class alternative rather than a
fallback.

## Estimating the opponent's rating

Asking which strength to model is asking something most people cannot answer
about an opponent. The moves are already evidence: each Maia network is a
distribution over moves for a rating, so the network least surprised by what
was actually played is the most likely one.

```
log L(rating) = SUM over their moves of  log P_maia_rating(move | position)
```

with a uniform prior, so the posterior is the softmax of those.

**It is right about 75% of the time on its own** - better than the 33% of
guessing between three networks, but not a fact, and it barely improves with
more moves because the limit is how alike the networks are rather than how much
data there is. So it declines to answer: requiring enough moves, enough
*discriminating* evidence and a concentrated posterior raises it to about 94%,
at the cost of staying silent roughly two thirds of the time. When it is
silent, it says so and falls back to 1500 rather than pretending.

## Recognition

**Zero calibration.** The piece set is auto-detected per screenshot: cburnett
(Lichess's default) is bundled, and one click in *Piece sets* fetches every
other recognizable Lichess set (38 of them - merida, alpha, staunty, horsey,
maestro, ...) into your local cache. Every square is scored against every
template of every installed set in a single matrix multiply; the best-matching
set classifies the board.

**Orientation is determined, not guessed.** Signals are consulted
strongest-first:

1. an explicit **Board orientation** choice in the UI - always wins;
2. **where the armies sit** - the two sides start on opposite ends and
   essentially never swap, so this is decisive for real positions;
3. **piece brightness** during calibration - white pieces are light-filled, so
   the brighter end of a starting position is white's;
4. coordinate labels, then FEN legality, as last resorts.

Calibration additionally asserts that the white templates really are brighter
than the black ones, so a misjudged orientation can never silently teach the
recognizer white pieces from black artwork - which would corrupt every later
reading.

**When it does not know, it says so.** A low-confidence match - small
winner-versus-runner-up margin, or a badly unmatched square - raises an
"unrecognized piece set" warning instead of emitting a confident wrong FEN. The
position is still loaded onto the board so you can drag the misread piece into
place, rather than being a dead end.

Piece art is downloaded at runtime for personal use and never redistributed
with this package - several sets are CC BY-NC-SA or freeware, and a
non-commercial clause does not mix with a free-software licence in either
direction. `piece_set_manifest()` records each set's licence.

## Setup

Dependencies are pinned in `renv.lock`:

```r
renv::restore()
```

Rtools/compilation is not required - everything installs as prebuilt binaries
on Windows/macOS.

Stockfish is downloaded on first use. The Blunder Radar additionally needs
[lc0](https://github.com/LeelaChessZero/lc0) and the Maia weights; on Windows
`ensure_maia()` fetches both. There is no official Linux binary for lc0, so the
container image builds it from source - see the `Dockerfile`. Without them the
app still works, and the radar says it is unavailable rather than failing.

## Run

```r
pkgload::load_all(".")
shiny::runApp(shiny::shinyApp(ui = app_ui, server = app_server))
```

or, once installed as a package:

```r
tanmai::run_app()
```

## Tests

```r
devtools::test()
```

277 tests. The suite pins the failures this project actually hit - orientation
detection and the colour-swap guard, the autocrop off-by-one across board
sizes, FEN and castling assembly, the confidence gate, the legal-move gate the
game tracker rests on, and the rating estimator's refusal to call a rating from
one move. Each was mutation-checked: reintroducing the original bug makes it
fail.

Tests use only the bundled cburnett art, so they need no network and no chess
engine; the parts that need Stockfish, lc0 or Maia skip cleanly on a bare
checkout. CI runs them on every push and pull request to `main`.

## Layout

```
R/
  app_ui.R, app_server.R, run_app.R  # golem entry points
  app_theme.R                        # design tokens, mirrored in styles.css
  mod_analyze.R                      # screenshot -> FEN
  mod_board.R                        # interactive board, live eval, radar
  mod_live.R                         # live game tracking + review
  mod_calibrate.R                    # teach a new piece set
  fct_detect.R                       # screenshot -> 64 squares
  fct_orientation.R                  # which way round the board is
  fct_pipeline.R                     # screenshot -> recognized position, end to end
  fct_recognize.R                    # template matching
  fct_fen.R                          # squares -> FEN, castling inference
  fct_chessjs.R                      # chess.js/V8 bridge (validity, SAN)
  fct_engine.R                       # Stockfish download + one-shot UCI query
  fct_engine_session.R               # persistent engine, MultiPV, live polling
  fct_human_model.R                  # Maia via lc0 (human move probabilities)
  fct_blunder_radar.R                # risk, trappiness, arrow selection
  fct_rating_estimate.R              # infer opponent rating from their moves
  fct_game_tracker.R                 # legal-move gate, eval graph, turning points
  fct_render.R                       # draw a position from any SVG piece set
  fct_piecesets.R                    # runtime piece-set download + manifest
  golem_utils.R                      # shared UI/reactive helpers
inst/
  app/templates.rds                  # bundled cburnett (Lichess) templates
  app/www/                           # styles.css, board.js, capture.js,
                                     #   paste.js, chessboard.js (MIT, vendored)
  svg/                               # cburnett piece SVGs (from python-chess)
  js/chess.js                        # bundled chess.js (MIT), V8 + browser
data-raw/build_default_templates.R   # regenerate inst/app/templates.rds
```

## Deployment

The app runs real chess engines, which rules out static hosts (Netlify) and
R-code-only platforms (shinyapps.io, whose bundles cannot ship or execute a
binary). It ships as a container:

```bash
docker build -t tanmai .
docker run --rm -p 8080:8080 tanmai   # then open http://localhost:8080
```

The image installs Stockfish from apt, builds lc0 from source in a separate
stage, bakes in the three Maia networks, and pre-builds every piece-set
template - so a cold start needs no downloads and nothing depends on a writable
filesystem. R package versions come from `renv.lock`, so the image and local
development cannot drift apart. `app.R` is the entrypoint and honours `$PORT`.
`TANMAI_STOCKFISH`, `TANMAI_LC0` and `TANMAI_MAIA_DIR` override
the engine and weights locations.

`docker-build.yaml` builds the image on every push and pull request, boots it,
and asserts that the app serves its own markup and stylesheet, that the engine
is found, and that Stockfish returns a move - so the image is verified with no
cloud account configured.

### Cloud Run

Deployment is driven by a **Google Cloud Build trigger** on `main`, which builds
this `Dockerfile` and updates the Cloud Run service. Cloud Run suits this app
because memory is configurable - lc0 plus three Maia networks needs far more
than the 512 MB typical of free tiers - and it scales to zero when idle.

Two things worth knowing:

- Cloud Build invokes the **legacy docker builder**, not BuildKit, so
  BuildKit-only syntax (`ADD --chmod=`, `RUN --mount=`, heredocs) fails there
  even though it builds fine locally and in `docker-build.yaml`. Stick to
  portable Dockerfile syntax.
- Give the service at least **2 GiB**. Starved, the radar degrades to "human
  model unavailable" rather than crashing, so a green deploy will not tell you
  it is wrong - check the radar actually works.

Also worth setting: low concurrency, because one R process is single-threaded;
a long request timeout, because Shiny holds a websocket open for the session;
session affinity; and startup CPU boost to shorten cold starts.

## Known limitations

- **Side to move** cannot be read from a still image - the UI asks for it. In a
  tracked game it is settled by which reading continues the game legally.
- **En passant** is not inferred; **castling rights** are granted only when king
  and rook sit on their home squares.
- **Rating estimation is a weak signal**, and says so. See above for the
  numbers.
- Live capture needs a current browser over HTTPS or localhost, and the app's
  window has to stay visible, because browsers throttle timers in a hidden tab.
- Stockfish and piece sets download to `tools::R_user_dir("tanmai",
  "cache")` on first use - needs an internet connection once.
- A few Lichess sets are hard on template matching because their *own* pieces
  are nearly identical: `firi`'s black and white rooks are 98% similar, with
  `governor` and `pirouetti` close behind. They read correctly from a clean
  screenshot but can misread a heavily compressed one. `mono`, `letter` and
  `disguised` are excluded outright - their pieces are ambiguous by design.
  `reillycraig` is excluded because its SVGs do not rasterize.
- **Chess.com piece art is deliberately not downloaded.** It is proprietary and
  its terms prohibit scraping, so bundling or auto-fetching it would be a
  licensing problem. The one-shot manual calibration is designed for exactly
  this and works for any custom theme.

## Documentation

Full documentation, including a walkthrough of the app and how the Blunder
Radar and live tracking work:
<https://tenmeh.github.io/tanmai/>

## Support

Tanmai is free and open source, and I work on it in my own time. If it
helps you, you can
[sponsor my work on GitHub](https://github.com/sponsors/tenmeh).

## Licence

[AGPL-3.0](LICENSE). Use it, study it, change it, share it. If you distribute
it - or run a modified copy as a website - the source has to be available under
the same terms.

Versions up to v1.0.3 were released under MIT and remain available under it.

Third-party components (chess.js, chessboard.js, the piece art, Stockfish, lc0,
Maia, Poppins) keep their own licences; see [LICENSE.md](LICENSE.md).
