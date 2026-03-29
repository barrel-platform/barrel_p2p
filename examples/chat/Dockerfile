FROM erlang:26-alpine AS builder

RUN apk add --no-cache git

WORKDIR /build

# Copy mycelium library first
COPY src /build/mycelium/src
COPY include /build/mycelium/include
COPY rebar.config /build/mycelium/rebar.config

# Copy chat example
WORKDIR /build/chat
COPY examples/chat/src ./src
COPY examples/chat/config ./config
COPY examples/chat/rebar.config .

# Create checkouts symlink for mycelium
RUN mkdir -p _checkouts && ln -s /build/mycelium _checkouts/mycelium

# Fetch mycelium dependencies (hlc)
WORKDIR /build/mycelium
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
ENV COOKIE=mycelium_chat
ENV CONTACT_NODES=

# Expose mycelium port
EXPOSE 9100

COPY examples/chat/scripts/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["foreground"]
