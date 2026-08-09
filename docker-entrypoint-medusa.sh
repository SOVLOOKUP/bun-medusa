#!/bin/sh
# ---------------------------------------------------------------------------
# Three jobs:
#   1. Patch /app/medusa-config.js to:
#        - inject real Redis-backed modules (cache / event_bus / workflows /
#          locking) when REDIS_URL is provided, replacing the memory-backed
#          defaults.
#        - override the session cookie's `secure` / `sameSite` flags to allow
#          HTTP login, unless MEDUSA_COOKIE_SECURE=true.  Medusa forces
#          `secure: true, sameSite: "lax"` whenever NODE_ENV=production,
#          which prevents the browser from accepting the session cookie over
#          plain HTTP — making the admin dashboard impossible to log into
#          when the image is run without TLS termination in front.
#   2. Append sslmode=disable&connect_timeout=30 to DATABASE_URL when no
#      `sslmode=` query parameter is already present.  MikroORM/PG defaults
#      otherwise try an SSL handshake first and take 10 s to time out
#      against a plain-TCP Postgres.
#
# The patch script is emitted into /app/node_modules (owned by user `medusa`)
# because /app root is owned by root and not writable by the runtime user.
# ---------------------------------------------------------------------------
set -eu

# --- (2) Normalise DATABASE_URL -------------------------------------------
if [ -n "${DATABASE_URL:-}" ]; then
  case "$DATABASE_URL" in
    *sslmode=*)    : ;;                              # explicit, leave alone
    *\?*)          DATABASE_URL="${DATABASE_URL}&sslmode=disable&connect_timeout=30" ;;
    *)             DATABASE_URL="${DATABASE_URL}?sslmode=disable&connect_timeout=30" ;;
  esac
  export DATABASE_URL
fi

# --- (1) Patch medusa-config.js -------------------------------------------
PATCH_FILE="/app/node_modules/.medusa_config_patch.cjs"
cat > "$PATCH_FILE" <<'NODEEOF'
process.chdir('/app');
const fs = require('fs');
const utils_1 = require("@medusajs/framework/utils");

// --- (1a) Redis modules --------------------------------------------------
const ru = process.env.REDIS_URL;
const mods = {};
if (ru) {
  mods.cache          = { resolve: "@medusajs/cache-redis",          options: { redisUrl: ru } };
  mods.event_bus      = { resolve: "@medusajs/event-bus-redis",      options: { redisUrl: ru, workerOptions: { concurrency: 1 } } };
  mods.workflows      = { resolve: "@medusajs/workflow-engine-redis", options: { redis: { url: ru } } };
  mods.locking        = {
    resolve: "@medusajs/medusa/locking",
    options: { providers: [{ id: "locking-redis", resolve: "@medusajs/locking-redis", is_default: true, options: { redisUrl: ru } }] }
  };
  if (process.env.CACHE_REDIS_URL) {
    mods.caching = {
      resolve: "@medusajs/medusa/caching-redis",
      options: { providers: [{ id: "caching-redis", resolve: "@medusajs/medusa/caching-redis", is_default: true, options: { redisUrl: process.env.CACHE_REDIS_URL } }] }
    };
  }
}

// --- (1b) Session cookie overrides --------------------------------------
// Medusa sets `secure: true, sameSite: "lax"` in production, which blocks
// the session cookie on plain HTTP.  Allow the operator to opt in to HTTP-
// friendly cookies (default) by setting MEDUSA_COOKIE_SECURE=false (the
// default here), or explicitly opt out via MEDUSA_COOKIE_SECURE=true when
// running behind TLS termination that the app can trust.
const cookieSecureRaw = (process.env.MEDUSA_COOKIE_SECURE || "false").toLowerCase();
const cookieSecure = cookieSecureRaw === "true" || cookieSecureRaw === "1";
const cookieOptions = {
  // Medusa's production default is sameSite:"lax" + secure:true.
  // We override to allow HTTP login unless explicitly enabled.
  secure: cookieSecure,
  sameSite: cookieSecure ? "lax" : false,
};

// --- (1c) Emit replacement medusa-config.js -----------------------------
const cfg = {
  projectConfig: {
    databaseUrl: process.env.DATABASE_URL,
    http: {
      storeCors:    process.env.STORE_CORS,
      adminCors:    process.env.ADMIN_CORS,
      authCors:     process.env.AUTH_CORS,
      jwtSecret:    process.env.JWT_SECRET,
      cookieSecret: process.env.COOKIE_SECRET,
    },
    cookieOptions,
  },
};
if (Object.keys(mods).length > 0) {
  cfg.modules = mods;
}

// Use loadEnv + defineConfig exactly like the original generated config.
const newContent = `"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("@medusajs/framework/utils");
(0, utils_1.loadEnv)(process.env.NODE_ENV || 'development', process.cwd());
module.exports = (0, utils_1.defineConfig)(${JSON.stringify(cfg, null, 4)});
`;
fs.writeFileSync('/app/medusa-config.js', newContent);

const bits = [];
bits.push('cookie: secure=' + cookieOptions.secure + ', sameSite=' + JSON.stringify(cookieOptions.sameSite));
if (ru) {
  bits.push('redis modules: ' + Object.keys(mods).join(', '));
} else {
  bits.push('redis modules: (none, REDIS_URL unset)');
}
console.log('[entrypoint] medusa-config.js patched — ' + bits.join(' | '));
NODEEOF
bun "$PATCH_FILE"

exec "$@"
