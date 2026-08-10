# Medusa Bun 镜像

[English](README.md) | [中文](README.zh-CN.md)

---

基于 [Bun](https://bun.sh) 的 [Medusa](https://github.com/medusajs/medusa) Docker 镜像,通过 GitHub Actions 自动追踪 Medusa 最新发布。每 6 小时轮询一次 npm registry,发现 `@medusajs/medusa` 新版本就自动 bump `.medusa-version`、打 `v<版本号>` tag、用 Bun 构建精简生产镜像并推送到 GHCR,同时维护 `latest` / `主版本.次版本` / `主版本` / `完整版本` 四个 tag。

### 特性

- **Bun alpine 运行时** —— builder 与 runtime 都基于 `oven/bun:1-alpine`,依赖安装与生产服务编排全部走 Bun。
- **自包含生产构建** —— `medusa build` 产物即运行时,无需挂载源码、无需 dev server,admin 后台已编译进镜像,通过 `:9000/app` 提供。
- **体积精简** —— 多阶段构建 + `bun install --production` + 对 `node_modules` 激进瘦身(删除 `*.d.ts` / `*.map` / 测试 / 文档等)。
- **自动追踪** —— [release.yml](.github/workflows/release.yml) 每 6 小时轮询 `registry.npmjs.org/@medusajs/medusa/latest`,新版本发布即自动重建。也支持手动指定版本触发。
- **运行时 entrypoint**([docker-entrypoint-medusa.sh](docker-entrypoint-medusa.sh))处理四个常见痛点,让 self-hosted 部署开箱即用:
  1. 自动给 `DATABASE_URL` 追加 `?sslmode=disable&connect_timeout=30`(若未显式指定 `sslmode=`),避免 MikroORM 在 plain-TCP Postgres 上 10 秒 SSL 握手超时。
  2. 当提供了 `REDIS_URL` 时,重写 `medusa-config.js`,把 4 个内存模块(`cache` / `event_bus` / `workflows` / `locking`)替换为对应的 Redis 实现。
  3. 覆盖 session cookie 的 `secure` / `sameSite` 标志以支持 HTTP 登录(Medusa 在 `NODE_ENV=production` 下强制 `secure:true`,导致 HTTP 下浏览器无法保存 cookie 无法登录)。设 `MEDUSA_COOKIE_SECURE=true` 可在可信 TLS 终止后恢复生产默认值。
  4. 在 `medusa start` 之前自动执行 `medusa db:migrate`(幂等,已执行的迁移会跳过)。若数据库尚未就绪,容器退出,`restart: unless-stopped` 会自动重试直到数据库可用。设 `MEDUSA_AUTO_MIGRATE=false` 可关闭。

### 快速开始

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. 配置密钥
cp .env.example .env
# 把三个 change_me 替换为:openssl rand -hex 32 生成的随机串

# 2. 启动全栈(postgres + redis + medusa)
#    迁移在首次启动时自动执行,无需手动操作。
docker compose up -d

# 3. 创建管理员账号(仅首次)
docker compose run --rm medusa \
  bunx medusa user -e admin@example.com -p YourPassword123

# 4. 打开后台
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
| `MEDUSA_AUTO_MIGRATE` | `true` | 在 `medusa start` 前自动执行 `medusa db:migrate`(幂等) |
| `MEDUSA_COOKIE_SECURE` | `false` | 设为 `true` 启用 `Secure` + `SameSite=lax` cookie(在 TLS 终止后面使用) |
| `CACHE_REDIS_URL` | 未设 | 设则额外注册一个使用该 URL 的 `caching-redis` 模块 |

### 目录结构

```
.
├── .github/workflows/release.yml   # 自动追踪 + 构建流水线
├── .medusa-version                 # 当前追踪版本(如 2.18.0)
├── Dockerfile                      # 多阶段 Bun 构建
├── docker-entrypoint-medusa.sh     # 运行时配置 patcher + 自动迁移
├── docker-compose.yml              # postgres + redis + medusa(自包含)
├── docker-compose.1panel.yml       # 1Panel 版(复用外部 postgres/redis)
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
