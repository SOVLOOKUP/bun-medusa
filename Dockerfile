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
# Two mitigations against npm registry 429 Too Many Requests on CI runners:
#
# 1) Install a `npm` PATH shim that makes `npm install` / `npm ci` a no-op.
#    create-medusa-app performs a full monorepo `npm install --legacy-peer-deps`
#    during scaffolding, but we delete every node_modules right after (we
#    detach the backend and use Bun for everything). Running that install is
#    pure waste and is the primary 429 trigger.
#
# 2) Set aggressive npm fetch retries as a safety net for anything that still
#    calls npm (e.g. `npx` itself resolving the create-medusa-app tarball).
# ---------------------------------------------------------------------------
ENV NPM_CONFIG_FETCH_RETRIES=12 \
    NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=15000 \
    NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=180000 \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    # Bun install retries against transient npm 429s on shared CI egress IPs.
    # (Bun 1.2+ honours BUN_INSTALL_RETRY_*; defaults are 2/250ms, too small.)
    BUN_INSTALL_RETRY_COUNT=20 \
    BUN_INSTALL_RETRY_DELAY=5000

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

# Install all (dev + prod) dependencies with Bun. Outer retry loop for the
# shared-CI-egress 429 scenario: even with BUN_INSTALL_RETRY_*, bun sometimes
# exhausts its retries on one resolution; we back off and re-run `bun install`
# (it is idempotent — everything already cached is skipped).
RUN for i in 1 2 3 4 5; do \
      if bun install; then break; fi; \
      echo "bun install (backend) attempt $i failed, sleeping $((i*15))s ..."; \
      sleep $((i * 15)); \
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
RUN for i in 1 2 3 4 5; do \
      if bun install --production; then break; fi; \
      echo "bun install (server production) attempt $i failed, sleeping $((i*15))s ..."; \
      sleep $((i * 15)); \
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
