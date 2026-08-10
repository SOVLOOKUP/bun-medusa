#!/bin/sh
# ---------------------------------------------------------------------------
# Development entrypoint (Bun-only, no Node.js).
#
#   1. First boot: seed the empty bind-mount with the starter source code
#      baked into the image (so `./medusa-app` is populated automatically).
#   2. Install dependencies if node_modules is missing.
#   3. Patch @jridgewell/trace-mapping to clamp -1 columns to 0, working
#      around Bun bug #17303 (source-map-support crash in containers).
#   4. Generate a .env file from environment variables (if absent).
#   5. Append sslmode=disable&connect_timeout=30 to DATABASE_URL.
#   6. Run database migrations (creates tables required by medusa develop).
#   7. Optionally create the admin user.
#   8. Hand off to `bun run dev` (i.e. `medusa develop`).
# ---------------------------------------------------------------------------
set -eu

# --- (0) Disable core dumps ------------------------------------------------
# Bun / Node native-module segfaults occasionally (CJS/ESM bridge, native
# bindings, trace-mapping null-return patch edge cases, etc.) and each
# crash writes a 1 GB core.* file to the process cwd (/app/medusa), which
# is the user's bind-mounted data volume.  Those files serve NO purpose
# inside a throwaway dev container, silently eat disk space, and force
# the user to manually clean them up.  Disable core dumping before any
# child process starts.  (The equivalent `--ulimit core=0` at docker-run
# time also works but this way we don't rely on the user remembering.)
if command -v ulimit >/dev/null 2>&1; then
  ulimit -c 0 2>/dev/null || true
fi
# If we have CAP_SYS_RESOURCE (rare) and the kernel core_pattern points
# somewhere writable, also hint the kernel to discard dumps via pipe.
# (Gracefully ignore — most container runtimes drop this capability.)
[ -w /proc/sys/kernel/core_pattern ] 2>/dev/null \
  && echo "|/bin/false" > /proc/sys/kernel/core_pattern 2>/dev/null || true

APP_DIR="/app/medusa"
SEED_DIR="/app/medusa-seed"

# --- (1) Seed source code on first boot -----------------------------------
# Check for package.json rather than "is the dir empty" — the named volume
# mounted at node_modules makes the dir appear non-empty even on first boot.
if [ ! -f "$APP_DIR/package.json" ]; then
  echo "[dev-entrypoint] First boot: seeding source code into $APP_DIR ..."
  cp -a "$SEED_DIR/." "$APP_DIR/"
  echo "[dev-entrypoint] Source code seeded. You can now edit files in ./medusa-app/ on the host."
fi

# --- (1b) Top up missing starter files on stale bind-mounts ---------------
# The starter may add new required files in newer versions (e.g.
# src/admin/i18n/index.ts added 2025-10-27).  A volume created from an
# older seed has package.json so step (1) never runs again, leaving the
# new file absent and Vite's i18n virtual module unable to resolve.
# Sync only what's missing — never overwrite existing user edits.
_TOPUP_FILES="
  src/admin/i18n/index.ts
  src/admin/i18n/README.md
"
for _rel in $_TOPUP_FILES; do
  _src="$SEED_DIR/$_rel"
  _dst="$APP_DIR/$_rel"
  if [ -f "$_src" ] && [ ! -f "$_dst" ]; then
    echo "[dev-entrypoint] Syncing missing $_rel from seed (stale volume) ..."
    mkdir -p "$(dirname "$_dst")"
    cp -a "$_src" "$_dst"
  fi
done
unset _rel _src _dst _TOPUP_FILES

cd "$APP_DIR"

# --- (2) Install dependencies if missing ----------------------------------
if [ ! -d "$APP_DIR/node_modules" ] || [ -z "$(ls -A "$APP_DIR/node_modules" 2>/dev/null)" ]; then
  echo "[dev-entrypoint] node_modules missing — running bun install (first boot, may take a while) ..."
  bun install
  echo "[dev-entrypoint] Dependencies installed."
fi

# --- (3) Patch trace-mapping for Bun compatibility (#17303) ---------------
# Bun's runtime can produce -1 column values in stack traces; trace-mapping
# throws on negative columns, crashing medusa develop.  Replace the throw
# (or any previous broken replacement that writes to undefined variables)
# with a safe `return {source:null,line:null,column:null,name:null}`.
#
# NOTE: Previous iterations of this entrypoint accidentally replaced the
# COL_GTR_EQ_ZERO throw with `aNeedle[aColumnName]=0`, referencing undefined
# variables that caused a ReferenceError.  The logic here is therefore:
#   a) Revert any stale `aNeedle[aColumnName]=0` back to the original throw.
#   b) Apply the correct null-return patch to both throw sites.
# Running (a)+(b) every boot makes the patch idempotent regardless of the
# prior state of the file (fresh / partially patched / broken).
_patch_trace_mapping() {
  _file="$1"
  [ -f "$_file" ] || return 0
  # (a) revert the broken aNeedle replacement back to the throw
  if grep -q 'aNeedle\[aColumnName\]=0' "$_file" 2>/dev/null; then
    sed -i 's/aNeedle\[aColumnName\]=0/throw new Error(COL_GTR_EQ_ZERO)/g' "$_file"
  fi
  # (b) now always re-apply the correct null-return patch for both throw sites
  if grep -q 'throw new Error(COL_GTR_EQ_ZERO)\|throw new Error(LINE_GTR_ZERO)' "$_file" 2>/dev/null; then
    echo "[dev-entrypoint] Patching $_file (Bun #17303 workaround)..."
    sed -i 's/throw new Error(COL_GTR_EQ_ZERO)/return {source:null,line:null,column:null,name:null}/g' "$_file"
    sed -i 's/throw new Error(LINE_GTR_ZERO)/return {source:null,line:null,column:null,name:null}/g' "$_file"
  fi
}
_patch_trace_mapping "$APP_DIR/node_modules/@jridgewell/trace-mapping/dist/trace-mapping.umd.js"
# Also patch the source-map-support copy if it bundles its own trace-mapping
for tm in "$APP_DIR"/node_modules/@cspotcode/source-map-support/node_modules/@jridgewell/trace-mapping/dist/trace-mapping.umd.js; do
  _patch_trace_mapping "$tm"
done

# --- (4) Generate .env from environment variables (if absent) -------------
if [ ! -f "$APP_DIR/.env" ]; then
  echo "[dev-entrypoint] Generating .env from environment variables ..."
  cat > "$APP_DIR/.env" <<EOF
# Auto-generated by docker-entrypoint-dev.sh on first boot.
# Edit freely — this file is NOT managed after creation.
DATABASE_URL=${DATABASE_URL:-}
REDIS_URL=${REDIS_URL:-}
JWT_SECRET=${JWT_SECRET:-change_me_jwt}
COOKIE_SECRET=${COOKIE_SECRET:-change_me_cookie}
STORE_CORS=${STORE_CORS:-http://localhost:8000}
ADMIN_CORS=${ADMIN_CORS:-http://localhost:5173,http://localhost:9000}
AUTH_CORS=${AUTH_CORS:-http://localhost:5173,http://localhost:8000,http://localhost:9000}
EOF
  echo "[dev-entrypoint] .env created."
fi

# --- (4b) Sync admin-vite-overrides.ts + patch medusa-config.ts ---------
# The in-container shared-port proxy (shared-port-proxy.ts) owns port 9000,
# so Medusa MUST listen on 9002.  admin-vite-overrides.ts provides the
# admin.vite function with all fixes (allowedHosts, fs.strict, HMR port,
# resolve-abs-fs-paths plugin that fixes the i18n blank-page bug).
#
# This runs on EVERY boot (not just first-boot seed) so that bind-mount
# volumes created by older image versions get upgraded automatically.

# Sync the overrides file (always overwrite — it's version-controlled, not
# user-editable).  Source from /usr/local/bin/ (always present in the image).
if [ -f /usr/local/bin/admin-vite-overrides.ts ]; then
  cp -a /usr/local/bin/admin-vite-overrides.ts "$APP_DIR/admin-vite-overrides.ts"
fi

_CFG="$APP_DIR/medusa-config.ts"
if [ -f "$_CFG" ]; then
  # Fix CJS/ESM if stale (older volumes may still have module.exports)
  sed -i 's/module\.exports = defineConfig/export default defineConfig/' "$_CFG"

  # Add import at top (idempotent)
  if ! grep -q 'import adminVite from "./admin-vite-overrides.ts"' "$_CFG"; then
    sed -i '1i import adminVite from "./admin-vite-overrides.ts";' "$_CFG"
  fi

  # Remove any existing one-line `admin: { vite: ... }` block.
  # All previous image versions injected the admin block as a single line,
  # so this catches volumes patched by any prior release.
  sed -i '/admin: { vite:/d' "$_CFG"

  # Inject fresh `admin: { vite: adminVite },` before projectConfig (idempotent)
  if ! grep -q 'admin: { vite: adminVite }' "$_CFG"; then
    sed -i 's|projectConfig: {|admin: { vite: adminVite },\n  projectConfig: {|' "$_CFG"
  fi

  # Enforce http.port = 9002 (proxy owns 9000)
  if grep -qE 'http:[[:space:]]*\{' "$_CFG"; then
    if grep -qE '(^|[[:space:]])port:[[:space:]]*9002' "$_CFG" 2>/dev/null; then
      : # already 9002
    elif grep -qE '(^|[[:space:]])port:[[:space:]]*[0-9]+' "$_CFG" 2>/dev/null; then
      echo "[dev-entrypoint] Correcting http.port to 9002 (proxy owns 9000) ..."
      sed -i -E 's/((^|[[:space:]])port:[[:space:]]*)[0-9]+/\19002/' "$_CFG"
    else
      echo "[dev-entrypoint] Injecting http.port = 9002 ..."
      sed -i 's/http: {/http: {\n    port: 9002,/' "$_CFG"
    fi
  fi
fi
unset _CFG

# --- (4c) Sanitize .env (idempotent, every boot) ---------------------------
# Older versions of this entrypoint had two bugs that could corrupt .env:
#   (a) The sed `s|...|DATABASE_URL=$DATABASE_URL|` replacement used the raw
#       URL which contains `&`.  In sed, `&` is a back-reference to the
#       entire match, so every rewrite *duplicated* the old value inside the
#       new value — repeating sslmode=disable&connect_timeout=30 many times.
#   (b) The generated .env lines sometimes had no trailing newline, causing
#       subsequent writes to glue to the previous line.
#
# Fix strategy: rewrite the file, normalising key=value lines:
#   • Ensure every KEY=VALUE pair sits on its own line (split runs of
#     "KEY=...KEY=..." produced by bug (a)+(b)).
#   • Keep the FIRST occurrence of each KEY (user edits win over
#     duplicates spawned by the sed bug).
#   • Preserve blank lines, comments, and the header block.
#   • Always add a final trailing newline.
if [ -f "$APP_DIR/.env" ]; then
  _TMP_ENV="${APP_DIR}/.env.sanitized.$$"
  _seen_keys=""

  # Read entire .env into REPLY; then split on KEY= boundaries to recover
  # from bug (a)+(b) concatenations.  Busybox-compatible (no bash arrays).
  _raw_env=$(cat "$APP_DIR/.env" 2>/dev/null || true)

  # Produce one KEY=VALUE token per line.  Strategy: turn "KEY1=v1KEY2=v2"
  # into "KEY1=v1" LF "KEY2=v2" by inserting newlines before each
  # /^[A-Z_][A-Z0-9_]*=/ match that is not already at BOF.
  _tokens=$(printf '%s\n' "$_raw_env" \
    | awk '
        {
          line = $0
          # If the line has multiple KEY= runs jammed together, split them.
          # Insert a \x01 marker before each ^[A-Z_][A-Z0-9_]*= that has a
          # non-empty prefix.
          while (match(line, /[A-Z_][A-Z0-9_]*=/)) {
            pos = RSTART
            if (pos == 1 && prev == "") {
              # first token in a new jumble
            } else if (pos > 1) {
              # print everything before this KEY= as a chunk
              print substr(line, 1, pos - 1)
            }
            # consume through the end of the value (up to the next KEY=
            # start or EOL)
            key_eq = substr(line, RSTART, RLENGTH)
            rest = substr(line, RSTART + RLENGTH)
            # find the next KEY= within rest (the bug produced
            # "KEY1=...KEY2=...")
            if (match(rest, /[A-Z_][A-Z0-9_]*=/)) {
              val = substr(rest, 1, RSTART - 1)
              print key_eq val
              line = substr(rest, RSTART)
              prev = "J"
            } else {
              print key_eq rest
              line = ""
              prev = ""
              break
            }
          }
          if (length(line) > 0) print line
        }
      ')

  # Now de-duplicate: for each KEY=VALUE line, keep the FIRST occurrence.
  # Preserve lines that don't look like KEY=VALUE (comments, blanks).
  : > "$_TMP_ENV"
  while IFS= read -r _line || [ -n "$_line" ]; do
    if printf '%s' "$_line" | grep -Eq '^[A-Z_][A-Z0-9_]*='; then
      _key=$(printf '%s' "$_line" | sed 's/=.*//')
      case " $_seen_keys " in
        *" $_key "*) ;;          # duplicate — drop
        *)
          echo "$_line" >> "$_TMP_ENV"
          _seen_keys="$_seen_keys $_key"
          ;;
      esac
    else
      echo "$_line" >> "$_TMP_ENV"
    fi
  done <<EOF
$_tokens
EOF

  # Guarantee final newline (busybox sh "read" loop can leave it off for
  # unterminated source lines).
  [ -s "$_TMP_ENV" ] && [ "$(tail -c1 "$_TMP_ENV" 2>/dev/null | wc -l)" -eq 0 ] && echo "" >> "$_TMP_ENV"

  mv "$_TMP_ENV" "$APP_DIR/.env"
  unset _TMP_ENV _raw_env _tokens _key _line _seen_keys
fi

# --- (5) Normalise DATABASE_URL + write back safely ------------------------
# Normalise the runtime DATABASE_URL (env var takes precedence, used by
# bun run dev / medusa develop directly — but also sync to .env so tools
# that read only .env still work).  Write-back uses AWK, not sed, so the
# `&` inside the URL is not interpreted as a sed back-reference.
if [ -n "${DATABASE_URL:-}" ]; then
  case "$DATABASE_URL" in
    *sslmode=*)    : ;;
    *\?*)          DATABASE_URL="${DATABASE_URL}&sslmode=disable&connect_timeout=30" ;;
    *)             DATABASE_URL="${DATABASE_URL}?sslmode=disable&connect_timeout=30" ;;
  esac
  export DATABASE_URL

  if [ -f "$APP_DIR/.env" ]; then
    _ENV_TMP="${APP_DIR}/.env.dburl.$$"
    # AWK: replace FIRST line that starts with DATABASE_URL= with our value;
    # leave every other line untouched.  (The sanitizer above guarantees only
    # one such line exists, but do the safe single-replace anyway.)
    awk -v newval="DATABASE_URL=$DATABASE_URL" '
      BEGIN { replaced = 0 }
      {
        if (!replaced && $0 ~ /^DATABASE_URL=/) {
          print newval
          replaced = 1
        } else {
          print $0
        }
      }
      END { if (!replaced) print newval }
    ' "$APP_DIR/.env" > "$_ENV_TMP" \
      && mv "$_ENV_TMP" "$APP_DIR/.env"
    rm -f "$_ENV_TMP"
    unset _ENV_TMP
  fi
fi

# --- (6) Run database migrations ------------------------------------------
# `medusa develop` loads module loaders (Tax, Currency, Region...) that
# query the DB at boot; if tables don't exist the boot fails fatally with
# "relation ... does not exist".  Run migrations first, mirroring the
# production entrypoint.  Use `bun run migrate` (not bunx) to avoid CJS/ESM
# parsing issues in Medusa's config loader.
echo "[dev-entrypoint] Running database migrations ..."
if ! MIGRATE_LOG=$(bun run migrate 2>&1); then
  echo "$MIGRATE_LOG"
  echo "[dev-entrypoint] Migration failed — retrying once in 5s ..."
  sleep 5
  if ! MIGRATE_LOG=$(bun run migrate 2>&1); then
    echo "$MIGRATE_LOG"
    echo "[dev-entrypoint] Migration retried and failed — dev server may crash if tables are missing."
  else
    echo "[dev-entrypoint] Retry succeeded.  Database migrations complete."
  fi
else
  echo "$MIGRATE_LOG"
  echo "[dev-entrypoint] Database migrations complete."
fi

# --- (7) Auto-create admin user (optional) --------------------------------
ADMIN_EMAIL="${MEDUSA_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${MEDUSA_ADMIN_PASSWORD:-}"
if [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
  echo "[dev-entrypoint] Ensuring admin user '$ADMIN_EMAIL' exists ..."
  # `bun run create-admin` resolves modules via bun run (avoids bunx CJS/ESM
  # conflict).  $MEDUSA_ADMIN_EMAIL / $MEDUSA_ADMIN_PASSWORD are expanded at
  # runtime by the shell from the script string baked into package.json.
  if MEDUSA_ADMIN_EMAIL="$ADMIN_EMAIL" MEDUSA_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
       bun run create-admin 2>&1; then
    echo "[dev-entrypoint] Admin user created."
  else
    echo "[dev-entrypoint] Admin user already exists — skipping."
  fi
fi

# --- (7b) Clear Vite optimizeDeps cache on every boot --------------------
#
# Even though admin-vite-overrides.ts now sets `optimizeDeps.noDiscovery`
# (which eliminates Bun/esbuild hash races triggered by lazy route
# scans), stale cross-version hash mismatches can still occur if the
# bind-mounted volume still has node_modules/.vite files from a prior
# image / earlier Vite build WITH discovery enabled.
#
# Example: today's container had metadata hash `EKE55IKS` for
# region-list-<prefix> but disk still had hash `3HPSTDKU` from a
# previous optimizeDeps run → browser 404 even though noDiscovery was
# set, because the old chunk files + metadata still existed.
#
# Cost: ~5–30 s extra on first admin page load (Vite re-builds the boot
# `include` list once).  That's strictly cheaper than chasing hashes
# later.
_VITE_CACHE="$APP_DIR/node_modules/.vite"
if [ -d "$_VITE_CACHE" ]; then
  _N_FILES=$(find "$_VITE_CACHE" -type f | wc -l | tr -d ' ')
  echo "[dev-entrypoint] Clearing stale Vite optimizeDeps cache ($_N_FILES files in $_VITE_CACHE) ..."
  rm -rf "$_VITE_CACHE"
  echo "[dev-entrypoint] Cache cleared.  Boot-time optimizeDeps will rebuild include-list chunks only (noDiscovery = no lazy re-scan)."
else
  echo "[dev-entrypoint] No prior Vite optimizeDeps cache (clean boot)."
fi
unset _VITE_CACHE _N_FILES

# --- (7c) Derive browser-facing HMR endpoint -------------------------------
#
# admin-vite-overrides.ts now reads LITERAL values out of process.env
# for server.hmr.{host,protocol,clientPort} (priority HMR_* > defaults),
# because Vite bakes these constants DIRECTLY into the shipped
# @vite/client source at transform time.  The earlier `config.define`
# trick did NOT work: @vite/client uses an internal transform pipeline
# that bypasses user-defined defines (confirmed live against the user's
# deployment — browser always connected to :9001 regardless of define).
#
# To make set-up zero-config for the common case where the user already
# passes ADMIN_URL (e.g. "https://medusa.example.com:8443/app"), parse
# protocol / host / port out of it and export HMR_* automatically.
#
# Rules:
#   • Explicit HMR_HOSTNAME / HMR_PROTOCOL / HMR_CLIENT_PORT → keep them.
#   • Else if ADMIN_URL is set → parse and fill any missing HMR_* from it.
#   • Protocol is rewritten: http→ws, https→wss (WebSocket equivalent).
#   • Standard ports (80 / 443) are exported as the EMPTY STRING — this
#     is the sentinel Vite needs to avoid falling back to hmr.port (9001)
#     because browsers drop location.port on standard ports.
if [ -n "${ADMIN_URL:-}" ]; then
  _HMR_H="${HMR_HOSTNAME:-}"
  _HMR_P="${HMR_PROTOCOL:-}"
  _HMR_CP="${HMR_CLIENT_PORT:-}"
  if [ -z "$_HMR_H" ] || [ -z "$_HMR_P" ] || [ -z "$_HMR_CP" ]; then
    # Parse ADMIN_URL with awk: works with busybox awk, no python/node.
    # Strip trailing path (/app or similar), then split proto / host[:port]
    _PARSED=$(printf '%s' "$ADMIN_URL" | awk -F'/' '{
      proto=$1; sub(/:$/,"",proto);
      authority=$3;
      n=split(authority, parts, ":");
      host=parts[1];
      port=(n==2) ? parts[2] : "";
      if (port=="") { if (proto=="https") port=443; else if (proto=="http") port=80; }
      wsproto=(proto=="https") ? "wss" : "ws";
      printf "%s|%s|%s", host, wsproto, port;
    }')
    if [ -n "$_PARSED" ]; then
      _AU_HOST="${_PARSED%%|*}"
      _REST="${_PARSED#*|}"
      _AU_PROTO="${_REST%%|*}"
      _AU_PORT="${_REST#*|}"
      [ -z "$_HMR_H"  ] && export HMR_HOSTNAME="$_AU_HOST"
      [ -z "$_HMR_P"  ] && export HMR_PROTOCOL="$_AU_PROTO"
      if [ -z "$_HMR_CP" ]; then
        if [ "$_AU_PORT" = "80" ] || [ "$_AU_PORT" = "443" ]; then
          # Empty string sentinel → Vite uses page implied port.
          export HMR_CLIENT_PORT=""
        else
          export HMR_CLIENT_PORT="$_AU_PORT"
        fi
      fi
      unset _AU_HOST _AU_PROTO _AU_PORT
    fi
    unset _PARSED
  fi
  unset _HMR_H _HMR_P _HMR_CP
fi
echo "[dev-entrypoint] Browser-facing HMR endpoint:"
echo "                 HMR_HOSTNAME    = ${HMR_HOSTNAME:-<inherit from page hostname>}"
echo "                 HMR_PROTOCOL    = ${HMR_PROTOCOL:-ws (defaults, NO TLS — please set ADMIN_URL=https://...)}"
case "${HMR_CLIENT_PORT+-x}" in
  +x) if [ -z "$HMR_CLIENT_PORT" ]; then
        echo "                 HMR_CLIENT_PORT = <empty string = keep page's standard 80/443 port>"
      else
        echo "                 HMR_CLIENT_PORT = $HMR_CLIENT_PORT"
      fi ;;
  *)  echo "                 HMR_CLIENT_PORT = <unset, fallthrough to hmr.port 9001 — BAD behind reverse proxy>" ;;
esac

# --- (8) Shared-port proxy + dev server -----------------------------------
# shared-port-proxy.ts (Bun) binds to container port 9000 and dispatches:
#   • HTTP + non-HMR WebSocket traffic   → 127.0.0.1:9002 (Medusa)
#   • WebSocket Upgrade for /vite-hmr(*) → 127.0.0.1:9001 (Vite HMR)
# Result: a SINGLE docker port mapping (-p HOST:9810→9000) carries EVERYTHING,
# so the reverse proxy only needs one location block + WebSocket Upgrade
# passthrough — no extra HMR port mapping, no separate /vite-hmr location.
#
# The proxy runs in the background.  Medusa runs on PORT=9002 in the
# foreground (still becomes PID 1 via exec).  If medusa exits the
# container will terminate and the proxy dies with it.
echo "[dev-entrypoint] Starting shared-port reverse proxy on 0.0.0.0:9000"
bun /usr/local/bin/shared-port-proxy.ts &
PROXY_PID=$!
trap '[ -n "${PROXY_PID:-}" ] && kill $PROXY_PID 2>/dev/null || true' EXIT INT TERM HUP

# Tiny grace period: let the proxy bind port 9000 BEFORE medusa comes up
# (medusa binds 9002 anyway, so this is purely cosmetic — no race).
sleep 0.5

echo "[dev-entrypoint] Starting dev server on container-internal port 9002: PORT=9002 $*"
PORT=9002 exec "$@"
