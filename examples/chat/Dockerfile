FROM erlang:26-alpine AS builder

RUN apk add --no-cache git

WORKDIR /build

# Copy barrel_p2p library first
COPY src /build/barrel_p2p/src
COPY include /build/barrel_p2p/include
COPY rebar.config /build/barrel_p2p/rebar.config

# Copy chat example
WORKDIR /build/chat
COPY examples/chat/src ./src
COPY examples/chat/config ./config
COPY examples/chat/rebar.config .

# Create checkouts symlink for barrel_p2p
RUN mkdir -p _checkouts && ln -s /build/barrel_p2p _checkouts/barrel_p2p

# Fetch barrel_p2p dependencies (hlc)
WORKDIR /build/barrel_p2p
RUN rebar3 get-deps

# Build chat release
WORKDIR /build/chat
RUN rebar3 as prod release

# Runtime image
FROM erlang:26-alpine

RUN apk add --no-cache bash

WORKDIR /app

COPY --from=builder /build/chat/_build/prod/rel/chat /app

# Default environment
ENV NODE_NAME=chat
ENV COOKIE=barrel_p2p_chat
ENV CONTACT_NODES=

# Expose barrel_p2p port
EXPOSE 9100

COPY examples/chat/scripts/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["foreground"]
