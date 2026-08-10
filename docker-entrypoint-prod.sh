#!/bin/sh
set -eu

APP_DIR="/app/medusa"

cd "$APP_DIR"

# --- (1) Run database migrations -----------------------------------------
# Use 'bun run migrate' — bun run resolves CJS/ESM correctly
echo "[medusa] Running database migrations ..."
bun run migrate 2>&1 || {
  echo "[medusa] Migration failed, will retry on next start or during first run."
}
echo "[medusa] Database migrations complete."

# --- (2) Create admin user if credentials provided -----------------------
ADMIN_EMAIL="${MEDUSA_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${MEDUSA_ADMIN_PASSWORD:-}"
if [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
  echo "[medusa] Ensuring admin user '$ADMIN_EMAIL' exists ..."
  bun run create-admin 2>&1 && \
    echo "[medusa] Admin user created." || \
    echo "[medusa] Admin user already exists — skipping."
fi

# --- (3) Start Medusa server (Bun runtime) -------------------------------
echo "[medusa] Starting production server with Bun: $*"
exec "$@"
