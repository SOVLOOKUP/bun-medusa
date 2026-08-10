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

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 9000 = backend API + admin dashboard (Vite dev server embedded)
EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bun", "run", "dev"]
