# Medusa for 1Panel

Medusa is an open-source, headless commerce backend for modern e-commerce, built with TypeScript and powered by Bun.

## Features

- **Headless Commerce**: Decoupled architecture, use any frontend
- **Multi-currency & Multi-language**: Built-in internationalization
- **Product Catalog**: Products, variants, categories, collections
- **Order Management**: Full order lifecycle management
- **Customer Management**: Customer accounts, addresses, groups
- **Promotions**: Campaigns, discounts, gift cards
- **Payment Providers**: Stripe, PayPal, and more
- **Fulfillment**: Shipping options and tracking
- **Zero-config setup**: Set `PUBLIC_URL` (external URL) ONCE in 1Panel form.
  CORS origins and admin redirects are auto-derived inside the container.
- **Auto-generated secrets**: Leave `JWT_SECRET` / `COOKIE_SECRET` /
  `AUTH_MFA_ENCRYPTION_KEY` empty and the entrypoint generates strong random
  values on first boot and persists them — no `openssl rand` needed.

## Quick Start (1Panel)

1. Install **PostgreSQL** and **Redis** via 1Panel App Store
2. Download the Medusa app package (`.tar.gz` or `.zip`) from GitHub Releases
3. Upload to 1Panel: `/opt/1panel/resource/apps/local/medusa`
4. Click **Update App List** in 1Panel App Store
5. Install Medusa from the local app list
6. In the install form, fill **at least**:
   - `Postgres/Redis connection info` (hosts + passwords)
   - `External URL` = browser-facing origin, e.g. `https://medusa.example.com:8443`
   - Credentials/secrets fields **can be left blank** — they get auto-generated.

## Docker Image

The Docker image is automatically built and published to GitHub Container Registry:

```
ghcr.io/<your-github-username>/bun-medusa:<version>
ghcr.io/<your-github-username>/bun-medusa:latest
```

### Manual Deployment (without 1Panel)

Use `docker-compose.prod.yml` in the top-level repo.  Minimal environment
variables (derived from `BASE_URL`) — no per-origin CORS boilerplate:

```yaml
services:
  medusa:
    image: ghcr.io/<your-github-username>/bun-medusa:latest
    container_name: medusa
    restart: unless-stopped
    ports:
      - "9000:9000"
    environment:
      NODE_ENV: production
      DATABASE_URL: postgres://user:pass@postgres:5432/medusa?sslmode=disable
      REDIS_URL: redis://redis:6379
      # ⭐ 写这一次 → STORE_CORS / ADMIN_CORS / AUTH_CORS / ADMIN_URL 自动推导
      BASE_URL: https://medusa.example.com
      # 密钥留空自动生成（建议长期部署固定一份，避免容器重建导致 JWT 会话/MFA token 失效）
      # JWT_SECRET=
      # COOKIE_SECRET=
      # AUTH_MFA_ENCRYPTION_KEY=
      MEDUSA_ADMIN_EMAIL: admin@example.com
      MEDUSA_ADMIN_PASSWORD: your-admin-password
    volumes:
      - ./data:/app/medusa
```

## Environment Variables

| Variable                | Description                                                                      | Required |
| ----------------------- | -------------------------------------------------------------------------------- | -------- |
| `DATABASE_URL`          | PostgreSQL connection URL                                                        | Yes      |
| `REDIS_URL`             | Redis connection URL                                                             | Yes      |
| `BASE_URL` / `PUBLIC_URL` | Public origin (auto-derives CORS).  One-line replacement for the three *_CORS.  | Yes (in 1Panel install form it's PUBLIC_URL) |
| `JWT_SECRET`            | JWT signing secret.  **Auto-generated if empty.**                                | No       |
| `COOKIE_SECRET`         | Session cookie secret.  **Auto-generated if empty.**                             | No       |
| `AUTH_MFA_ENCRYPTION_KEY` | MFA encryption key.  **Auto-generated if empty.**  (32+ bytes hex recommended) | No       |
| `MEDUSA_ADMIN_EMAIL`    | Admin email for initial setup                                                    | No       |
| `MEDUSA_ADMIN_PASSWORD` | Admin password for initial setup                                                 | No       |
| `STORE_CORS`            | Allowed origins for Store API.  *Derived from BASE_URL when unset.*              | No       |
| `ADMIN_CORS`            | Allowed origins for Admin API.  *Derived from BASE_URL when unset.*              | No       |
| `AUTH_CORS`             | Allowed origins for Auth API.  *Derived from BASE_URL when unset.*               | No       |

## Links

- [Medusa Documentation](https://docs.medusajs.com/)
- [Medusa GitHub](https://github.com/medusajs/medusa)
