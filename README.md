# Medusa Bun Dev

[English](README.md) | [中文](README.zh-CN.md)

---

Development environment for [Medusa v2](https://github.com/medusajs/medusa) with source-code mount, hot-reload, and zero manual setup. Based on `oven/bun:1.4-debian`, clones the official `medusa-starter-default` at build time so you can edit source on the host and see changes instantly inside the container.

## Features

- **Bun 1.4 Debian runtime** — `oven/bun:1.4-debian` with TUNA mirror for apt, `npmmirror.com` for Bun packages.
- **Source-code mount** — `./medusa-app/` is auto-seeded on first boot; edit files on the host, the dev server hot-reloads inside the container.
- **Pure Bun** — `bun install` for dependencies, `bun run dev` for the dev server. No Node.js required.
- **Bun #17303 workaround** — entrypoint patches `@jridgewell/trace-mapping` to clamp `-1` column values (Bun stack-trace bug that crashes `medusa develop` in containers).
- **Vite HMR in containers** — `medusa-config.ts` sets `hmr.clientPort: 9000` (backend proxies the WebSocket) and a `resolve.alias` to fix Medusa's i18n path resolution bug.
- **One-command startup** — auto-migrate + auto-create admin user on first boot.
- **Two compose variants** — self-contained (postgres + redis + medusa) or 1Panel (external postgres/redis).

## Quick start (self-contained)

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. Configure secrets
cp .env.example .env
# Replace the change_me values with: openssl rand -hex 32

# 2. Build and start (first boot seeds source + installs deps)
docker compose up -d --build

# 3. Wait ~60s for first boot, then open the admin dashboard
open http://localhost:9000/app
# Login with admin@medusa.local / SuperSecret123
```

After first boot, the source is in `./medusa-app/`. Edit any file under `medusa-app/src/` — the backend hot-reloads via the file watcher, and the admin dashboard hot-reloads via Vite HMR.

## Quick start (1Panel — external postgres/redis)

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. Configure secrets + 1Panel DB/Redis host overrides
cp .env.example .env
# Edit .env:
#   - JWT_SECRET / COOKIE_SECRET
#   - POSTGRES_HOST / POSTGRES_PASSWORD
#   - REDIS_HOST / REDIS_PASSWORD

# 2. Start medusa only (uses external postgres + redis via 1panel-network)
docker compose -f docker-compose.1panel.yml up -d --build

# 3. Open the admin dashboard
open http://<server-ip>:9000/app
```

Prerequisites:
- 1Panel has PostgreSQL and Redis/Valkey deployed, both joined to `1panel-network`.
- PostgreSQL has database `medusa` with user `medusa` granted.
- The `1panel-network` Docker network exists.

## Default admin credentials

| Field | Default |
|---|---|
| Email | `admin@medusa.local` |
| Password | `SuperSecret123` |

Override in `.env`:
```bash
MEDUSA_ADMIN_EMAIL=your@email.com
MEDUSA_ADMIN_PASSWORD=YourStrongPassword
```

## Configuration

Required environment variables (see [.env.example](.env.example)):

| Variable | Purpose |
|---|---|
| `JWT_SECRET` | JWT signing secret (>= 32 bytes hex) |
| `COOKIE_SECRET` | Session cookie signing secret (>= 32 bytes hex) |
| `STORE_CORS` | Storefront origins allowed to call the Store API |
| `ADMIN_CORS` | Admin dashboard origins allowed to call the Admin API |
| `AUTH_CORS` | Auth API CORS (usually the union of admin + storefront origins) |

1Panel variant also requires:

| Variable | Purpose |
|---|---|
| `POSTGRES_USER` | PostgreSQL username |
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `POSTGRES_HOST` | PostgreSQL container name on 1panel-network |
| `POSTGRES_DB` | PostgreSQL database name |
| `REDIS_PASSWORD` | Redis/Valkey password |
| `REDIS_HOST` | Redis container name on 1panel-network |

### CORS cheat sheet

| Variable | Protects | Who calls it |
|---|---|---|
| `STORE_CORS` | `/store/*` | Your storefront (Next.js, etc.) |
| `ADMIN_CORS` | `/admin/*` | Admin dashboard (`:9000/app`) |
| `AUTH_CORS` | `/auth/*` | Login/register (both admin + storefront) |

Origins must be exact: `protocol://host:port`. Multiple origins comma-separated, no spaces.

## File layout

```
.
├── Dockerfile                  # Dev image (Bun 1.4 Debian + clone starter)
├── docker-entrypoint.sh        # Seed source, patch trace-mapping, create admin
├── docker-compose.yml          # postgres + redis + medusa (self-contained)
├── docker-compose.1panel.yml   # 1Panel variant (external postgres/redis)
├── .env.example                # Required env vars template
└── medusa-app/                 # Auto-seeded source (gitignored)
    ├── src/                    # Edit here — hot-reload in container
    ├── medusa-config.ts        # Vite HMR + i18n alias config
    ├── package.json
    └── ...
```

## How it works

### Build time (Dockerfile)

1. `FROM oven/bun:1.4-debian` with TUNA apt mirror.
2. Installs `git` only (no nodejs/npm).
3. Clones `medusa-starter-default` into `/app/medusa`.
4. Saves a pristine copy to `/app/medusa-seed` (for first-boot seeding).
5. `bun install` (full dependencies, including devDependencies).
6. Sets `BUN_CONFIG_REGISTRY=https://registry.npmmirror.com`.

### First boot (docker-entrypoint.sh)

1. If `package.json` is missing in the bind-mount, copies source from `/app/medusa-seed`.
2. If `node_modules` is empty, runs `bun install`.
3. Patches `@jridgewell/trace-mapping` — clamps `-1` column values to `0` (Bun bug #17303 workaround).
4. Generates `.env` from environment variables (if absent).
5. Appends `?sslmode=disable&connect_timeout=30` to `DATABASE_URL`.
6. Creates the admin user (skips if exists).
7. Hands off to `bun run dev` (i.e. `medusa develop`).

### Vite configuration (medusa-config.ts)

Two fixes for container environments:

1. **HMR** — `server.hmr.clientPort: 9000` tells the Vite client to connect via port 9000 (the backend proxies the WebSocket), instead of a random port that isn't exposed.

2. **i18n path alias** — Medusa's Vite plugin generates import paths like `/app/medusa/src/admin/i18n/index.ts`. Vite strips the `/app` base prefix, leaving `/medusa/src/...` which doesn't exist. The alias `'/medusa/' -> '/app/medusa/'` fixes this.

## Troubleshooting

**Admin dashboard is blank / Vite connection errors.**
Ensure `medusa-config.ts` has the `admin.vite` configuration (HMR clientPort + alias). If you modified it, restart the container — the Watcher restarts the backend but Vite needs a full restart for config changes.

**`column must be greater than or equal to 0` crash.**
This is Bun bug #17303. The entrypoint patches `trace-mapping` automatically. If you bypass the entrypoint, the crash will return.

**Container exits immediately after start.**
Check `docker inspect <container> --format 'OOMKilled={{.State.OOMKilled}}'`. If `OOMKilled=true`, add `mem_limit: 2g` to the medusa service in docker-compose.yml.

**`medusa-app/` is empty after starting.**
The entrypoint seeds it on first boot. If you deleted it, stop the containers, remove the `medusa_node_modules` volume, and restart: `docker compose down && docker volume rm medusa-bun_medusa_node_modules && docker compose up -d`.

**First boot is slow.**
The first `docker compose up --build` clones the starter and installs all dependencies (~1100 packages). Subsequent starts reuse the cached `node_modules` volume and are fast.

## Notes

- `medusa-app/` is gitignored — it's auto-generated from the starter. Your customizations live in there but aren't tracked by git.
- The npm mirror `https://registry.npmmirror.com` is used during the Docker build to avoid GitHub Actions IP rate-limiting (429) from npmjs.org.
- In dev mode, Redis modules are not configured (Medusa uses in-memory defaults). This is fine for development. For production, configure Redis in `medusa-config.ts`.
