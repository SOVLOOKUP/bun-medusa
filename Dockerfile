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

# CI=1 keeps create-medusa-app non-interactive (skips the Claude Code prompt).
# A placeholder DATABASE_URL keeps medusa-config happy during the build; no
# database is contacted at build time (--skip-db is passed below).
ENV CI=1
ENV DATABASE_URL="postgres://medusa:medusa@localhost:5432/medusa"

WORKDIR /scaffold

# Scaffold a fresh Medusa project at the pinned version. `npx` runs
# create-medusa-app under node; `yes ""` answers the optional Next.js starter
# prompt with the default (no). --skip-db avoids any database interaction,
# --no-browser skips opening a browser.
RUN yes "" | npx --yes create-medusa-app@${MEDUSA_VERSION} server \
      --directory-path /scaffold \
      --skip-db \
      --no-browser \
      --use-npm \
      --version ${MEDUSA_VERSION}

# The template is a pnpm/turbo monorepo. Detach the backend from it so Bun can
# manage the backend as a standalone project (no workspace hoisting, no
# pnpm-specific config to translate).
WORKDIR /scaffold/server
RUN rm -f package.json pnpm-workspace.yaml package-lock.json yarn.lock pnpm-lock.yaml \
 && rm -rf apps/*/node_modules

WORKDIR /scaffold/server/apps/backend

# Install all (dev + prod) dependencies with Bun.
RUN bun install

# Build backend + admin dashboard. `bun run build` invokes `medusa build`, which
# runs under node through the CLI's shebang.
RUN bun run build

# `.medusa/server` is a self-contained production app: the build copies the
# backend's package.json into it. Install only production deps there with Bun,
# then strip non-runtime files (type declarations, source maps, TypeScript
# sources, tests, docs, changelogs) to shrink the final image.
WORKDIR /scaffold/server/apps/backend/.medusa/server
RUN bun install --production \
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
