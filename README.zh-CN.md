# Medusa Bun Dev

[English](README.md) | [中文](README.zh-CN.md)

---

[Medusa v2](https://github.com/medusajs/medusa) 开发环境，源码挂载 + 热重载 + 零手动配置。基于 `oven/bun:1.4-debian`，构建时克隆官方 `medusa-starter-default`，启动后可在宿主机编辑源码，容器内即时热重载。

## 特性

- **Bun 1.4 Debian 运行时** — `oven/bun:1.4-debian`，apt 使用清华 TUNA 源，Bun 包使用 npmmirror.com。
- **源码挂载** — `./medusa-app/` 首次启动自动初始化；在宿主机编辑文件，容器内 dev server 热重载。
- **纯 Bun** — `bun install` 安装依赖，`bun run dev` 启动 dev server，无需 Node.js。
- **Bun #17303 修复** — entrypoint 补丁 `@jridgewell/trace-mapping`，将 `-1` 列值钳制为 `0`（Bun 在容器中崩溃的 bug）。
- **容器内 Vite HMR** — `medusa-config.ts` 设置 `hmr.clientPort: 9000`（后端代理 WebSocket）+ `resolve.alias` 修复 Medusa i18n 路径解析 bug。
- **一键启动** — 首次启动自动迁移 + 自动创建管理员账号。
- **两种 compose 方案** — 自包含（postgres + redis + medusa）或 1Panel（外部 postgres/redis）。

## 快速开始（自包含）

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. 配置密钥
cp .env.example .env
# 用 openssl rand -hex 32 替换 change_me 值

# 2. 构建并启动（首次启动初始化源码 + 安装依赖）
docker compose up -d --build

# 3. 等待约 60 秒，打开管理后台
open http://localhost:9000/app
# 用 admin@medusa.local / SuperSecret123 登录
```

首次启动后，源码在 `./medusa-app/`。编辑 `medusa-app/src/` 下任意文件 — 后端通过文件监听器热重载，管理后台通过 Vite HMR 热重载。

## 快速开始（1Panel — 外部 postgres/redis）

```bash
git clone https://github.com/SOVLOOKUP/bun-medusa.git
cd bun-medusa

# 1. 配置密钥 + 1Panel 数据库/Redis 主机
cp .env.example .env
# 编辑 .env:
#   - JWT_SECRET / COOKIE_SECRET
#   - POSTGRES_HOST / POSTGRES_PASSWORD
#   - REDIS_HOST / REDIS_PASSWORD

# 2. 仅启动 medusa（通过 1panel-network 使用外部 postgres + redis）
docker compose -f docker-compose.1panel.yml up -d --build

# 3. 打开管理后台
open http://<服务器IP>:9000/app
```

前提条件：
- 1Panel 已部署 PostgreSQL 和 Redis/Valkey，均加入 `1panel-network`。
- PostgreSQL 中已创建数据库 `medusa` 并授权用户 `medusa`。
- Docker 网络 `1panel-network` 存在。

## 默认管理员凭证

| 字段 | 默认值 |
|---|---|
| 邮箱 | `admin@medusa.local` |
| 密码 | `SuperSecret123` |

在 `.env` 中覆盖：
```bash
MEDUSA_ADMIN_EMAIL=your@email.com
MEDUSA_ADMIN_PASSWORD=YourStrongPassword
```

## 配置

必填环境变量（见 [.env.example](.env.example)）：

| 变量 | 用途 |
|---|---|
| `JWT_SECRET` | JWT 签名密钥（>= 32 字节 hex） |
| `COOKIE_SECRET` | 会话 cookie 签名密钥（>= 32 字节 hex） |
| `STORE_CORS` | 允许调用 Store API 的 storefront 源 |
| `ADMIN_CORS` | 允许调用 Admin API 的管理后台源 |
| `AUTH_CORS` | Auth API CORS（通常是 admin + storefront 源的并集） |

1Panel 方案还需要：

| 变量 | 用途 |
|---|---|
| `POSTGRES_USER` | PostgreSQL 用户名 |
| `POSTGRES_PASSWORD` | PostgreSQL 密码 |
| `POSTGRES_HOST` | 1panel-network 上的 PostgreSQL 容器名 |
| `POSTGRES_DB` | PostgreSQL 数据库名 |
| `REDIS_PASSWORD` | Redis/Valkey 密码 |
| `REDIS_HOST` | 1panel-network 上的 Redis 容器名 |

### CORS 速查表

| 变量 | 保护 | 调用方 |
|---|---|---|
| `STORE_CORS` | `/store/*` | 你的 storefront（Next.js 等） |
| `ADMIN_CORS` | `/admin/*` | 管理后台（`:9000/app`） |
| `AUTH_CORS` | `/auth/*` | 登录/注册（admin + storefront） |

源必须精确：`协议://主机:端口`。多个源用逗号分隔，不要空格。

## 文件结构

```
.
├── Dockerfile                  # Dev 镜像（Bun 1.4 Debian + 克隆 starter）
├── docker-entrypoint.sh        # 初始化源码、补丁 trace-mapping、创建管理员
├── docker-compose.yml          # postgres + redis + medusa（自包含）
├── docker-compose.1panel.yml   # 1Panel 方案（外部 postgres/redis）
├── .env.example                # 环境变量模板
└── medusa-app/                 # 自动初始化的源码（gitignore）
    ├── src/                    # 在这里编辑 — 容器内热重载
    ├── medusa-config.ts        # Vite HMR + i18n alias 配置
    ├── package.json
    └── ...
```

## 工作原理

### 构建时（Dockerfile）

1. `FROM oven/bun:1.4-debian`，配置清华 TUNA apt 源。
2. 仅安装 `git`（不装 nodejs/npm）。
3. 克隆 `medusa-starter-default` 到 `/app/medusa`。
4. 保存一份纯净副本到 `/app/medusa-seed`（用于首次启动初始化）。
5. `bun install`（完整依赖，包括 devDependencies）。
6. 设置 `BUN_CONFIG_REGISTRY=https://registry.npmmirror.com`。

### 首次启动（docker-entrypoint.sh）

1. 如果挂载目录中缺少 `package.json`，从 `/app/medusa-seed` 复制源码。
2. 如果 `node_modules` 为空，运行 `bun install`。
3. 补丁 `@jridgewell/trace-mapping` — 将 `-1` 列值钳制为 `0`（Bun bug #17303 修复）。
4. 从环境变量生成 `.env`（如果不存在）。
5. 给 `DATABASE_URL` 追加 `?sslmode=disable&connect_timeout=30`。
6. 创建管理员用户（已存在则跳过）。
7. 执行 `bun run dev`（即 `medusa develop`）。

### Vite 配置（medusa-config.ts）

容器环境下的两个修复：

1. **HMR** — `server.hmr.clientPort: 9000` 让 Vite 客户端通过 9000 端口连接（后端代理 WebSocket），而不是使用未暴露的随机端口。

2. **i18n 路径别名** — Medusa 的 Vite 插件生成的导入路径如 `/app/medusa/src/admin/i18n/index.ts`，Vite 去掉 `/app` base 前缀后变成 `/medusa/src/...`（不存在）。别名 `'/medusa/' -> '/app/medusa/'` 修复此问题。

## 常见问题

**管理后台空白 / Vite 连接错误。**
确保 `medusa-config.ts` 包含 `admin.vite` 配置（HMR clientPort + alias）。如果修改过，需重启容器 — Watcher 只重启后端，Vite 配置变更需要完整重启。

**`column must be greater than or equal to 0` 崩溃。**
这是 Bun bug #17303。entrypoint 自动补丁 `trace-mapping`。如果绕过 entrypoint，崩溃会重现。

**容器启动后立即退出。**
检查 `docker inspect <容器名> --format 'OOMKilled={{.State.OOMKilled}}'`。如果 `OOMKilled=true`，在 docker-compose.yml 的 medusa 服务中添加 `mem_limit: 2g`。

**启动后 `medusa-app/` 为空。**
entrypoint 在首次启动时初始化。如果删除了，停止容器、删除 `medusa_node_modules` 卷、重启：`docker compose down && docker volume rm medusa-bun_medusa_node_modules && docker compose up -d`。

**首次启动较慢。**
首次 `docker compose up --build` 需要克隆 starter 并安装全部依赖（约 1100 个包）。后续启动复用缓存的 `node_modules` 卷，速度很快。

## 注意事项

- `medusa-app/` 被 gitignore — 它是从 starter 自动生成的。你的自定义修改在里面，但不被 git 跟踪。
- Docker 构建时使用 npm 镜像 `https://registry.npmmirror.com`，避免 GitHub Actions IP 被 npmjs.org 限流（429）。
- dev 模式下不配置 Redis 模块（Medusa 使用内存默认值）。开发环境无需 Redis。生产环境请在 `medusa-config.ts` 中配置 Redis。
