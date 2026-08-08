# tanmai 1.4.0

## New features

* **The opponent-rating slider now offers every hundred from 1100 to 1900**,
  rather than three settings 400 points apart. Each stop is a real trained
  network, not the nearest of a coarse few, so asking about a 1300 gets you a
  model of a 1300.

  The range itself cannot be widened: CSSLab trained Maia for 1100-1900 and
  nothing outside it exists - `maia-1000` and `maia-2000` both 404. Verified
  against the repository rather than assumed, and the bound is now stated in
  the code so the next person does not go looking.

* The Blunder Radar falls back to the nearest network it actually has, instead
  of switching itself off. Deployed images bake in all nine, but a development
  machine may hold only some, and modelling a 1300 as the 1400 you do have
  beats declining to model a human at all.

## Notes

* The rating **estimator** deliberately keeps its three-network grid. Its
  published accuracy - right about 75% of the time, 94% when it chooses to
  speak - was measured over those three, and the rule producing those figures
  wants 70% of the posterior on a single network. Adjacent Maia networks play
  very similarly, so on a nine-way grid that mass spreads across neighbours and
  the estimator would fall silent almost always: not because it knows less, but
  because it is being asked a harder question than the one it was calibrated
  for. Widening it needs a re-derived confidence rule and a fresh corpus.

* The image build now asserts on the weight files directly. Checking
  `human_model_available()` for each rating would have become vacuous once that
  function learned to fall back, and a build check that cannot fail is worse
  than none.

# tanmai 1.3.1

## Bug fixes

* **A FEN with the trailing fields trimmed is accepted, as the box has claimed
  since 1.3.0.** The comment there said chess.js "fills in the fields people
  habitually leave off". It does the opposite - it validates strictly and
  rejects anything short of six fields - so pasting what Lichess and Chess.com
  actually copy to the clipboard failed with "must contain six space-delimited
  fields". `fen_complete()` now fills them in before validation.

  Castling is deliberately not invented when the field is absent: such a FEN is
  not claiming those rights, and granting them would silently change the
  position. Recognition from a screenshot still infers castling, because a
  picture has no such field to omit.

# tanmai 1.3.0

## New features

* **Load a position from FEN.** If you already have the position as text,
  recognition is a step to skip rather than endure. Paste it under *Read a
  position* and it goes straight to the board. A four-field FEN is accepted -
  chess.js fills in the clocks - and a bad one is reported with chess.js's own
  message, which says *which* field is wrong instead of just "invalid".

* **Import a game from PGN.** Paste a game and the whole thing loads: move
  list, evaluation graph, where it turned, and the Blunder Radar review on any
  move. Headers, comments, annotation glyphs and variations are all handled,
  and a `[FEN]` header is honoured so a study or endgame is not silently
  replayed from the standard opening position.

  An imported game is the same object as one watched move by move, which is
  why none of the analysis needed writing twice.

## Bug fixes

* Evaluating a game no longer blocks the app. The scorer worked through every
  unscored position in one pass - fine for the ply or two a live observation
  adds, but an imported game arrives with all of it unscored, and forty-odd
  positions at a quarter-second each would have frozen Shiny's single thread
  for about eleven seconds. It now does a few per pass and comes back for the
  rest, so the graph fills in while the app stays usable.

# tanmai 1.2.0

## Renamed

* **The package is now `tanmai`, not `chessvision`.** The old name collided
  with Chessvision.ai, a well-established browser extension that does the same
  job - reading a chess board from a screenshot. Publishing under a name
  already owned by a known product in the same problem space is a bad idea
  generally, and a worse one with CRAN in mind.

* The repository moved to `tenmeh/tanmai` for the same reason. GitHub redirects
  the old address, so existing clones and links keep working, but the
  documentation site is now at <https://tenmeh.github.io/tanmai/>.

* One name across the package, the repository, the app and the Cloud Run
  service, where there were three.

* `library(chessvision)` no longer works; use `library(tanmai)`. Earlier
  releases keep the old name and are unaffected.

* Cached downloads move with the name, from `R_user_dir("chessvision")` to
  `R_user_dir("tanmai")`. Stockfish, lc0, the Maia weights and any downloaded
  piece sets are fetched again on first use. They are all re-downloadable, so
  nothing is lost except the bandwidth - the old directory can be deleted.

* `CHESSVISION_STOCKFISH`, `CHESSVISION_LC0` and `CHESSVISION_MAIA_DIR` are now
  `TANMAI_*`, **and the old names are still honoured**. Dropping them would
  have broken any container or shell profile that sets them, and broken it
  silently: each one falls back to behaviour that looks perfectly normal -
  searching `PATH` for the engine, looking in the user cache for the weights -
  so the only symptom would be the radar quietly reporting itself unavailable.

# tanmai 1.1.0

## Licence

* **Now AGPL-3.0** (was MIT). You may still use, study, modify and share this
  freely - but if you distribute it, or run a modified copy as a website, the
  source has to be available under the same terms. The "Affero" part is the
  point for something that is primarily a hosted app: an ordinary GPL lets
  someone run a changed version as a service and never publish anything.

* Releases up to and including v1.0.3 stay available under MIT. That cannot be
  withdrawn, and is not being pretended otherwise.

## Documentation

* **A documentation site**, built with pkgdown and published to GitHub Pages:
  <https://tenmeh.github.io/tanmai/>. Every exported
  function has a reference page, grouped by what it is for rather than in one
  alphabetical wall, and `NEWS.md` becomes the changelog.

* Three articles: a *Getting Started* walkthrough of the app, and one each on
  how the Blunder Radar is scored and why the live tracker rests on a single
  legality rule.

* Poppins is served from the site itself rather than from Google's CDN, so
  reading the docs makes no third-party request.

# tanmai 1.0.3

## Bug fixes

* **Tapping a highlighted square works on the first tap.** It took two. The
  guard that stops a tap being handled twice was a plain flag, set when
  chessboard.js reported the press and cleared by the click that follows it -
  but that click does not always arrive, because chessboard.js moves the piece
  element to a drag layer and back, so the press and release can land on
  different elements. The flag then survived to swallow the *next* tap, which
  is why selecting a piece worked and moving it needed two goes. The guard is
  now tied to the specific square and expires on its own, so a stale one can
  only ever suppress a repeat press on the same square.

# tanmai 1.0.2

## Bug fixes

* **Tap to move actually works.** It was shipped in 1.0.1 but never functioned
  on a real click. chessboard.js claims the `mousedown` on a piece to begin a
  drag, so pressing and releasing on one square arrives as a drag that was
  dropped where it started - and the `click` that follows was being swallowed
  as the tail of that drag. Taps on your own pieces are now recognised through
  chessboard.js's own drop callback instead of waiting for a click that comes
  too late. Dragging is unaffected.

# tanmai 1.0.1

## Bug fixes

* **Pieces can be moved by tapping.** Tap a piece to select it - its legal
  destinations appear as dots, captures as rings - then tap where it should
  go. Dragging still works exactly as before. Dragging was the only way to
  move a piece, and on a phone the board is small enough that a square is
  about 34 pixels, which is not a realistic drag target for a thumb.

* **Controls are big enough to hit on a touch screen.** Radio buttons were
  19 pixels tall against an accessibility floor of about 44, so choosing a
  side to move or an orientation was a matter of luck.

* **A recognised position scrolls itself into view.** On a phone the page is
  several screens tall and the board sat below the fold, so analysing a
  screenshot appeared to do nothing. The board is only scrolled to when it is
  actually off screen, so nothing moves under you on a desktop.

# tanmai 1.0.0

## New features

* **The interface has been rebuilt.** It was stock Bootstrap 3 Shiny - a
  title, tabs, and every control stacked down one column between horizontal
  rules. It now runs on Bootstrap 5 with a designed palette, type scale and
  spacing, and a light/dark switch in the navbar. The board is the centre of
  the app, so it now sits in its own panel with the evaluation, engine lines
  and blunder radar alongside it, rather than being the third thing down a
  wall of forms. Capture settings are folded away until wanted.

* **The opponent's rating is estimated from their moves.** Reviewing a move no
  longer starts by asking which strength to explain it for - a question most
  people cannot answer about an opponent. Each Maia network is a distribution
  over moves for a rating, so the moves already played are evidence: the
  network least surprised by them is the most likely one. Choose "Estimated
  from this game" and the review models whoever actually played the move under
  review, judged on every move they made.

* The estimate says when it does not know. Picking the most likely of the three
  networks is right about 75% of the time on its own - better than the 33% of
  guessing, but not a fact. Requiring enough moves, enough discriminating
  evidence and a concentrated posterior raises that to about 94%, at the cost
  of staying silent roughly two thirds of the time, when it says so and falls
  back to 1500. Accuracy barely improves with more moves, because the limit is
  how alike the networks are rather than how much data there is.

* **Live game tracking.** Follow a game as it is played rather than analysing
  one frozen position. Share the window you are playing in, or paste a fresh
  screenshot after each move, and the app keeps the running game: the move
  list, an evaluation per move, a graph of the evaluation across the game, and
  a list of the moves where it turned.

* A position only joins the game when exactly one sequence of legal moves
  explains how it got there. That single rule does the work of a pile of
  ad-hoc filters: it throws out misread squares, ignores frames caught
  mid-animation, recovers a ply that was never seen on screen, and handles
  castling, en passant and promotion correctly because chess.js generates the
  moves rather than a square-by-square diff guessing at them. Readings that
  cannot be explained are counted and shown, not quietly appended - a tracker
  that invents moves is worse than one that says it lost the thread.

* Which way round the board is, and whose turn it is, are settled by the game
  instead of guessed from pixels. A screenshot can show neither, so both
  readings are put to the same gate and the one that continues the game legally
  is the one that was right.

* Clicking a move - in the list, on the graph, or in the turning points -
  rewinds the board to just before it and offers to ask the Blunder Radar
  whether the mistake was predictable. After `3.Qh5 Nf6` it reports that a 1500
  player plays `Nf6` here 6% of the time and that it is the single largest
  source of risk in the position: what the move cost and why it was tempting,
  in one place.

* Screen capture is `getDisplayMedia` - the browser's own dialog, one choice of
  screen, window or tab, and the board marked once by dragging over a still
  frame. Frames are compared in the browser and only a settled, changed picture
  is sent, so the cost is roughly one recognition per move rather than one per
  tick. Mark the region roughly on the board's edge: it is grown outward a
  little before use, since slicing into the board is fatal to recognition,
  but a very loose region is no good either - past a margin of about 5% the
  edge detection stops finding the board. It needs a current browser over
  HTTPS or localhost, and the app's window has to stay visible, because
  browsers throttle timers in a hidden tab.
  A web page cannot read the screen unprompted, or watch the clipboard while
  another window has focus; neither is pretended at, and pasting after each
  move is a first-class alternative rather than a fallback.

* **Blunder Radar.** An engine tells you what is best; this tells you what is
  likely to go *wrong*. For an opponent of a chosen strength (1100/1500/1900),
  it scores every legal move by `P(a human plays it) x centipawns it loses`,
  combining [Maia](https://github.com/CSSLab/maia-chess) human-move
  probabilities with Stockfish evaluations. Known traps score roughly 2000x a
  quiet position: Legal's mate 6724 cp, Scholar's mate 1673 cp, versus 3.0 cp
  for the starting position.

* Board arrows show the engine's choice in blue and the moves a human is
  likely to get wrong in orange/red. Arrows are picked by *risk contribution*
  rather than raw probability, because in a trap the dangerous move is by
  construction not the most likely one - after `3.Qh5`, the losing `Nf6` is
  only the fourth most probable reply, and would otherwise never be drawn.

* The interactive board now lives on the analyze page instead of a separate
  tab, and a recognized screenshot loads onto it automatically. Reading a
  position and exploring it is one task; splitting it across tabs meant a
  round trip and a button in between.

* lc0 and the Maia networks are built into the container image, so the
  Blunder Radar works on a deployed instance and not just locally.

## Bug fixes

* The image builds on Google Cloud Build again. The Maia weights had their
  permissions widened with `ADD --chmod=`, which is BuildKit-only syntax;
  Cloud Build still invokes the legacy docker builder and rejected it
  outright. A separate `chmod` step behaves identically under both builders.

* The interactive board keeps its move history when a tracked game drives it.
  Inferred moves are played onto it one at a time instead of the position being
  set outright, so its move numbers agree with the game's rather than
  restarting from wherever the last jump landed.

* "Open in board" no longer requires the piece set to have been recognized
  confidently. It now only requires the position to be structurally legal, so
  a Chess.com or custom-theme screenshot can still be sent to the board and
  corrected by hand rather than being a dead end.

* Misread squares can be fixed by dragging pieces on the board directly,
  instead of needing a full recalibration of the piece set.

* R package versions in the container image are installed from `renv.lock`
  rather than a hand-maintained list in the `Dockerfile`, so local
  development and the deployed image can no longer drift apart. `rsvg` - a
  required dependency - was missing from the lockfile entirely.

* Container builds retry transient package-mirror failures instead of failing
  the whole build over a single unreachable file.
