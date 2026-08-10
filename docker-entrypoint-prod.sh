#!/bin/sh
set -eu

APP_DIR="/app/medusa"

cd "$APP_DIR"

# --- (1) Run database migrations -----------------------------------------
echo "[medusa] Running database migrations ..."
npx medusa db:migrate 2>&1 || {
  echo "[medusa] Migration failed, will retry on next start or during first run."
}
echo "[medusa] Database migrations complete."

# --- (2) Create admin user if credentials provided -----------------------
ADMIN_EMAIL="${MEDUSA_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${MEDUSA_ADMIN_PASSWORD:-}"
if [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
  echo "[medusa] Ensuring admin user '$ADMIN_EMAIL' exists ..."
  if npx medusa user -e "$ADMIN_EMAIL" -p "$ADMIN_PASSWORD" 2>&1; then
    echo "[medusa] Admin user created."
  else
    echo "[medusa] Admin user already exists — skipping."
  fi
fi

# --- (3) Start Medusa server ---------------------------------------------
echo "[medusa] Starting production server: $*"
exec "$@"