# syntax=docker/dockerfile:1.7

# Medusa release to scaffold. The CI workflow passes the version tracked in
# `.medusa-version` via --build-arg. create-medusa-app and every @medusajs/*
# package are pinned to this exact version.
ARG MEDUSA_VERSION=2.18.0
ARG BUN_IMAGE=oven/bun:1-alpine

###############################################################################
# Builder
###############################################################################
FROM ${BUN_IMAGE} AS builder

ARG MEDUSA_VERSION

# Bun is already the base image. node + npm are added because create-medusa-app
# drives the scaffold install through npm, and `medusa build` runs under node
# via the `medusa` bin's shebang. Bun manages all dependencies and orchestrates
# the build.
RUN apk add --no-cache nodejs npm git python3 build-base

# ---------------------------------------------------------------------------
# Route ALL package fetches through the npmmirror registry mirror.
# GitHub Actions runners share egress IPs that npmjs.org aggressively rate
# limits (HTTP 429), which killed every prior build. npmmirror is a public,
# high-availability mirror that does not 429 CI traffic. Configured for both
# npm/npx (env var) and Bun (bunfig.toml in HOME, picked up by every
# `bun install` regardless of WORKDIR).
# ---------------------------------------------------------------------------
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    NPM_CONFIG_FETCH_RETRIES=8 \
    NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=10000 \
    NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=120000 \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false

RUN printf '[install]\nregistry = "https://registry.npmmirror.com"\n' > /root/.bunfig.toml

# create-medusa-app performs a full monorepo `npm install --legacy-peer-deps`
# during scaffolding that we delete immediately afterwards (we detach the
# backend and use Bun for everything). Shim `npm install` to a no-op so
# scaffolding is fast and never hits the network for the throwaway install.
RUN printf '#!/bin/sh\ncase "$1" in install|ci|i) echo "[npm-shim] skipping %s (will use bun install later)"; exit 0 ;; esac; exec /usr/bin/npm "$@"\n' \
      > /usr/local/bin/npm \
 && chmod +x /usr/local/bin/npm

# CI=1 keeps create-medusa-app non-interactive (skips the Claude Code prompt).
# A placeholder DATABASE_URL keeps medusa-config happy during the build; no
# database is contacted at build time (--skip-db is passed below).
ENV CI=1
ENV DATABASE_URL="postgres://medusa:medusa@localhost:5432/medusa"

WORKDIR /scaffold

# Scaffold a fresh Medusa project at the pinned version. `npx` runs
# create-medusa-app under node; `yes ""` answers the optional Next.js starter
# prompt with the default (no). --skip-db avoids any database interaction,
# --no-browser skips opening a browser. Retry loop catches transient registry
# / network failures (429, 5xx, socket resets, flaky git clone).
RUN set -eu; \
    for i in 1 2 3; do \
      if yes "" | npx --yes create-medusa-app@${MEDUSA_VERSION} server \
          --directory-path /scaffold \
          --skip-db \
          --no-browser \
          --use-npm \
          --version ${MEDUSA_VERSION}; then \
        break; \
      fi; \
      echo "create-medusa-app attempt $i failed, retrying..."; \
      rm -rf /scaffold/* /scaffold/.[!.]* 2>/dev/null || true; \
      sleep $((i * 20)); \
    done

# After scaffolding we no longer need the install shim. Restore real npm so
# downstream tools that happen to shell out to npm still work.
RUN rm -f /usr/local/bin/npm

# The template is a pnpm/turbo monorepo. Detach the backend from it so Bun can
# manage the backend as a standalone project (no workspace hoisting, no
# pnpm-specific config to translate).
WORKDIR /scaffold/server
RUN rm -f package.json pnpm-workspace.yaml package-lock.json yarn.lock pnpm-lock.yaml \
 && rm -rf apps/*/node_modules

WORKDIR /scaffold/server/apps/backend

# Install all (dev + prod) dependencies with Bun (via npmmirror). Light retry
# for transient network blips; bun install is idempotent.
RUN for i in 1 2 3; do \
      if bun install; then break; fi; \
      echo "bun install (backend) attempt $i failed, sleeping $((i*10))s ..."; \
      sleep $((i * 10)); \
    done

# Build backend + admin dashboard. `bun run build` invokes `medusa build`, which
# runs under node through the CLI's shebang. Retry once: the admin dashboard
# build downloads packages from npm on first build and can transiently 429.
RUN bun run build || (sleep 30 && bun run build)

# `.medusa/server` is a self-contained production app: the build copies the
# backend's package.json into it. Install only production deps there with Bun,
# then strip non-runtime files (type declarations, source maps, TypeScript
# sources, tests, docs, changelogs) to shrink the final image.
WORKDIR /scaffold/server/apps/backend/.medusa/server
RUN for i in 1 2 3; do \
      if bun install --production; then break; fi; \
      echo "bun install (server production) attempt $i failed, sleeping $((i*10))s ..."; \
      sleep $((i * 10)); \
    done \
 && find node_modules -type f \( \
      -name '*.md' -o -name '*.markdown' \
      -o -name '*.d.ts' -o -name '*.d.cts' -o -name '*.d.mts' \
      -o -name '*.map' -o -name '*.ts' -o -name '*.cts' -o -name '*.mts' \
      -o -name 'LICENSE*' -o -name 'LICENCE*' -o -name 'CHANGELOG*' \
      -o -name 'HISTORY*' -o -name 'AUTHORS*' -o -name 'NOTICE*' \
      -o -name '*.tgz' -o -name '*.tar.gz' -o -name '.npmignore' \
      -o -name '.editorconfig' -o -name '.eslintrc*' -o -name '.prettierrc*' \
      -o -name 'yarn.lock' -o -name 'package-lock.json' -o -name 'pnpm-lock.yaml' \
    \) -delete 2>/dev/null || true \
 && find node_modules -type d \( \
      -name '__tests__' -o -name '__test__' -o -name '__mocks__' \
      -o -name 'tests' -o -name 'test' -o -name 'docs' -o -name 'doc' \
      -o -name 'examples' -o -name 'example' -o -name 'coverage' \
      -o -name '.github' -o -name '.turbo' -o -name '.cache' \
    \) -prune -exec rm -rf {} + 2>/dev/null || true \
 && rm -rf node_modules/.cache

###############################################################################
# Runtime (Bun)
###############################################################################
FROM ${BUN_IMAGE} AS runtime

ENV NODE_ENV=production
ENV PORT=9000

WORKDIR /app

# Run as a non-root user.
RUN addgroup -S medusa && adduser -S medusa -G medusa

# Copy the self-contained production build. Running `medusa start` from here
# mirrors the documented `cd .medusa/server && medusa start` flow. `bunx` runs
# the `medusa` CLI under Bun (no node required at runtime).
COPY --from=builder --chown=medusa:medusa /scaffold/server/apps/backend/.medusa/server ./

USER medusa

EXPOSE 9000

# No secrets are baked into the image. Supply at runtime, e.g.:
#   DATABASE_URL, JWT_SECRET, COOKIE_SECRET, REDIS_URL,
#   STORE_CORS, ADMIN_CORS, AUTH_CORS
# Run migrations once with:
#   docker run --rm <image> bunx medusa db:migrate
CMD ["bunx", "medusa", "start"]
