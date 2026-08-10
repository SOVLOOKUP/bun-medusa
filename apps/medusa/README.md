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

## Quick Start (1Panel)

1. Install **PostgreSQL** and **Redis** via 1Panel App Store
2. Download the Medusa app package (`.tar.gz` or `.zip`) from GitHub Releases
3. Upload to 1Panel: `/opt/1panel/resource/apps/local/medusa`
4. Click **Update App List** in 1Panel App Store
5. Install Medusa from the local app list

## Docker Image

The Docker image is automatically built and published to GitHub Container Registry:

```
ghcr.io/<your-github-username>/bun-medusa:<version>
ghcr.io/<your-github-username>/bun-medusa:latest
```

### Manual Deployment (without 1Panel)

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
      JWT_SECRET: your-jwt-secret
      COOKIE_SECRET: your-cookie-secret
      STORE_CORS: http://your-domain.com
      ADMIN_CORS: http://your-domain.com,http://localhost:9000
      AUTH_CORS: http://your-domain.com,http://localhost:9000
      MEDUSA_ADMIN_EMAIL: admin@example.com
      MEDUSA_ADMIN_PASSWORD: your-admin-password
    volumes:
      - ./data:/app/medusa/.medusa
```

## Environment Variables

| Variable                | Description                      | Required |
| ----------------------- | -------------------------------- | -------- |
| `DATABASE_URL`          | PostgreSQL connection URL        | Yes      |
| `REDIS_URL`             | Redis connection URL             | Yes      |
| `JWT_SECRET`            | JWT signing secret               | Yes      |
| `COOKIE_SECRET`         | Cookie encryption secret         | Yes      |
| `MEDUSA_ADMIN_EMAIL`    | Admin email for initial setup    | No       |
| `MEDUSA_ADMIN_PASSWORD` | Admin password for initial setup | No       |
| `STORE_CORS`            | Allowed origins for Store API    | Yes      |
| `ADMIN_CORS`            | Allowed origins for Admin API    | Yes      |
| `AUTH_CORS`             | Allowed origins for Auth API     | Yes      |

## Links

- [Medusa Documentation](https://docs.medusajs.com/)
- [Medusa GitHub](https://github.com/medusajs/medusa)
