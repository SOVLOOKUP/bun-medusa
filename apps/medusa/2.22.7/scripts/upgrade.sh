#!/bin/sh
set -eu

echo "[medusa] Upgrading..."

# Medusa handles migrations automatically on startup
echo "[medusa] Upgrade complete. Database migrations will run on next start."