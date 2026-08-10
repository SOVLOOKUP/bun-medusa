# Development image — clones medusa-starter-default at build time, installs
# full dependencies (including devDependencies), and exposes the dev server
# ports.  The entrypoint seeds an empty bind-mount on first boot so you can
# edit the source on the host with hot-reload inside the container.
#
# Build:  docker build -f Dockerfile.dev -t bun-medusa:dev .
#
FROM oven/bun:1.4-debian

# 替换为国内 Debian 源（清华 TUNA）
RUN sed -i 's|http://deb.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' \
        /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
    sed -i 's|http://deb.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' \
        /etc/apt/sources.list 2>/dev/null || true

# git clones the starter repo
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone the official Medusa v2 starter.
ARG MEDUSA_VERSION=2.18.0
ARG STARTER_REPO=https://github.com/medusajs/medusa-starter-default.git
RUN git clone --depth 1 "$STARTER_REPO" /app/medusa && \
    rm -rf /app/medusa/.git

# Keep a pristine copy of the source (without node_modules) that the
# entrypoint copies into the bind-mount on first boot.
RUN cp -a /app/medusa /app/medusa-seed

# Use the npm mirror to avoid rate-limiting (429) from npmjs.org.
ENV BUN_CONFIG_REGISTRY=https://registry.npmmirror.com

# Install ALL dependencies (including devDependencies) — dev mode needs
# TypeScript, the Vite admin dev server, etc.
WORKDIR /app/medusa
RUN bun install

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 9000 = backend API + admin dashboard (Vite dev server embedded)
EXPOSE 9000

ENTRYPOINT ["docker-entrypoint-dev.sh"]
CMD ["bun", "run", "dev"]
