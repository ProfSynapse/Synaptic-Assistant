# Dockerfile — Multi-stage Elixir release build for Railway deployment.
#
# Stage 1: Build (compile deps + release)
# Stage 2: Runtime (minimal Ubuntu image with the release binary)
#
# Build: docker build -t assistant .
# Run:   docker run -p 4000:4000 --env-file .env assistant

# --- Build Stage ---
ARG BUILDER_IMAGE="hexpm/elixir:1.19.5-erlang-28.3.3-ubuntu-noble-20260210.1"
ARG RUNNER_IMAGE="ubuntu:noble-20260210.1"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Prepare build directory
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before we compile dependencies
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application code and remaining config (config.yaml, prompts/, runtime.exs)
COPY config config
COPY priv priv
COPY lib lib
COPY assets assets

# Compile the release
RUN mix compile

# Build assets (Tailwind CSS)
RUN mix assets.deploy

# Build the release
RUN mix release

# --- Runtime Stage ---
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy the release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/assistant ./

USER nobody

# Run migrations on startup, then start the server
CMD ["/bin/sh", "-c", "bin/assistant eval 'Assistant.Release.migrate' && bin/assistant start"]
