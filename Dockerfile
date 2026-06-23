# =============================================================================
# Stage 1: Node binary (copied into other stages)
# =============================================================================
FROM node:24-alpine AS node

# =============================================================================
# Stage 2: Builder — installs all deps, compiles Ruby gems, precompiles assets
# =============================================================================
FROM ruby:3.4.4-alpine3.21 AS builder

ARG NODE_VERSION="24.13.0"
ARG PNPM_VERSION="10.2.0"
ARG BUNDLE_WITHOUT="development:test"
ARG RAILS_ENV=production
ARG NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider"

ENV NODE_VERSION=${NODE_VERSION} \
    PNPM_VERSION=${PNPM_VERSION} \
    BUNDLE_WITHOUT=${BUNDLE_WITHOUT} \
    BUNDLER_VERSION=2.5.16 \
    RAILS_SERVE_STATIC_FILES=true \
    RAILS_ENV=${RAILS_ENV} \
    NODE_OPTIONS=${NODE_OPTIONS} \
    BUNDLE_PATH="/gems" \
    PNPM_HOME="/root/.local/share/pnpm" \
    PATH="/root/.local/share/pnpm:$PATH"

# Install system deps
RUN apk update && apk add --no-cache \
    openssl tar build-base tzdata \
    postgresql-dev postgresql-client \
    git curl xz \
    musl ruby-full ruby-dev gcc make \
    musl-dev openssl-dev g++ linux-headers vips \
  && gem install bundler -v "$BUNDLER_VERSION"

# Copy Node binary from node stage
COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install -g pnpm@${PNPM_VERSION}

WORKDIR /app

# Install Ruby gems (cached layer — only re-runs if Gemfile changes)
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local force_ruby_platform true \
 && bundle config set without 'development test' \
 && bundle install -j 4 -r 3

# Install Node packages (cached layer — only re-runs if package.json changes)
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Copy full source
COPY . /app

# Create log dir to prevent startup crash when RAILS_LOG_TO_STDOUT=false
RUN mkdir -p /app/log

# Precompile assets
RUN SECRET_KEY_BASE=precompile_placeholder \
    RAILS_LOG_TO_STDOUT=enabled \
    bundle exec rake assets:precompile

# Stamp the git SHA
RUN git rev-parse HEAD > /app/.git_sha || echo "no-git" > /app/.git_sha

# Clean up to reduce image size
RUN rm -rf /gems/ruby/3.4.0/cache/*.gem \
 && find /gems/ruby/3.4.0/gems/ \( -name "*.c" -o -name "*.o" \) -delete \
 && rm -rf .git spec node_modules tmp/cache

# =============================================================================
# Stage 3: Final runtime — lean image, only what's needed to run
# =============================================================================
FROM ruby:3.4.4-alpine3.21 AS runtime

ARG RAILS_ENV=production
ARG BUNDLE_WITHOUT="development:test"

ENV RAILS_ENV=${RAILS_ENV} \
    BUNDLER_VERSION=2.5.16 \
    BUNDLE_WITHOUT=${BUNDLE_WITHOUT} \
    BUNDLE_FORCE_RUBY_PLATFORM=1 \
    BUNDLE_PATH="/gems" \
    RAILS_SERVE_STATIC_FILES=true \
    EXECJS_RUNTIME=Disabled

# Minimal runtime deps only
RUN apk update && apk add --no-cache \
    build-base openssl tzdata \
    postgresql-client imagemagick git vips \
  && gem install bundler -v "$BUNDLER_VERSION"

# Copy Node binary (needed for runtime asset serving in some configs)
COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

# Copy compiled gems and app from builder
COPY --from=builder /gems/ /gems/
COPY --from=builder /app /app
COPY --from=builder /app/.git_sha /app/.git_sha

WORKDIR /app

# Entrypoint waits for postgres, then runs db:chatwoot_prepare, then starts server
COPY docker/entrypoints/rails.sh /usr/local/bin/rails-entrypoint.sh
RUN chmod +x /usr/local/bin/rails-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["rails-entrypoint.sh"]
CMD ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
	
