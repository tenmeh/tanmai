// Live board capture: a stream of board images for the game tracker.
//
// WHAT A BROWSER CAN ACTUALLY DO
//
// A Shiny app is a web page. It cannot read the screen, watch the clipboard in
// the background (navigator.clipboard.read() rejects unless the document has
// focus, which it does not while you are playing in another window), or attach
// to another site's DOM. The one real capability is getDisplayMedia: the user
// picks a screen, window or tab once in the browser's own dialog, and the page
// then receives a live video stream of it. That is a genuine capability with a
// genuine permission gate, and it is what this file uses. Everything else on
// offer would need a helper process or an extension.
//
// Two consequences are worth being plain about. The stream is whatever the
// user shared - a whole screen, most likely - so the board has to be located
// within it, which is why a region is selected once by dragging over a still
// frame. And a browser throttles timers in a fully hidden tab, so the app's
// window has to stay visible; side by side with the game, or on a second
// monitor.
//
// WHAT GETS SENT
//
// Not every frame. Frames are compared against each other in a small offscreen
// canvas, and one is sent only when the picture has settled (so a piece sliding
// mid-animation is not read) and differs from whatever was sent last (so
// re-renders and cursor movement cost nothing). This is only a prefilter: it
// exists to save work, not to be correct. Deciding whether a genuinely new
// board is a legal continuation of the game is the server's job, and it is
// strict about it - so this side can afford to be generous and send anything
// that might be interesting.
(function () {
  var cap = null; // active capture, or null

  var WORK = 96; // frame-comparison resolution, per side
  var SEND_MAX = 720; // longest side of the image actually sent to R
  // Nobody drags a rectangle onto a board edge to the pixel, so the marked
  // region is grown outward before use: cutting into the board shifts the 8x8
  // grid and recognition returns confident nonsense, whereas a margin of
  // background is trimmed back off by autocrop_board() on the server.
  //
  // The margin has to stay modest, though. Measured against a live capture,
  // recognition holds for margins up to about 5% of the board and breaks past
  // it - with too much background the edge detection stops finding the board
  // at all. So this pads by a little, not a lot, and the region still wants
  // marking roughly on the board edge.
  var PAD = 0.02; // ...by this share of the region per side
  var PAD_MIN = 4; // ...never fewer than this many pixels
  var PAD_MAX = 16; // ...and never more, to stay clear of that cliff
  // Deliberately low: a false positive here just costs one recognition, which
  // the server then discards. A false negative loses a move.
  var CHANGED = 0.8; // mean per-pixel luma delta counting as "something moved"
  var SETTLED = 1.0; // ...and below which the picture is holding still
  // How long to wait for the server to acknowledge a frame before assuming the
  // acknowledgement is never coming. Generous: recognition alone runs to well
  // over a second, and a busy container can be slower still. The only cost of
  // being wrong is one extra frame in flight.
  var STUCK_MS = 15000;

  function el(id) {
    return document.getElementById(id);
  }

  function status(state, message) {
    if (!cap) return;
    Shiny.setInputValue(
      cap.statusInput,
      { state: state, message: message || "", nonce: Math.random() },
      { priority: "event" }
    );
  }

  // ---- frame comparison --------------------------------------------------

  function luma(ctx2d) {
    var d = ctx2d.getImageData(0, 0, WORK, WORK).data;
    var out = new Float32Array(WORK * WORK);
    for (var i = 0, p = 0; i < d.length; i += 4, p++) {
      out[p] = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
    }
    return out;
  }

  function meanDelta(a, b) {
    if (!a || !b) return Infinity;
    var s = 0;
    for (var i = 0; i < a.length; i++) s += Math.abs(a[i] - b[i]);
    return s / a.length;
  }

  // ---- the region --------------------------------------------------------

  // Region is stored in the video's own pixel coordinates, so it stays correct
  // however the preview canvas is scaled on screen. What is marked is stored
  // as marked - the padding is applied here, at the point of use, so the
  // rectangle drawn back onto the preview still matches what the user drew.
  function clampPad(size) {
    return Math.min(PAD_MAX, Math.max(PAD_MIN, size * PAD));
  }

  function regionOrWhole() {
    var v = cap.video;
    if (!cap.region) return { x: 0, y: 0, w: v.videoWidth, h: v.videoHeight };
    var r = cap.region;
    var w = r.w + 2 * clampPad(r.w);
    var h = r.h + 2 * clampPad(r.h);

    // A board is square, so the region is squared off around its centre. Then
    // everything is rounded to whole pixels: a fractional source rectangle
    // makes the browser resample, which softens the boundaries between squares
    // and was enough on its own to turn a readable board into an unreadable
    // one. Whole numbers here mean the frame is copied, not interpolated.
    var side = Math.round(Math.min(Math.max(w, h), v.videoWidth, v.videoHeight));
    var x = Math.round(r.x + r.w / 2 - side / 2);
    var y = Math.round(r.y + r.h / 2 - side / 2);
    return {
      x: Math.max(0, Math.min(x, v.videoWidth - side)),
      y: Math.max(0, Math.min(y, v.videoHeight - side)),
      w: side,
      h: side
    };
  }

  function drawPreview() {
    var v = cap.video;
    var c = cap.preview;
    if (!v.videoWidth) return;
    var scale = Math.min(1, 460 / v.videoWidth);
    c.width = Math.round(v.videoWidth * scale);
    c.height = Math.round(v.videoHeight * scale);
    cap.previewScale = scale;
    var g = c.getContext("2d");
    g.drawImage(v, 0, 0, c.width, c.height);
    if (cap.region) {
      g.strokeStyle = "#2b6cb0";
      g.lineWidth = 2;
      g.strokeRect(
        cap.region.x * scale,
        cap.region.y * scale,
        cap.region.w * scale,
        cap.region.h * scale
      );
    }
  }

  function bindRegionPicker() {
    var c = cap.preview;
    var dragging = false;
    var sx = 0;
    var sy = 0;

    function at(e) {
      var r = c.getBoundingClientRect();
      return {
        x: ((e.clientX - r.left) / r.width) * c.width,
        y: ((e.clientY - r.top) / r.height) * c.height
      };
    }

    c.addEventListener("mousedown", function (e) {
      dragging = true;
      var p = at(e);
      sx = p.x;
      sy = p.y;
      e.preventDefault();
    });
    c.addEventListener("mousemove", function (e) {
      if (!dragging) return;
      var p = at(e);
      drawPreview();
      var g = c.getContext("2d");
      g.strokeStyle = "#dd6b20";
      g.lineWidth = 2;
      g.strokeRect(sx, sy, p.x - sx, p.y - sy);
    });
    window.addEventListener("mouseup", function (e) {
      if (!dragging) return;
      dragging = false;
      var p = at(e);
      var x = Math.min(sx, p.x);
      var y = Math.min(sy, p.y);
      var w = Math.abs(p.x - sx);
      var h = Math.abs(p.y - sy);
      if (w < 20 || h < 20) return; // a click, not a drag
      var s = cap.previewScale || 1;
      cap.region = { x: x / s, y: y / s, w: w / s, h: h / s };
      cap.lastSent = null; // a new region means the last send is not comparable
      cap.prev = null;
      drawPreview();
      status(cap.timer ? "capturing" : "ready", "board region set");
    });
  }

  // ---- the loop ----------------------------------------------------------

  function tick() {
    if (!cap || !cap.video.videoWidth) return;
    var r = regionOrWhole();

    var wc = cap.work;
    var wg = wc.getContext("2d", { willReadFrequently: true });
    wg.drawImage(cap.video, r.x, r.y, r.w, r.h, 0, 0, WORK, WORK);
    var cur = luma(wg);

    if (cap.inflight && Date.now() - cap.inflightSince > STUCK_MS) {
      cap.inflight = false; // give up waiting rather than stop capturing
    }

    var moving = meanDelta(cur, cap.prev);
    var novel = meanDelta(cur, cap.lastSent);
    cap.prev = cur;

    // Still moving: a piece is sliding, or a menu is animating. Reading the
    // board now would give a position that never existed.
    if (moving > SETTLED) return;
    if (novel < CHANGED) return;

    // Backpressure. Recognition takes longer than the capture interval on any
    // realistic board size - measured at 1.2-1.4s against a 1.2s default - so
    // a fixed timer sends faster than the server can consume. Shiny is single
    // threaded, the surplus frames queue up inside it, and the backlog grows
    // without bound until the container is killed. It reads as a memory leak
    // and is really a producer outrunning a consumer.
    //
    // Waiting for the acknowledgement makes the rate self-adjusting: fast
    // machines send often, slow ones send less, and neither builds a queue.
    // Deliberately placed *before* lastSent is updated, so a frame skipped
    // this way still counts as novel and is picked up on the next tick rather
    // than being lost.
    if (cap.inflight) return;
    cap.inflight = true;
    // If an acknowledgement never arrives - a server-side error, a dropped
    // websocket - capture must not wedge for the rest of the session.
    cap.inflightSince = Date.now();

    cap.lastSent = cur;
    var s = Math.min(1, SEND_MAX / Math.max(r.w, r.h));
    var out = cap.out;
    out.width = Math.max(8, Math.round(r.w * s));
    out.height = Math.max(8, Math.round(r.h * s));
    out.getContext("2d").drawImage(cap.video, r.x, r.y, r.w, r.h, 0, 0, out.width, out.height);

    cap.seq++;
    // PNG, not JPEG: recognition matches templates pixel by pixel, and JPEG
    // ringing around piece edges is exactly the kind of noise it would trip on.
    Shiny.setInputValue(
      cap.frameInput,
      { img: out.toDataURL("image/png"), seq: cap.seq },
      { priority: "event" }
    );
  }

  function startLoop() {
    if (!cap || cap.timer) return;
    var ms = 1200;
    var input = el(cap.intervalInput);
    if (input && input.value) ms = Math.max(400, parseFloat(input.value) * 1000);
    cap.timer = setInterval(tick, ms);
    cap.intervalMs = ms;
    status("capturing", "");
  }

  function stopLoop() {
    if (cap && cap.timer) {
      clearInterval(cap.timer);
      cap.timer = null;
    }
  }

  function teardown(message) {
    stopLoop();
    if (cap && cap.stream) {
      cap.stream.getTracks().forEach(function (t) {
        t.stop();
      });
    }
    status("stopped", message || "");
    cap = null;
  }

  // ---- wiring ------------------------------------------------------------

  function start(root) {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
      Shiny.setInputValue(
        root.dataset.statusInput,
        {
          state: "error",
          message:
            "This browser cannot share a screen with the page. Screen capture needs " +
            "a recent Chrome, Edge or Firefox served over HTTPS or from localhost.",
          nonce: Math.random()
        },
        { priority: "event" }
      );
      return;
    }

    // Must be called straight from the click: getDisplayMedia requires a user
    // gesture, so this cannot be triggered by a message from the server.
    navigator.mediaDevices
      .getDisplayMedia({ video: { frameRate: 4 }, audio: false })
      .then(function (stream) {
        var video = el(root.dataset.video);
        video.srcObject = stream;
        video.play();

        cap = {
          stream: stream,
          video: video,
          preview: el(root.dataset.canvas),
          work: document.createElement("canvas"),
          out: document.createElement("canvas"),
          frameInput: root.dataset.frameInput,
          statusInput: root.dataset.statusInput,
          intervalInput: root.dataset.intervalInput,
          region: null,
          prev: null,
          lastSent: null,
          previewScale: 1,
          timer: null,
          seq: 0
        };
        cap.work.width = WORK;
        cap.work.height = WORK;

        stream.getVideoTracks()[0].addEventListener("ended", function () {
          teardown("screen sharing ended");
        });

        video.addEventListener(
          "loadedmetadata",
          function () {
            drawPreview();
            bindRegionPicker();
            status("ready", "drag on the preview to mark the board");
            startLoop();
          },
          { once: true }
        );
      })
      .catch(function (err) {
        Shiny.setInputValue(
          root.dataset.statusInput,
          {
            state: "error",
            message: "Screen sharing was not started (" + (err && err.name) + ").",
            nonce: Math.random()
          },
          { priority: "event" }
        );
      });
  }

  document.addEventListener("click", function (e) {
    if (!e.target.closest) return;
    var root = e.target.closest(".cv-capture");
    if (!root) return;

    if (e.target.closest(".cv-cap-start")) {
      if (cap) teardown("restarting");
      start(root);
    } else if (e.target.closest(".cv-cap-stop")) {
      if (cap) teardown("stopped by you");
    } else if (e.target.closest(".cv-cap-whole")) {
      if (cap) {
        cap.region = null;
        cap.prev = null;
        cap.lastSent = null;
        drawPreview();
        status(cap.timer ? "capturing" : "ready", "using the whole shared area");
      }
    } else if (e.target.closest(".cv-cap-shot")) {
      // Force one frame through regardless of the change filter.
      if (cap) {
        cap.lastSent = null;
        tick();
      }
    }
  });

  // The server has finished with a frame and is ready for the next one.
  if (window.Shiny && Shiny.addCustomMessageHandler) {
    Shiny.addCustomMessageHandler("tanmai-capture-ack", function () {
      if (cap) cap.inflight = false;
    });
  }

  // The interval slider takes effect without restarting the share.
  document.addEventListener("change", function (e) {
    if (!cap || !e.target.id || e.target.id !== cap.intervalInput) return;
    stopLoop();
    startLoop();
  });
})();
