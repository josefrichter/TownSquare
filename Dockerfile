# Multi-stage build for a self-contained OTP release.
#
# The router bakes the widget path at compile time (Path.expand("../../public",
# __DIR__) → /app/public, since the source lives at /app/lib/town_square_beam).
# The runtime stage therefore puts public/ back at /app/public so it resolves.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250520-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# App sources. public/ is copied so the compile-time @public_dir (/app/public)
# is a real path and so the assets travel with the build.
COPY lib lib
COPY public public
RUN mix compile

# Runtime config is read on boot, not at build time.
COPY config/runtime.exs config/

RUN mix release

# --- runtime image --------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

# The release goes to /app (so /app/bin/town_square_beam), and the widget assets
# to /app/public to match the path baked into the router at compile time.
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/town_square_beam ./
COPY --from=builder --chown=nobody:root /app/public ./public

USER nobody

# PORT and TOWNSQUARE_* are read by config/runtime.exs at boot.
ENV PORT=8788
EXPOSE 8788

CMD ["/app/bin/town_square_beam", "start"]
