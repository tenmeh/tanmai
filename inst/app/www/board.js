// Interactive analysis board: chessboard.js for rendering/drag-drop, chess.js
// for legality, and Shiny inputs/messages to sync with the server.
//
// Client-side chess.js is the same bundle the server runs in V8, so both sides
// agree on the rules. The server owns evaluation; the browser owns the move
// tree and only reports the resulting FEN.
//
// Every message carries explicit, already-namespaced element/input ids from the
// R module (via session$ns), so this file never reconstructs Shiny ids itself.
(function () {
  var boards = {}; // container id -> {board, game, stateInput, orientation}
  var pending = {}; // container id -> board-set message received before build
  var lastTouched = null; // which board the keyboard should drive

  // Every position of the current line, from the game's starting position to
  // its latest move. Derived by replaying rather than cached, so it cannot
  // drift out of step with the game, and cheap enough at a few hundred plies
  // that caching would be a premature optimisation.
  //
  // Replaying is also what keeps this working across chess.js versions: 1.x
  // exposes `before`/`after` FENs on verbose history and 0.x does not, and the
  // rest of this file already supports both.
  function positionsOf(cid) {
    var st = boards[cid];
    var start = st.startFen || new window.ChessCtor().fen();
    var fens = [start];
    var walk;
    try {
      walk = new window.ChessCtor(start);
    } catch (e) {
      return [st.game.fen()];
    }
    var hist = st.game.history();
    for (var i = 0; i < hist.length; i++) {
      try {
        walk.move(hist[i]);
      } catch (e) {
        break;
      }
      fens.push(walk.fen());
    }
    return fens;
  }

  function clampCursor(cid, fens) {
    var st = boards[cid];
    var last = fens.length - 1;
    if (typeof st.cursor !== "number" || st.cursor > last || st.cursor < 0) {
      st.cursor = last;
    }
    return st.cursor;
  }

  function sendState(cid) {
    var st = boards[cid];
    if (!st) return;
    var g = st.game;
    var fens = positionsOf(cid);
    var cursor = clampCursor(cid, fens);
    var atEnd = cursor === fens.length - 1;
    var viewFen = fens[cursor];
    var history = g.history();
    var over = typeof g.isGameOver === "function" ? g.isGameOver() : g.game_over();

    Shiny.setInputValue(
      st.stateInput,
      {
        // The position being *looked at*, not necessarily the latest one, so
        // the engine analyses what the user can see. Rewinding is a way of
        // asking "what did the engine think here", and it would be useless if
        // the evaluation stayed pinned to the final position.
        fen: viewFen,
        turn: viewFen.split(" ")[1] || "w",
        history: history,
        last: cursor > 0 ? history[cursor - 1] : null,
        ply: cursor,
        plies: fens.length - 1,
        at_start: cursor === 0,
        at_end: atEnd,
        // Only the live position can be finished; a rewound one always has a
        // move available, namely the one that was actually played next.
        game_over: atEnd && over,
        nonce: Math.random()
      },
      { priority: "event" }
    );
  }

  // Show the position at `idx`, clamped to the line.
  function goTo(cid, idx) {
    var st = boards[cid];
    if (!st) return;
    var fens = positionsOf(cid);
    st.cursor = Math.max(0, Math.min(idx, fens.length - 1));
    clearSelection(cid);
    st.board.position(fens[st.cursor]);
    sendState(cid);
  }

  // Playing a move from a rewound position continues from there, discarding
  // what followed - the behaviour of every analysis board, and the only one
  // that makes "go back and try something else" work.
  function truncateToCursor(cid) {
    var st = boards[cid];
    if (typeof st.cursor !== "number") return;
    var guard = 0;
    while (st.game.history().length > st.cursor && guard++ < 1024) {
      st.game.undo();
    }
  }

  // The game as it stands *at the cursor*. Interaction has to be answered from
  // the position on screen, not the latest one: which side may be dragged,
  // which squares a piece can reach, what is on a square. When the cursor is
  // at the live end this returns the game itself, so nothing changes on the
  // common path - including draw detection, which needs the move history a
  // FEN cannot carry.
  function activeGame(cid) {
    var st = boards[cid];
    var hist = st.game.history();
    if (st.cursor === undefined || st.cursor === hist.length) return st.game;
    var fens = positionsOf(cid);
    try {
      return new window.ChessCtor(fens[st.cursor]);
    } catch (e) {
      return st.game;
    }
  }

  function onDragStart(cid) {
    return function (source, piece) {
      var st = boards[cid];
      var g = activeGame(cid);
      // Rewound positions are always playable: refusing here would make
      // "go back and try something else" impossible after a finished game.
      var atEnd = st.cursor === undefined || st.cursor === st.game.history().length;
      var over = typeof g.isGameOver === "function" ? g.isGameOver() : g.game_over();
      if (atEnd && over) return false;
      // Only the side to move may be dragged.
      if (piece.search(new RegExp("^" + (g.turn() === "w" ? "b" : "w"))) !== -1) {
        return false;
      }
    };
  }

  // Try a move, updating the board and telling the server if it was legal.
  // Returns true when the move was played.
  function tryMove(cid, from, to) {
    var st = boards[cid];
    var move = null;
    truncateToCursor(cid);
    try {
      move = st.game.move({ from: from, to: to, promotion: "q" });
    } catch (e) {
      move = null; // chess.js 1.x throws on an illegal move
    }
    if (move === null) return false;
    st.cursor = st.game.history().length;
    sendState(cid);
    return true;
  }

  function onDrop(cid) {
    return function (source, target) {
      var st = boards[cid];

      // Pressing and releasing on the same square is a tap, not a drag - but
      // chessboard.js has already claimed the mousedown, so this callback is
      // the only place it can be seen. Routing it here rather than waiting for
      // a `click` is the whole trick: on a piece, chessboard.js starts a drag
      // the moment you press, and the click that follows arrives after this.
      if (target === source) {
        handleTap(cid, source);
        noteHandled(cid, source);
        return "snapback";
      }

      clearSelection(cid);
      noteHandled(cid, target);
      if (!tryMove(cid, source, target)) return "snapback";
    };
  }

  // ---- tap to move -------------------------------------------------------
  // Dragging a piece across a 34px square with a thumb is miserable, and on a
  // phone that is the only size a board comes in. Tapping the piece and then
  // its destination is the interaction every mobile chess app uses, and it
  // costs desktop users nothing - drag still works exactly as before.

  function clearSelection(cid) {
    var st = boards[cid];
    if (!st) return;
    var host = document.getElementById(cid);
    if (host) {
      host.querySelectorAll(".cv-sq-selected, .cv-sq-target").forEach(function (e) {
        e.classList.remove("cv-sq-selected", "cv-sq-target");
      });
    }
    st.selected = null;
  }

  function selectSquare(cid, square) {
    var st = boards[cid];
    var host = document.getElementById(cid);
    if (!st || !host) return;
    clearSelection(cid);
    st.selected = square;

    var from = host.querySelector('[data-square="' + square + '"]');
    if (from) from.classList.add("cv-sq-selected");

    // Show where it can actually go. chess.js is already here and authoritative,
    // so this cannot disagree with what a move attempt will accept.
    var moves = [];
    try {
      moves = activeGame(cid).moves({ square: square, verbose: true }) || [];
    } catch (e) {
      moves = [];
    }
    moves.forEach(function (m) {
      var el = host.querySelector('[data-square="' + m.to + '"]');
      if (el) el.classList.add("cv-sq-target");
    });
  }

  function ownPieceAt(cid, square) {
    var g = activeGame(cid);
    var p = null;
    try {
      p = g.get(square);
    } catch (e) {
      p = null;
    }
    return p && p.color === g.turn();
  }

  // What a tap on a square means. Reached two ways, because chessboard.js only
  // claims presses that land on a piece:
  //   - via onDrop(source === target), for a tap on one of your own pieces;
  //   - via the delegated click below, for empty squares and enemy pieces,
  //     where no drag was ever started.
  function handleTap(cid, square) {
    var st = boards[cid];
    if (!st) return;

    var over =
      typeof st.game.isGameOver === "function"
        ? st.game.isGameOver()
        : st.game.game_over();
    if (over) return;

    if (!st.selected) {
      if (ownPieceAt(cid, square)) selectSquare(cid, square);
      return;
    }
    if (st.selected === square) {
      clearSelection(cid); // tapping it again puts it back down
      return;
    }
    if (tryMove(cid, st.selected, square)) {
      clearSelection(cid);
      st.board.position(st.game.fen());
      return;
    }
    // Not a legal destination: treat it as picking a different piece, or as a
    // miss.
    if (ownPieceAt(cid, square)) selectSquare(cid, square);
    else clearSelection(cid);
  }

  // Record that chessboard.js already dealt with a press on this square, so
  // the click that may follow is a duplicate rather than a new tap.
  //
  // Deliberately keyed on the square and a short deadline, not a plain flag.
  // A flag assumes the trailing click always arrives - and it does not:
  // chessboard.js moves the piece element to a drag layer and back, so
  // mousedown and mouseup can end up on different elements and the browser
  // fires no click at all. The flag then survived to eat the *next* tap,
  // which is why selecting a piece worked but the move needed two clicks on
  // the destination. Keyed this way, a stale record can only ever suppress a
  // second press on the same square, and expires regardless.
  function noteHandled(cid, square) {
    var st = boards[cid];
    if (!st) return;
    st.handledSquare = square;
    st.handledAt = Date.now();
  }

  function alreadyHandled(cid, square) {
    var st = boards[cid];
    if (!st || st.handledSquare !== square) return false;
    // Generous, because a touch browser can delay the synthesised click.
    var fresh = Date.now() - st.handledAt < 700;
    if (fresh) st.handledSquare = null; // one duplicate only
    return fresh;
  }

  function onBoardClick(cid) {
    return function (ev) {
      var st = boards[cid];
      if (!st) return;
      var cell = ev.target.closest("[data-square]");
      if (!cell) return;
      var square = cell.getAttribute("data-square");
      if (alreadyHandled(cid, square)) return;
      handleTap(cid, square);
    };
  }

  function onSnapEnd(cid) {
    return function () {
      boards[cid].board.position(boards[cid].game.fen());
    };
  }

  function build(msg) {
    var cid = msg.container;
    var game;
    try {
      game = new window.ChessCtor(msg.fen || undefined);
    } catch (e) {
      // chess.js throws on a structurally illegal FEN (missing king, pawns on
      // the back rank, ...). The server is expected to filter these out
      // before sending a create/set message, but falling back to the start
      // position beats leaving this container's board half-built forever.
      game = new window.ChessCtor();
    }
    var board = window.Chessboard(cid, {
      draggable: true,
      position: game.fen(),
      orientation: msg.orientation || "white",
      // Full URL template from R, e.g. "pieces/{piece}.svg" - the extension
      // varies because a few sets ship webp/png instead of svg.
      pieceTheme: msg.pieceTheme,
      onDragStart: onDragStart(cid),
      onDrop: onDrop(cid),
      onSnapEnd: onSnapEnd(cid)
    });
    boards[cid] = {
      board: board,
      game: game,
      // Where this line begins. Not always the standard opening position - a
      // recognised screenshot or a PGN with a [FEN] header starts elsewhere -
      // so it has to be remembered rather than assumed.
      startFen: game.fen(),
      cursor: game.history().length,
      stateInput: msg.stateInput,
      orientation: msg.orientation || "white",
      selected: null,
      handledSquare: null,
      handledAt: 0
    };
    // Delegated, so it survives chessboard.js rebuilding the squares on every
    // position change.
    var host = document.getElementById(cid);
    if (host) {
      host.addEventListener("click", onBoardClick(cid));
      // Keyboard navigation needs to know which board to drive when a
      // page holds more than one.
      host.addEventListener("mousedown", function () {
        lastTouched = cid;
      });
    }
    window.addEventListener("resize", function () {
      board.resize();
      redrawArrows(cid);
    });
    sendState(cid);
  }

  // chessboard.js fixes its square size from the container width at build
  // time, so building while the tab is still hidden (width 0) produces a 0px
  // board that later resizes don't reliably repair. Wait for the container to
  // actually have width - i.e. the tab has been shown - then build once, and
  // keep re-fitting on later size changes.
  function create(msg) {
    var cid = msg.container;
    var host = document.getElementById(cid);
    if (!host) return;

    var built = false;
    var lastW = 0;

    function tryBuild() {
      var w = host.clientWidth;
      if (!built && w > 0) {
        built = true;
        lastW = w;
        build(msg);
        // Apply any position that arrived while we were waiting.
        if (pending[cid]) {
          applySet(pending[cid]);
          delete pending[cid];
        }
      } else if (built && w > 0 && Math.abs(w - lastW) > 1) {
        lastW = w;
        boards[cid].board.resize();
        redrawArrows(cid);
      }
    }

    if (typeof ResizeObserver === "function") {
      new ResizeObserver(tryBuild).observe(host);
    }
    // ResizeObserver does not always fire for a display:none -> visible tab
    // switch, so poll as well until the board exists.
    var ticks = 0;
    var timer = setInterval(function () {
      tryBuild();
      if (built || ticks++ > 600) clearInterval(timer);
    }, 100);
    tryBuild();
  }

  // ---- arrows ------------------------------------------------------------
  var lastArrows = {}; // container id -> arrow spec, kept for redraw on resize

  function redrawArrows(cid) {
    var spec = lastArrows[cid];
    if (spec) drawArrows(cid, spec);
  }

  function drawArrows(cid, arrows) {
    var st = boards[cid];
    var host = document.getElementById(cid);
    if (!st || !host) return;

    var old = host.querySelector(".cv-arrows");
    if (old) old.remove();
    lastArrows[cid] = arrows;
    if (!arrows || !arrows.length) return;

    var size = host.clientWidth;
    if (!size) return;
    var sq = size / 8;
    var flipped = st.board.orientation() === "black";
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("class", "cv-arrows");
    svg.setAttribute("width", size);
    svg.setAttribute("height", size);
    var defs = document.createElementNS(ns, "defs");
    svg.appendChild(defs);

    function centre(square) {
      var file = square.charCodeAt(0) - 97;
      var rank = parseInt(square[1], 10) - 1;
      var x = flipped ? 7 - file : file;
      var y = flipped ? rank : 7 - rank;
      return { x: (x + 0.5) * sq, y: (y + 0.5) * sq };
    }

    arrows.forEach(function (a, i) {
      var mkId = "cv-head-" + cid.replace(/[^A-Za-z0-9_-]/g, "") + "-" + i;
      var mk = document.createElementNS(ns, "marker");
      mk.setAttribute("id", mkId);
      mk.setAttribute("markerWidth", "4");
      mk.setAttribute("markerHeight", "4");
      mk.setAttribute("refX", "2.6");
      mk.setAttribute("refY", "2");
      mk.setAttribute("orient", "auto");
      var tip = document.createElementNS(ns, "path");
      tip.setAttribute("d", "M0,0 L4,2 L0,4 z");
      tip.setAttribute("fill", a.color);
      mk.appendChild(tip);
      defs.appendChild(mk);

      var from = centre(a.from);
      var to = centre(a.to);
      var line = document.createElementNS(ns, "line");
      line.setAttribute("x1", from.x);
      line.setAttribute("y1", from.y);
      line.setAttribute("x2", to.x);
      line.setAttribute("y2", to.y);
      line.setAttribute("stroke", a.color);
      line.setAttribute("stroke-width", a.width || sq * 0.14);
      line.setAttribute("stroke-linecap", "round");
      line.setAttribute("opacity", a.opacity || 0.75);
      line.setAttribute("marker-end", "url(#" + mkId + ")");
      svg.appendChild(line);
    });

    host.appendChild(svg);
  }

  // ---- Shiny message handlers -------------------------------------------
  // ---- keyboard navigation ------------------------------------------------
  // Left/right step, up/down (and Home/End) jump to the ends - the bindings
  // every analysis site uses, so they need no explanation.
  //
  // Most of this is about *not* firing. Arrow keys already mean something in a
  // text field and mean "scroll" everywhere else, so hijacking them globally
  // would be worse than not having the feature.

  function isTyping(el) {
    if (!el) return false;
    var tag = (el.tagName || "").toLowerCase();
    return (
      tag === "input" ||
      tag === "textarea" ||
      tag === "select" ||
      el.isContentEditable === true
    );
  }

  // The board to drive: the only one, or the last one touched. A board on a
  // tab that is not showing has no offsetParent, and must not swallow the
  // arrow keys the user is scrolling that tab with.
  function keyboardTarget() {
    var ids = Object.keys(boards).filter(function (cid) {
      var host = document.getElementById(cid);
      return host && host.offsetParent !== null;
    });
    if (!ids.length) return null;
    if (ids.length === 1) return ids[0];
    if (lastTouched && ids.indexOf(lastTouched) !== -1) return lastTouched;
    return ids[0];
  }

  document.addEventListener("keydown", function (ev) {
    // Ctrl/Cmd/Alt combinations belong to the browser.
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
    if (isTyping(ev.target)) return;

    var cid = keyboardTarget();
    if (!cid) return;

    var st = boards[cid];
    var last = positionsOf(cid).length - 1;
    var cursor = typeof st.cursor === "number" ? st.cursor : last;
    var target;
    switch (ev.key) {
      case "ArrowLeft":
        target = cursor - 1;
        break;
      case "ArrowRight":
        target = cursor + 1;
        break;
      case "ArrowUp":
      case "Home":
        target = 0;
        break;
      case "ArrowDown":
      case "End":
        target = last;
        break;
      default:
        return;
    }
    // Only now, once we know this keystroke is ours: otherwise the page would
    // stop scrolling for keys we never handle.
    ev.preventDefault();
    goTo(cid, target);
  });

  Shiny.addCustomMessageHandler("tanmai-board-create", function (msg) {
    // The container may not exist yet when the tab has never been shown.
    var tries = 0;
    (function attempt() {
      if (document.getElementById(msg.container)) {
        create(msg);
      } else if (tries++ < 60) {
        setTimeout(attempt, 50);
      }
    })();
  });

  function applySet(msg) {
    var st = boards[msg.container];
    if (!st) {
      // Board not built yet (its tab has never been opened); remember the
      // position and apply it once the board exists.
      pending[msg.container] = msg;
      return;
    }
    var game;
    try {
      game = new window.ChessCtor(msg.fen);
    } catch (e) {
      // A structurally illegal FEN (see build()); ignore rather than break
      // an otherwise-working board.
      return;
    }
    st.game = game;
    st.startFen = game.fen();
    st.cursor = 0;
    // The selected piece may not exist in the new position, and the highlight
    // would survive onto whatever now sits on that square.
    clearSelection(msg.container);
    st.board.position(msg.fen, false);
    if (msg.orientation && msg.orientation !== st.orientation) {
      st.orientation = msg.orientation;
      st.board.orientation(msg.orientation);
    }

    // A position just arrived from somewhere else on the page. On a phone the
    // board can be two screens further down, so bring it into view - but only
    // when it is actually off screen, which means this does nothing on a
    // desktop where the board was already in front of you.
    var host = document.getElementById(msg.container);
    if (host && typeof host.scrollIntoView === "function") {
      var r = host.getBoundingClientRect();
      var vh = window.innerHeight || document.documentElement.clientHeight;
      var visible = r.top < vh * 0.75 && r.bottom > vh * 0.25;
      if (!visible) {
        host.scrollIntoView({ behavior: "smooth", block: "center" });
      }
    }

    sendState(msg.container);
  }

  Shiny.addCustomMessageHandler("tanmai-board-set", applySet);

  Shiny.addCustomMessageHandler("tanmai-board-undo", function (msg) {
    var st = boards[msg.container];
    if (!st) return;
    truncateToCursor(msg.container);
    st.game.undo();
    st.cursor = st.game.history().length;
    st.board.position(st.game.fen());
    sendState(msg.container);
  });

  // First / back / forward / last, the controls every analysis board has.
  Shiny.addCustomMessageHandler("tanmai-board-nav", function (msg) {
    var st = boards[msg.container];
    if (!st) return;
    var last = positionsOf(msg.container).length - 1;
    var cursor = typeof st.cursor === "number" ? st.cursor : last;
    var target =
      msg.to === "first" ? 0
      : msg.to === "last" ? last
      : msg.to === "back" ? cursor - 1
      : msg.to === "forward" ? cursor + 1
      : cursor;
    goTo(msg.container, target);
  });

  Shiny.addCustomMessageHandler("tanmai-board-flip", function (msg) {
    var st = boards[msg.container];
    if (!st) return;
    st.board.flip();
    st.orientation = st.board.orientation();
    redrawArrows(msg.container);
  });

  // Accepts one move or several. The live tracker sends several when it had to
  // infer a ply it never saw on screen; playing them in turn keeps this board's
  // own history complete, which a jump to the final position would not.
  Shiny.addCustomMessageHandler("tanmai-board-move", function (msg) {
    var st = boards[msg.container];
    if (!st) return;
    var list = msg.ucis || msg.uci;
    if (!Array.isArray(list)) list = [list];
    // A move arriving from the server is played from the position on screen,
    // exactly as a dragged one is - so if the user has rewound, this continues
    // the line from there rather than appending to a position they are no
    // longer looking at.
    truncateToCursor(msg.container);
    var played = 0;
    list.forEach(function (uci) {
      if (!uci) return;
      var mv = { from: uci.slice(0, 2), to: uci.slice(2, 4) };
      if (uci.length > 4) mv.promotion = uci[4];
      try {
        st.game.move(mv);
        played++;
      } catch (e) {
        /* ignore an illegal suggestion */
      }
    });
    if (!played) return;
    // Follow the move. Without this the cursor stays where it was, the state
    // reported back describes an older position than the one now on the board,
    // and the next request is computed from the wrong place.
    st.cursor = st.game.history().length;
    st.board.position(st.game.fen());
    sendState(msg.container);
  });

  Shiny.addCustomMessageHandler("tanmai-board-arrows", function (msg) {
    drawArrows(msg.container, msg.arrows);
  });

  Shiny.addCustomMessageHandler("tanmai-evalbar", function (msg) {
    var w = document.getElementById(msg.white_id);
    var b = document.getElementById(msg.black_id);
    if (!w || !b) return;
    var pct = Math.max(0, Math.min(100, msg.pct));
    w.style.height = pct + "%";
    b.style.height = 100 - pct + "%";
  });
})();
