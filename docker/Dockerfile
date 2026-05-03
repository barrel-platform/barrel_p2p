# Multi-stage Dockerfile for Mycelium integration tests
# Target: OTP 28+ (Erlang 28)

ARG ERLANG_VERSION=28
FROM erlang:${ERLANG_VERSION}-alpine AS builder

# Install build dependencies. cmake + a C/C++ toolchain are needed by
# rocksdb, derp, and instrument NIFs. perl/linux-headers are required
# by derp's bundled boringssl.
RUN apk add --no-cache \
    git \
    bash \
    build-base \
    cmake \
    ninja \
    perl \
    linux-headers \
    lz4-dev \
    snappy-dev \
    libsodium-dev

WORKDIR /app

# Copy rebar configs first for better layer caching
COPY rebar.config rebar.lock* ./

# Fetch dependencies. All deps are public; no auth needed.
RUN rebar3 get-deps

# Copy source code
COPY config/ config/
COPY include/ include/
COPY src/ src/
COPY test/ test/

# Some deps (notably rocksdb) have a `git submodule update` compile
# pre-hook. Without a .git anywhere in the parent chain, the hook
# aborts. An empty repo at /app makes the no-op submodule update
# succeed without polluting the source tree.
RUN git init -q .

# Compile with test profile (includes test dependencies)
RUN rebar3 as test compile

# ============================================
# Runtime stage
# ============================================
FROM erlang:${ERLANG_VERSION}-alpine AS runtime

RUN apk add --no-cache bash netcat-openbsd iputils

WORKDIR /app

# Copy compiled artifacts from builder
COPY --from=builder /app/_build /app/_build
COPY --from=builder /app/rebar.config /app/
COPY --from=builder /app/config /app/config
COPY --from=builder /app/include /app/include
COPY --from=builder /app/src /app/src
COPY --from=builder /app/test /app/test

# Copy scripts and test configs
COPY docker/scripts/ /app/scripts/
COPY docker/test.config /app/docker/test.config
COPY docker/auth-test.config /app/docker/auth-test.config
COPY docker/circuit-test.config /app/docker/circuit-test.config
RUN chmod +x /app/scripts/*.sh

# Create data directory for keys
RUN mkdir -p /app/data/keys/trusted && chmod 700 /app/data/keys

# Environment
ENV ERLANG_COOKIE=mycelium_test_cookie
ENV NODE_ROLE=member
ENV NODE_NAME=node@localhost

# Health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
    CMD /app/scripts/health_check.sh

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
