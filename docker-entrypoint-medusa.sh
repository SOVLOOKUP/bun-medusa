#!/bin/sh
# Runtime entrypoint for the Bun-based Medusa image.
#
# Two jobs:
#   1. If REDIS_URL is provided, patch /app/medusa-config.js so the four
#      memory-backed modules (cache, event_bus, workflows, locking) use real
#      Redis resolvers.  The patch is emitted into /app/node_modules (owned
#      by user `medusa`) because /app root is owned by root and not writable.
#   2. Append sslmode=disable&connect_timeout=30 to DATABASE_URL when those
#      query parameters are absent.  MikroORM/PG defaults otherwise try an
#      SSL handshake first and take 10 s to time out against a plain-TCP
#      Postgres, which is the overwhelmingly common case for self-hosted.
#
set -eu

# --- (2) Normalise DATABASE_URL -------------------------------------------
if [ -n "${DATABASE_URL:-}" ]; then
  case "$DATABASE_URL" in
    *sslmode=*)    : ;;  # already explicitly chosen
    *\?*)          DATABASE_URL="${DATABASE_URL}&sslmode=disable&connect_timeout=30" ;;
    *)             DATABASE_URL="${DATABASE_URL}?sslmode=disable&connect_timeout=30" ;;
  esac
  export DATABASE_URL
fi

# --- (1) Inject Redis modules when REDIS_URL is set -----------------------
if [ -n "${REDIS_URL:-}" ]; then
  PATCH_FILE="/app/node_modules/.medusa_redis_patch.cjs"
  # Use a heredoc quoted on the EOF marker so shell does not interpolate vars.
  cat > "$PATCH_FILE" <<'NODEEOF'
process.chdir('/app');
const ru = process.env.REDIS_URL;
if (!ru) { process.exit(0); }
const mods = {
  cache: {
    resolve: "@medusajs/cache-redis",
    options: { redisUrl: ru }
  },
  event_bus: {
    resolve: "@medusajs/event-bus-redis",
    options: { redisUrl: ru, workerOptions: { concurrency: 1 } }
  },
  workflows: {
    resolve: "@medusajs/workflow-engine-redis",
    options: { redisUrl: ru }
  },
  locking: {
    resolve: "@medusajs/medusa/locking",
    options: {
      providers: [
        {
          id: "locking-redis",
          resolve: "@medusajs/locking-redis",
          is_default: true,
          options: { redisUrl: ru }
        }
      ]
    }
  }
};
if (process.env.CACHE_REDIS_URL) {
  mods.caching = {
    resolve: "@medusajs/medusa/caching-redis",
    options: {
      providers: [
        {
          id: "caching-redis",
          resolve: "@medusajs/medusa/caching-redis",
          is_default: true,
          options: { redisUrl: process.env.CACHE_REDIS_URL }
        }
      ]
    }
  };
}
const fs = require('fs');
const newContent = `"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("@medusajs/framework/utils");
(0, utils_1.loadEnv)(process.env.NODE_ENV || 'development', process.cwd());
module.exports = (0, utils_1.defineConfig)({
    projectConfig: {
        databaseUrl: process.env.DATABASE_URL,
        http: {
            storeCors: process.env.STORE_CORS,
            adminCors: process.env.ADMIN_CORS,
            authCors: process.env.AUTH_CORS,
            jwtSecret: process.env.JWT_SECRET,
            cookieSecret: process.env.COOKIE_SECRET,
        }
    },
    modules: ` + JSON.stringify(mods, null, 4) + `
});
`;
fs.writeFileSync('/app/medusa-config.js', newContent);
console.log('[entrypoint] Redis modules injected: ' + Object.keys(mods).join(', '));
NODEEOF
  bun "$PATCH_FILE"
fi

exec "$@"
