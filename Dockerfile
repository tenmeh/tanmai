# tanmai: chess screenshot -> best move.
#
# Everything the app needs at runtime is baked in here, because container
# filesystems are ephemeral and often read-only: the chess engine comes from
# apt rather than a runtime download, and every piece-set template library is
# built during the image build so a cold start is immediately ready.

# One base image for both stages. This is not tidiness - it is the fix for a
# real outage. lc0 used to be built on debian:bookworm-slim and the finished
# binary copied into the Ubuntu-based runtime, which worked only for as long as
# the two distributions happened to ship compatible shared libraries. When the
# bookworm base was refreshed, lc0 kept building and passing its own smoke test
# in the build stage, then silently failed to start in the runtime stage: the
# image build died thirty seconds later on an unrelated-looking assertion deep
# in an R script, with lc0's actual error swallowed by the subprocess.
#
# Building the binary against the very libraries it will run against removes
# the entire class of problem, and sharing one ARG means the two stages cannot
# drift apart again.
ARG R_IMAGE=rocker/r-ver:4.6.1

# ---------------------------------------------------------------------------
# Stage 1: lc0, the engine behind the Blunder Radar's human model.
#
# There is no official Linux binary for lc0 - the project's releases are
# Windows and Android only, and Debian's `leela-zero` package is the unrelated
# Go engine - so it has to be built from source. Only the finished binary is
# copied into the runtime image, leaving the ~1 GB of build toolchain behind.
# ---------------------------------------------------------------------------
FROM ${R_IMAGE} AS lc0build

ARG LC0_VERSION=v0.32.1

RUN apt-get update -o Acquire::Retries=5 \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=5 \
        build-essential ca-certificates git meson ninja-build \
        pkg-config python3 zlib1g-dev libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --recurse-submodules --depth 1 --branch "${LC0_VERSION}" \
        https://github.com/LeelaChessZero/lc0.git /src

WORKDIR /src

# CPU/BLAS only. ispc, onnx, cuda and opencl are switched off: they need
# toolchains or hardware this image will never have. That costs nothing here
# because the radar runs the network at `go nodes 1` - a single forward pass
# per query, where raw throughput is irrelevant.
RUN meson setup build --buildtype=release \
        -Dgtest=false -Dispc=false -Donnx=false \
        -Dblas=true -Dopenblas=true \
        -Ddnnl=false -Dopencl=false -Dcudnn=false \
    && ninja -C build lc0 \
    && ./build/lc0 --help > /dev/null

# Maia weights, fetched here so the runtime stage needs no network access.
# Every network CSSLab published - 1100 to 1900 in hundreds - so each stop
# on the rating slider is an actual trained model rather than the nearest
# of three. They are about 7 MB each; the whole set is under 70 MB.
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1100.pb.gz /weights/maia-1100.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1200.pb.gz /weights/maia-1200.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1300.pb.gz /weights/maia-1300.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1400.pb.gz /weights/maia-1400.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1500.pb.gz /weights/maia-1500.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1600.pb.gz /weights/maia-1600.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1700.pb.gz /weights/maia-1700.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1800.pb.gz /weights/maia-1800.pb.gz
ADD https://github.com/CSSLab/maia-chess/raw/master/maia_weights/maia-1900.pb.gz /weights/maia-1900.pb.gz

# Widening the permissions is not cosmetic: ADD from a URL leaves files 0600
# (root-only), so lc0 could not read them if the container runs as a non-root
# uid, which Cloud Run may do. COPY --from preserves the mode, so fixing it
# here is what makes the runtime stage safe.
#
# Done as a separate RUN rather than `ADD --chmod=`, which is a BuildKit-only
# extension: Google Cloud Build still invokes the legacy docker builder, where
# it fails outright with "the --chmod option requires BuildKit". A plain chmod
# behaves identically under both builders.
RUN chmod 0644 /weights/*.pb.gz

# ---------------------------------------------------------------------------
# Stage 2: the app.
# ---------------------------------------------------------------------------
FROM ${R_IMAGE}

# System libraries:
#   libmagick++    - the magick package
#   librsvg2       - rasterizes the piece SVGs (magick's own SVG delegate is
#                    unreliable, hence the rsvg package)
#   libnode        - the V8 package, which runs chess.js for rules/SAN
#   stockfish      - the engine; installing it here avoids fetching a binary
#                    onto a filesystem that may be read-only
# Acquire::Retries guards against transient mirror failures, which otherwise
# fail the whole build over one unreachable .deb out of ~150.
RUN apt-get update -o Acquire::Retries=5 \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=5 \
        libmagick++-dev \
        librsvg2-dev \
        libnode-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        curl \
        stockfish \
        libopenblas0 \
    && rm -rf /var/lib/apt/lists/*

# Debian installs the engine into /usr/games, which is not on the default PATH
# of a non-interactive session.
ENV PATH="/usr/games:${PATH}"

# lc0 and the Maia networks, from the build stage above. TANMAI_MAIA_DIR
# pins where maia_dir() looks, rather than letting it resolve under the user
# cache - that depends on HOME, which is not dependable in a container that
# may run as an arbitrary uid.
COPY --from=lc0build /src/build/lc0 /usr/local/bin/lc0
COPY --from=lc0build /weights/ /opt/maia/
ENV TANMAI_MAIA_DIR=/opt/maia

# Prove the binary runs *here*, not merely where it was compiled. The build
# stage already smoke-tests it, which is exactly why the previous failure was
# so obscure: lc0 was fine in the stage that built it and unable to start in
# the stage that used it. Without this line the first symptom is an R
# assertion timing out thirty seconds later, with lc0's real complaint - a
# missing or mismatched shared library - written to a stderr that processx
# captures and discards. `ldd` is printed alongside so the next such failure
# names the library instead of hiding it.
RUN ldd /usr/local/bin/lc0 || true \
    && lc0 --help > /dev/null \
    && echo "lc0 runs in the runtime image"

WORKDIR /srv/tanmai

# renv.lock is the single source of truth for R package versions - the same
# file `renv::snapshot()` maintains for local dev - copied in on its own so
# this layer only rebuilds when a dependency actually changes, not on every
# source edit.
COPY renv.lock renv.lock

# restore() installs the exact locked versions directly into R's normal
# site-library (not renv's usual project-private renv/library folder, via
# the explicit `library` argument below). This is deliberate: renv isolates
# an active project's library and - critically - hides the plain
# site-library once a project is "activated" but not yet in sync, which is
# exactly what broke `library(tanmai)` here previously (tanmai
# itself is installed by a plain R CMD INSTALL below, into that same plain
# site-library, bypassing renv entirely). Using renv purely as a one-shot,
# build-time installer sidesteps that: nothing here ever activates renv as a
# project, so .Rprofile and renv/activate.R are never needed in the image
# (see .dockerignore) and there is no isolation to fight with at runtime.
RUN Rscript -e "install.packages('renv', repos = 'https://cloud.r-project.org')" \
    && Rscript -e "renv::restore(project = '.', library = '/usr/local/lib/R/site-library', prompt = FALSE)"

COPY . .

RUN R CMD INSTALL --no-multiarch --with-keep.source . \
    && rm -rf /tmp/downloaded_packages

# Pre-build every piece-set template library. Without this the app would fetch
# ~38 sets from lichess.org on first use and lose them again on the next cold
# start. Failing softly keeps the image buildable if lichess is unreachable -
# the bundled cburnett set always works.
RUN Rscript -e "library(tanmai); \
      ready <- tryCatch(tanmai:::setup_piece_sets(), error = function(e) { \
        message('piece-set prefetch skipped: ', conditionMessage(e)); logical(0) }); \
      message(sprintf('piece sets baked in: %d', sum(ready)))"

# Fail the build rather than ship an image whose engine or art is missing.
# The human model is checked by actually running it: lc0 can be present and
# still be unusable (wrong BLAS, unreadable weights), and a Blunder Radar that
# silently degrades to "human model unavailable" in production is exactly the
# failure this stage exists to catch. Asserting on a real policy query - the
# probabilities must be non-empty and sum to 1 - is what makes it meaningful.
RUN Rscript -e "library(tanmai); \
      stopifnot(!is.null(tanmai:::find_local_engine())); \
      sets <- tanmai:::available_piece_sets(); \
      message(sprintf('engine: %s', tanmai:::find_local_engine())); \
      message(sprintf('piece sets available: %d', length(sets))); \
      stopifnot(length(sets) >= 1); \
      message(sprintf('lc0: %s', tanmai:::find_lc0())); \
      stopifnot(!is.null(tanmai:::find_lc0())); \
      w <- vapply(tanmai:::MAIA_RATINGS, tanmai:::maia_weights_path, character(1)); \
      message(sprintf('maia networks baked in: %d/%d', sum(file.exists(w)), length(w))); \
      stopifnot(all(file.exists(w))); \
      sess <- tanmai:::maia_session_start(1500); \
      stopifnot(!is.null(sess)); \
      pol <- tanmai:::human_move_probabilities(sess, \
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'); \
      tanmai:::maia_session_stop(sess); \
      message(sprintf('maia-1500 policy: %d moves, top %s at %.1f%%', \
        nrow(pol), pol\$move[1], 100 * pol\$prob[1])); \
      stopifnot(nrow(pol) == 20, abs(sum(pol\$prob) - 1) < 0.02)"

# Cloud Run (and most hosts) inject the port to listen on.
ENV PORT=8080
EXPOSE 8080

CMD ["Rscript", "/srv/tanmai/app.R"]
