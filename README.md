# Medusa Bun Image

[English](#english) | [中文](#中文)

---

<a id="english"></a>

## English

Auto-tracking, Bun-based Docker image for [Medusa](https://github.com/medusajs/medusa). A GitHub Actions workflow polls the npm registry every 6 hours; when a new version of `@medusajs/medusa` is published it bumps `.medusa-version`, tags `v<version>`, builds a slim production image with Bun, and pushes it to GHCR with `latest` / `major.minor` / `major` / `version` tags.

### Features

- **Bun alpine runtime** — `oven/bun:1-alpine` for both builder and runtime stages. Dependencies installed and the production server orchestrated through Bun.
- **Self-contained production build** — `medusa build` output is the runtime; no source mount, no dev server, admin dashboard compiled into the image and served from `:9000/app`.
- **Small footprint** — multi-stage build, `bun install --production`, and aggressive pruning of `*.d.ts` / `*.map` / tests / docs from `node_modules`.
- **Auto-tracking** — `.github/workflows/release.yml` polls `registry.npmjs.org/@medusajs/medusa/latest` every 6 hours and rebuilds automatically on new releases. Manual dispatch with a specific version is also supported.
- **Runtime entrypoint** ([docker-entrypoint-medusa.sh](docker-entrypoint-medusa.sh)) handles three pain-points so self-hosted deploys work out of the box:
  1. Appends `?sslmode=disable&connect_timeout=30` to `DATABASE_URL` (unless an explicit `sslmode=` is already present) to avoid MikroORM's 10 s SSL-handshake timeout against plain-TCP Postgres.
  2. When `REDIS_URL` is provided, rewrites `medusa-config.js` to replace the four memory-backed modules (`cache` / `event_bus` / `workflows` / `locking`) with their Redis-backed implementations.
  3. Overrides the session cookie `secure` / `sameSite` flags so HTTP login works (Medusa forces `secure:true` under `NODE_ENV=production`, which breaks browser login over plain HTTP). Set `MEDUSA_COOKIE_SECURE=true` to restore the production default behind trusted TLS.

### Quick start

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. Configure secrets
cp .env.example .env
# Replace the three change_me values with: openssl rand -hex 32

# 2. Bring up the stack (postgres + redis + medusa)
docker compose up -d

# 3. Run migrations (first time only)
docker compose run --rm medusa bunx medusa db:migrate

# 4. Create an admin user (first time only)
docker compose run --rm medusa \
  bunx medusa user -e admin@example.com -p YourPassword123

# 5. Open the admin dashboard
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
| `MEDUSA_COOKIE_SECURE` | `false` | Set `true` to enable `Secure` + `SameSite=lax` cookies (use behind TLS termination) |
| `CACHE_REDIS_URL` | unset | When set, registers a separate `caching-redis` module using this URL |

### File layout

```
.
├── .github/workflows/release.yml   # Auto-track + build pipeline
├── .medusa-version                 # Tracked version (e.g. 2.18.0)
├── Dockerfile                      # Multi-stage Bun build
├── docker-entrypoint-medusa.sh     # Runtime config patcher
├── docker-compose.yml              # postgres + redis + medusa
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

---

<a id="中文"></a>

## 中文

基于 [Bun](https://bun.sh) 的 [Medusa](https://github.com/medusajs/medusa) Docker 镜像,通过 GitHub Actions 自动追踪 Medusa 最新发布。每 6 小时轮询一次 npm registry,发现 `@medusajs/medusa` 新版本就自动 bump `.medusa-version`、打 `v<版本号>` tag、用 Bun 构建精简生产镜像并推送到 GHCR,同时维护 `latest` / `主版本.次版本` / `主版本` / `完整版本` 四个 tag。

### 特性

- **Bun alpine 运行时** —— builder 与 runtime 都基于 `oven/bun:1-alpine`,依赖安装与生产服务编排全部走 Bun。
- **自包含生产构建** —— `medusa build` 产物即运行时,无需挂载源码、无需 dev server,admin 后台已编译进镜像,通过 `:9000/app` 提供。
- **体积精简** —— 多阶段构建 + `bun install --production` + 对 `node_modules` 激进瘦身(删除 `*.d.ts` / `*.map` / 测试 / 文档等)。
- **自动追踪** —— [release.yml](.github/workflows/release.yml) 每 6 小时轮询 `registry.npmjs.org/@medusajs/medusa/latest`,新版本发布即自动重建。也支持手动指定版本触发。
- **运行时 entrypoint**([docker-entrypoint-medusa.sh](docker-entrypoint-medusa.sh))处理三个常见痛点,让 self-hosted 部署开箱即用:
  1. 自动给 `DATABASE_URL` 追加 `?sslmode=disable&connect_timeout=30`(若未显式指定 `sslmode=`),避免 MikroORM 在 plain-TCP Postgres 上 10 秒 SSL 握手超时。
  2. 当提供了 `REDIS_URL` 时,重写 `medusa-config.js`,把 4 个内存模块(`cache` / `event_bus` / `workflows` / `locking`)替换为对应的 Redis 实现。
  3. 覆盖 session cookie 的 `secure` / `sameSite` 标志以支持 HTTP 登录(Medusa 在 `NODE_ENV=production` 下强制 `secure:true`,导致 HTTP 下浏览器无法保存 cookie 无法登录)。设 `MEDUSA_COOKIE_SECURE=true` 可在可信 TLS 终止后恢复生产默认值。

### 快速开始

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. 配置密钥
cp .env.example .env
# 把三个 change_me 替换为:openssl rand -hex 32 生成的随机串

# 2. 启动全栈(postgres + redis + medusa)
docker compose up -d

# 3. 执行数据库迁移(仅首次)
docker compose run --rm medusa bunx medusa db:migrate

# 4. 创建管理员账号(仅首次)
docker compose run --rm medusa \
  bunx medusa user -e admin@example.com -p YourPassword123

# 5. 打开后台
open http://localhost:9000/app
```

### 镜像 tag

发布到 `ghcr.io/sovlookup/bun-medusa`:

| Tag | 含义 |
|---|---|
| `2.18.0` | 精确版本 |
| `2.18` | `2.18` 的最新 patch |
| `2` | `2` 的最新 minor |
| `latest` | 始终为最新发布版本 |

### 配置

必填环境变量(详见 [.env.example](.env.example)):

| 变量 | 用途 |
|---|---|
| `JWT_SECRET` | JWT 签名密钥(≥ 32 字节 hex) |
| `COOKIE_SECRET` | Session cookie 签名密钥(≥ 32 字节 hex) |
| `AUTH_MFA_ENCRYPTION_KEY` | MFA 加密密钥(≥ 32 字节 hex) |
| `STORE_CORS` | 允许调用 Store API 的 storefront 来源 |
| `ADMIN_CORS` | 允许调用 Admin API 的后台来源 |
| `AUTH_CORS` | Auth API 的 CORS(通常为 admin + storefront 来源的并集) |

由 [docker-compose.yml](docker-compose.yml) 提供:

| 变量 | 默认值 |
|---|---|
| `DATABASE_URL` | `postgres://postgres:postgres@postgres:5432/medusa-store` |
| `REDIS_URL` | `redis://redis:6379` |
| `NODE_ENV` | `production` |

可选:

| 变量 | 默认值 | 用途 |
|---|---|---|
| `MEDUSA_COOKIE_SECURE` | `false` | 设为 `true` 启用 `Secure` + `SameSite=lax` cookie(在 TLS 终止后面使用) |
| `CACHE_REDIS_URL` | 未设 | 设则额外注册一个使用该 URL 的 `caching-redis` 模块 |

### 目录结构

```
.
├── .github/workflows/release.yml   # 自动追踪 + 构建流水线
├── .medusa-version                 # 当前追踪版本(如 2.18.0)
├── Dockerfile                      # 多阶段 Bun 构建
├── docker-entrypoint-medusa.sh     # 运行时配置 patcher
├── docker-compose.yml              # postgres + redis + medusa
├── .env.example                    # 必填环境变量模板
└── .gitignore
```

### 自动追踪机制

[release.yml](.github/workflows/release.yml) 的 `track` job:

1. 每 6 小时(cron)轮询 `https://registry.npmjs.org/@medusajs/medusa/latest`。
2. 把返回的 `version` 字段与 `.medusa-version` 比对。
3. 不一致则:bump `.medusa-version`、提交 `chore: bump medusa to <版本>`、打 `v<版本>` tag、推送。
4. 同一次 workflow run 中接着触发 `build` job。

`build` job:

1. 在新 tag 上 checkout。
2. 执行 `docker/buildx build --build-arg MEDUSA_VERSION=<版本>`(默认 `linux/amd64`;设仓库变量 `PLATFORMS=linux/amd64,linux/arm64` 启用 arm64)。
3. 推送到 GHCR,打上述 4 个 tag。
4. 使用 GitHub Actions cache 复用层。

手动触发:Actions → release → Run workflow → 输入具体版本(如 `2.18.0`)。

### 本地开发 / 测试

```bash
# 本地构建镜像(与 CI 一致)
docker build --build-arg MEDUSA_VERSION=2.18.0 -t medusa-bun:local .

# 或拉取已发布镜像
docker pull ghcr.io/sovlookup/bun-medusa:2.18.0

# 进入镜像交互式 shell
docker run --rm -it --entrypoint sh ghcr.io/sovlookup/bun-medusa:2.18.0
```

### 故障排查

**`Could not connect to the database while running migrations. The connection timed out after 10 seconds.`**
entrypoint 会自动给 `DATABASE_URL` 追加 `?sslmode=disable&connect_timeout=30`。如果你绕过了 entrypoint(`--entrypoint` 覆盖),需要手动加 query 参数。

**后台登录没反应(点 Sign in 后又回到 `/app/login`)。**
由 `secure:true` session cookie 在 HTTP 下被浏览器拒绝导致。要么用镜像自带的 entrypoint(默认 `secure:false`),要么设 `MEDUSA_COOKIE_SECURE=true` 并在前面加 HTTPS。

**日志里出现 `redisUrl not found. A fake redis instance will be used.`。**
有 3 条这样的 info 是旧代码路径的遗留,无害。entrypoint 在 `REDIS_URL` 设定时会重写 `medusa-config.js`,把 4 个真实 Redis 模块(`event-bus-redis` / `cache-redis` / `workflow-engine-redis` / `locking-redis`)注册进去 —— 你应该能看到 4 条 `Connection to Redis ... established` 日志确认真实连接已建立。

**`/store/products` 返回 HTTP 400。**
这是预期行为 —— Medusa v2 要求 Store API 请求带 `x-publishable-api-key` header。在后台(Settings → API Key Management)创建 publishable API key,然后请求时加 `x-publishable-api-key: <key>`。

### 注意事项

- `track` job 用 `GITHUB_TOKEN` 推送版本 bump,**不会再次触发 workflows**(设计如此,避免循环);`build` job 在同一次 workflow run 里执行。
- 如果默认分支有保护,需要允许 `github-actions[bot]` 推送,或改用 PAT。
