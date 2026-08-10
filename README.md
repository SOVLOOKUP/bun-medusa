# Medusa Bun Image

[English](README.md) | [中文](README.zh-CN.md)

---

Auto-tracking, Bun-based Docker image for [Medusa](https://github.com/medusajs/medusa). A GitHub Actions workflow polls the npm registry every 6 hours; when a new version of `@medusajs/medusa` is published it bumps `.medusa-version`, tags `v<version>`, builds a slim production image with Bun, and pushes it to GHCR with `latest` / `major.minor` / `major` / `version` tags.

### Features

- **Bun alpine runtime** — `oven/bun:1-alpine` for both builder and runtime stages. Dependencies installed and the production server orchestrated through Bun.
- **Self-contained production build** — `medusa build` output is the runtime; no source mount, no dev server, admin dashboard compiled into the image and served from `:9000/app`.
- **Small footprint** — multi-stage build, `bun install --production`, and aggressive pruning of `*.d.ts` / `*.map` / tests / docs from `node_modules`.
- **Auto-tracking** — `.github/workflows/release.yml` polls `registry.npmjs.org/@medusajs/medusa/latest` every 6 hours and rebuilds automatically on new releases. Manual dispatch with a specific version is also supported.
- **Runtime entrypoint** ([docker-entrypoint-medusa.sh](docker-entrypoint-medusa.sh)) handles four pain-points so self-hosted deploys work out of the box:
  1. Appends `?sslmode=disable&connect_timeout=30` to `DATABASE_URL` (unless an explicit `sslmode=` is already present) to avoid MikroORM's 10 s SSL-handshake timeout against plain-TCP Postgres.
  2. When `REDIS_URL` is provided, rewrites `medusa-config.js` to replace the four memory-backed modules (`cache` / `event_bus` / `workflows` / `locking`) with their Redis-backed implementations.
  3. Overrides the session cookie `secure` / `sameSite` flags so HTTP login works (Medusa forces `secure:true` under `NODE_ENV=production`, which breaks browser login over plain HTTP). Set `MEDUSA_COOKIE_SECURE=true` to restore the production default behind trusted TLS.
  4. Automatically runs `medusa db:migrate` before `medusa start` (idempotent — already-applied migrations are skipped). If the database isn't ready yet, the container exits and `restart: unless-stopped` retries until it comes up. Set `MEDUSA_AUTO_MIGRATE=false` to disable.

### Quick start

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. Configure secrets
cp .env.example .env
# Replace the three change_me values with: openssl rand -hex 32

# 2. Bring up the stack (postgres + redis + medusa)
#    Migrations run automatically on first boot — no manual step needed.
docker compose up -d

# 3. Create an admin user (first time only)
docker compose run --rm medusa \
  bunx medusa user -e admin@example.com -p YourPassword123

# 4. Open the admin dashboard
open http://localhost:9000/app
```

### Image tags

Published to `ghcr.io/sovlookup/bun-medusa`:

| Tag | Meaning |
|---|---|
| `2.18.0` | Exact version |
| `2.18` | Latest patch of `2.18` |
| `2` | Latest minor of `2` |
| `latest` | Always the newest release |

### Configuration

Required environment variables (see [.env.example](.env.example)):

| Variable | Purpose |
|---|---|
| `JWT_SECRET` | JWT signing secret (≥ 32 bytes hex) |
| `COOKIE_SECRET` | Session cookie signing secret (≥ 32 bytes hex) |
| `AUTH_MFA_ENCRYPTION_KEY` | MFA encryption key (≥ 32 bytes hex) |
| `STORE_CORS` | Storefront origins allowed to call the Store API |
| `ADMIN_CORS` | Admin dashboard origins allowed to call the Admin API |
| `AUTH_CORS` | Auth API CORS (usually the union of admin + storefront origins) |

Provided by [docker-compose.yml](docker-compose.yml):

| Variable | Default |
|---|---|
| `DATABASE_URL` | `postgres://postgres:postgres@postgres:5432/medusa-store` |
| `REDIS_URL` | `redis://redis:6379` |
| `NODE_ENV` | `production` |

Optional:

| Variable | Default | Purpose |
|---|---|---|
| `MEDUSA_AUTO_MIGRATE` | `true` | Auto-run `medusa db:migrate` before `medusa start` (idempotent) |
| `MEDUSA_COOKIE_SECURE` | `false` | Set `true` to enable `Secure` + `SameSite=lax` cookies (use behind TLS termination) |
| `CACHE_REDIS_URL` | unset | When set, registers a separate `caching-redis` module using this URL |

### File layout

```
.
├── .github/workflows/release.yml   # Auto-track + build pipeline
├── .medusa-version                 # Tracked version (e.g. 2.18.0)
├── Dockerfile                      # Multi-stage Bun build
├── docker-entrypoint-medusa.sh     # Runtime config patcher + auto-migrate
├── docker-compose.yml              # postgres + redis + medusa (self-contained)
├── docker-compose.1panel.yml       # 1Panel variant (external postgres/redis)
├── .env.example                    # Required env vars template
└── .gitignore
```

### Auto-tracking mechanism

The `track` job in [release.yml](.github/workflows/release.yml):

1. Polls `https://registry.npmjs.org/@medusajs/medusa/latest` every 6 hours (cron).
2. Compares the published `version` field to `.medusa-version`.
3. On a mismatch: bumps `.medusa-version`, commits with message `chore: bump medusa to <version>`, tags `v<version>`, and pushes.
4. The same workflow run then triggers the `build` job.

The `build` job:

1. Checks out at the new tag.
2. Runs `docker/buildx build --build-arg MEDUSA_VERSION=<version>` (default `linux/amd64`; set the repo variable `PLATFORMS=linux/amd64,linux/arm64` for arm64).
3. Pushes to GHCR with the four tags above.
4. Uses GitHub Actions cache for layer reuse.

Manual dispatch: Actions → release → Run workflow → enter a specific version (e.g. `2.18.0`).

### Local development / testing

```bash
# Build the image locally (mirrors what CI does)
docker build --build-arg MEDUSA_VERSION=2.18.0 -t medusa-bun:local .

# Or pull the published image
docker pull ghcr.io/sovlookup/bun-medusa:2.18.0

# Run an interactive shell inside the image
docker run --rm -it --entrypoint sh ghcr.io/sovlookup/bun-medusa:2.18.0
```

### Troubleshooting

**`Could not connect to the database while running migrations. The connection timed out after 10 seconds.`**
The entrypoint automatically appends `?sslmode=disable&connect_timeout=30` to `DATABASE_URL`. If you bypass the entrypoint (`--entrypoint` override), add the query params manually.

**Admin login silently fails (returns to `/app/login` after Sign in).**
Caused by `secure:true` session cookies being rejected over HTTP. Either use the bundled entrypoint (default, sets `secure:false`), or set `MEDUSA_COOKIE_SECURE=true` and put HTTPS in front.

**`redisUrl not found. A fake redis instance will be used.`** appears in logs.
Three of these lines are emitted by legacy code paths and are harmless. The entrypoint rewrites `medusa-config.js` so the four real Redis modules (`event-bus-redis` / `cache-redis` / `workflow-engine-redis` / `locking-redis`) are registered when `REDIS_URL` is set — you should see four `Connection to Redis ... established` lines confirming real connections.

**`/store/products` returns HTTP 400.**
This is expected — Medusa v2 requires an `x-publishable-api-key` header on Store API calls. Create a publishable API key in the admin dashboard (Settings → API Key Management) and pass it as `x-publishable-api-key: <key>`.

### Notes

- The `GITHUB_TOKEN` used by the `track` job to push the version bump will not re-trigger workflows (by design — prevents loops); the `build` job runs in the same workflow run.
- If your default branch is protected, allow the `github-actions[bot]` to push or switch to a PAT.
