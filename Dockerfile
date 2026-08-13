# Development image — clones medusa-starter-default at build time, installs
# full dependencies (including devDependencies), and exposes the dev server
# ports.  The entrypoint seeds an empty bind-mount on first boot so you can
# edit the source on the host with hot-reload inside the container.
#
# Build:  docker build -f Dockerfile.dev -t bun-medusa:dev .
#
FROM oven/bun:debian

# Install git + CA certificates (needed for HTTPS git clone)
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone the official Medusa v2 starter.
ARG MEDUSA_VERSION=2.19.0
ARG STARTER_REPO=https://github.com/medusajs/medusa-starter-default.git
RUN git clone --depth 1 "$STARTER_REPO" /app/medusa && \
    rm -rf /app/medusa/.git

WORKDIR /app/medusa

# Fix CJS/ESM conflict in medusa-config.ts (same fix as production image)
RUN sed -i 's/module\.exports = defineConfig/export default defineConfig/' medusa-config.ts

# Copy the admin Vite config overrides file into the starter source tree.
# docker-entrypoint.sh syncs this to the bind-mount on every boot and
# patches medusa-config.ts to import + use it as `admin.vite`.
# See admin-vite-overrides.ts for the full list of fixes (allowedHosts,
# fs.strict, HMR port, and the resolve-abs-fs-paths plugin that fixes the
# i18n virtual module's broken absolute-path import resolution).
COPY admin-vite-overrides.ts /app/medusa/admin-vite-overrides.ts

# Add migrate + create-admin scripts to package.json
RUN bun -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("package.json","utf-8"));p.scripts.start=p.scripts.start||"medusa start";p.scripts.migrate="medusa db:migrate";p.scripts["create-admin"]="medusa user -e $MEDUSA_ADMIN_EMAIL -p $MEDUSA_ADMIN_PASSWORD";fs.writeFileSync("package.json",JSON.stringify(p,null,2)+"\n")'

# Keep a pristine copy of the source (without node_modules) that the
# entrypoint copies into the bind-mount on first boot.
RUN cp -a /app/medusa /app/medusa-seed

# Use npmmirror to avoid 429 rate-limiting from npmjs.org
ENV BUN_CONFIG_REGISTRY=https://registry.npmmirror.com

# Install ALL dependencies (including devDependencies) — dev mode needs
# TypeScript, the Vite admin dev server, etc.
RUN bun install

# Patch @jridgewell/trace-mapping: return null result instead of throwing
# "column must be >= 0" when Bun passes negative column values during
# decorator stack trace resolution.  Idempotent with the entrypoint patch.
RUN sed -i 's/throw new Error(COL_GTR_EQ_ZERO)/return {source:null,line:null,column:null,name:null}/g' \
    node_modules/@jridgewell/trace-mapping/dist/trace-mapping.umd.js && \
    sed -i 's/throw new Error(LINE_GTR_ZERO)/return {source:null,line:null,column:null,name:null}/g' \
    node_modules/@jridgewell/trace-mapping/dist/trace-mapping.umd.js

COPY docker-entrypoint.sh  shared-port-proxy.ts  admin-vite-overrides.ts  /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Only ONE external port — 9000.  shared-port-proxy.ts sits here and
# dispatches:
#   • HTTP + non-HMR WebSocket   → container-internal 9002 (Medusa)
#   • WebSocket Upgrade /vite-hmr → container-internal 9001 (Vite HMR)
# The user needs a SINGLE docker port mapping (e.g. -p 9810:9000) and a
# SINGLE reverse-proxy location with WebSocket Upgrade headers passed
# through — no extra /vite-hmr location, no extra HMR port mapping.
EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bun", "run", "dev"]
