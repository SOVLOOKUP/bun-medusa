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
ARG MEDUSA_VERSION=2.18.0
ARG STARTER_REPO=https://github.com/medusajs/medusa-starter-default.git
RUN git clone --depth 1 "$STARTER_REPO" /app/medusa && \
    rm -rf /app/medusa/.git

WORKDIR /app/medusa

# Fix CJS/ESM conflict in medusa-config.ts (same fix as production image)
RUN sed -i 's/module\.exports = defineConfig/export default defineConfig/' medusa-config.ts

# Inject the `admin:` block + http.port fallback into medusa-config.ts.
#
# admin.vite is a FUNCTION (config) => config and applies four fixes:
#
#   (A) allowedHosts=true / host=true — accept any Host header and listen
#       on 0.0.0.0 (prevents 403 "Blocked request" behind a reverse proxy).
#   (B) server.fs.strict=false + explicit /app/medusa entries in fs.allow —
#       Vite's i18n virtual module emits imports like
#       `import "/app/medusa/src/admin/i18n/index.ts"` with a leading slash
#       from a \0-prefixed virtual importer.  That combination confuses
#       Vite resolveId's "fs path vs URL path" heuristic into the wrong
#       branch, and/or fs.strict rejects it at serve-time, producing
#       "Failed to resolve import ... Does the file exist?" even though
#       the file is there on disk.  Disabling strict + explicit allow
#       unblocks both the resolve and serve stages.
#   (C) server.hmr — FIXED container port 9001 (never random).  Under
#       middlewareMode (admin-bundler embeds Vite in Express) Vite would
#       otherwise pick a random free port and tell the browser to connect
#       directly to it (which fails through the reverse proxy).
#       clientPort="" → @vite/client falls back to location.port (the
#       reverse-proxy HTTPS port the user actually visits — matches the
#       page URL).  path="/vite-hmr" lets the in-container shared-port
#       proxy (shared-port-proxy.ts on :9000) route WebSocket Upgrade
#       requests for /vite-hmr(*) to the HMR listener on :9001 while
#       everything else goes to Medusa itself on :9002.  Result: a SINGLE
#       external port (9000 / whatever the docker mapping maps it to)
#       carries HTTP admin/API traffic AND HMR WebSocket traffic.
#
# http.port=9002 fallback — PORT env var (set by entrypoint) takes
# precedence, but some code paths read the config value directly; make
# sure both agree so Medusa never tries to listen on the proxy's port 9000.
RUN if ! grep -q 'allowedHosts' medusa-config.ts; then \
    sed -i 's/projectConfig: {/admin: { vite: (config) => { config.server = config.server || {}; config.server.allowedHosts = true; config.server.host = true; config.server.fs = config.server.fs || {}; config.server.fs.strict = false; config.server.fs.allow = [...(config.server.fs.allow || []), "\/app\/medusa", "\/app\/medusa\/src"]; config.server.hmr = { port: 9001, clientPort: "", path: "\/vite-hmr" }; return config; } },\n  projectConfig: {/' medusa-config.ts; \
    fi && \
    if ! grep -qE 'http:\s*\{\s*$' medusa-config.ts >/dev/null 2>&1 || ! grep -q 'port:' medusa-config.ts >/dev/null 2>&1; then \
    sed -i 's/http: {/http: {\n    port: 9002,/' medusa-config.ts 2>/dev/null || true; \
    fi; \
    grep -q 'allowedHosts' medusa-config.ts && \
    echo "medusa-config.ts patched (allowedHosts + fs.strict/fs.allow + HMR :9001 + http.port :9002)"

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

COPY docker-entrypoint.sh  shared-port-proxy.ts  /usr/local/bin/
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
