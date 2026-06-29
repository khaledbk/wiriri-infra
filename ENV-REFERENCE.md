# Environment variable reference (per VPS)

What each environment variable is **for** — names and usage only, **never values**.
Source of truth for values is **Infisical** (3 stages: dev/staging/prod); on-box `.env` files are
materialized by `get-env.sh` before `docker compose up`. Reflects the post-cleanup state
(see `../docs/audit/INFISICAL-KEY-AUDIT-2026-06-29.md`).

| VPS | Runs | Secret source |
|-----|------|---------------|
| web-01 (.3) | nginx edge · webapp · admin | Infisical: **webapp** + **admin** projects |
| api-01 (.4) | NestJS backend · Redis · exporters | Infisical: **backend** project |
| db-01 (.5) | PostgreSQL | on-box postgres config (DSN consumed by backend) |
| storage-01 (.7) | MinIO · imgproxy | on-box `.env` / `imgproxy.env` |
| monitor-01 (.6) | Prometheus · Grafana | on-box config |

---

## web-01 — webapp (Infisical project `webapp`)

Next.js public vars are inlined at **build** time; `NEXTAUTH_SECRET` is read at **runtime** by NextAuth.

| Variable | Usage |
|---|---|
| `NEXTAUTH_SECRET` | NextAuth session JWT signing/encryption secret (runtime) |
| `NEXT_PUBLIC_BACKEND_DOMAIN` | GraphQL/API host the webapp calls (`api.wiriri.com`) + CSP connect-src |
| `NEXT_PUBLIC_MAIN_DOMAIN` | Canonical site domain (links, cookies, SEO) |
| `NEXT_PUBLIC_WEBAPP_URL` | Absolute base URL of the webapp (redirects, canonical, share links) |
| `NEXT_PUBLIC_ENVIRONMENT` | Runtime environment flag (dev/staging/prod gating) |
| `NEXT_PUBLIC_GOOGLE_API_KEY` | Google API key (Places/geocoding used in search & listing forms) |
| `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` | Google Maps JS key (map rendering) |
| `NEXT_PUBLIC_GTM_ID` | Google Tag Manager container → GA4 (`GTM-TFT37X7X`) |

> Pre-launch flag: `NEXT_PUBLIC_PAYMENT_GATEWAY_URL` is read by `middleware.ts` (CSP connect-src) but
> not currently set — set it before live payments, or confirm Konnect is redirect-only.

## web-01 — admin (Infisical project `admin`)

| Variable | Usage |
|---|---|
| `NEXTAUTH_SECRET` | Admin NextAuth session secret (runtime; rotated 2026-06-29, unique per env) |
| `NEXT_PUBLIC_BACKEND_DOMAIN` | API host the admin calls |
| `NEXT_PUBLIC_MAIN_DOMAIN` | Canonical domain |
| `NEXT_PUBLIC_ENVIRONMENT` | Environment flag |

## web-01 — nginx edge

No env vars. TLS via Let's Encrypt files; GeoIP2 reads a local `.mmdb` (DB-IP Lite) in-process.

---

## api-01 — backend (Infisical project `backend`)

### Core / runtime
| Variable | Usage |
|---|---|
| `NODE_ENV` | Node environment (production) |
| `PORT` | Backend listen port (`4001`) |
| `TZ` | Process timezone (`Africa/Tunis`) |
| `DOMAIN` | Base domain used to build absolute URLs |
| `BACKEND_URL` | Backend's own public base URL (callbacks, links) |
| `COUNTRY_CODE` | Default country (Tunisia) for formatting/validation |

### Database & cache
| Variable | Usage |
|---|---|
| `DATABASE_URL` | PostgreSQL DSN → db-01 (`:5432`) |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` | Redis (cache, queues/BullMQ) on api-01 |

### Auth / JWT
| Variable | Usage |
|---|---|
| `JWT_SECRET` | Signs app access/refresh tokens |
| `JWT_EXPIRES_IN` | Access token TTL |
| `AUTH_LOGIN_RATE_LIMIT_MAX_ATTEMPTS` / `_WINDOW_SEC` | Login brute-force throttle |
| `AUTH_FORGOT_PASSWORD_RATE_LIMIT_MAX_ATTEMPTS` / `_WINDOW_SEC` | Forgot-password throttle |

### Social login & maps
| Variable | Usage |
|---|---|
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_CALLBACK_URL` | Google OAuth |
| `GOOGLE_MAPS_API_KEY` | Server-side geocoding |
| `FACEBOOK_APP_ID` / `FACEBOOK_APP_SECRET` / `FACEBOOK_CALLBACK_URL` | Facebook OAuth |

### Storage / CDN (MinIO + imgproxy)
| Variable | Usage |
|---|---|
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | MinIO service-account creds (`wiriri_backend_minio`) |
| `S3_ENDPOINT` | Private MinIO endpoint (`10.130.18.7:9000`) for put/del/presign-mint |
| `S3_PUBLIC_ENDPOINT` | Public host presigned URLs are signed against (`cdn.wiriri.com`) |
| `S3_REGION` | S3 region for SigV4 |
| `S3_BUCKET_IMAGES` / `S3_BUCKET_PRIVATE` | `wiriri-prod-images` / `wiriri-prod-private` buckets |
| `S3_FORCE_PATH_STYLE` | Path-style addressing (MinIO) |
| `CDN_PUBLIC_URL` | Base CDN URL the resolver builds `/img/` links from |
| `IMGPROXY_KEY` / `IMGPROXY_SALT` | Sign imgproxy transform URLs (must match storage-01) |

### Payments (Konnect)
| Variable | Usage |
|---|---|
| `PAYMENT_GATEWAY` | Active gateway selector |
| `KONNECT_API_KEY` / `KONNECT_WALLET_ID` / `KONNECT_BASE_URL` | Konnect API creds + endpoint |
| `KONNECT_WEBHOOK_URL` | Where Konnect posts payment status |
| `PAYMENT_SUCCESS_URL` / `PAYMENT_FAILURE_URL` | Post-payment redirect targets |

### Mailer
| Variable | Usage |
|---|---|
| `MAIL_PROVIDER` | `smtp` (nodemailer) or `sendgrid` (native SDK) — selects the transport |
| `SENDGRID_API_KEY` | SendGrid API key (when `MAIL_PROVIDER=sendgrid`) |
| `MAILER_HOST` / `MAILER_PORT` / `MAILER_ENCRYPTION` | SMTP relay connection |
| `MAILER_USERNAME` / `MAILER_PASSWORD` / `MAILER_AUTH_MODE` | SMTP auth |
| `MAILER_FROM` | Sender address (`contact@wiriri.com`) — used by both transports |
| `MAILER_COMPANY_NAME` | Brand name in email templates |
| `MAILER_DISABLE_DELIVERY` | Kill-switch (log instead of send) |
| `MAILER_VERBOSE_LOGS` | Verbose transport logging |
| *(optional)* `MAILER_LOGO_URL` | Email logo; unset → code default `wiriri.com/...` |
| *(optional)* `MAILER_DEV_REDIRECT_TO` | Redirect all mail to one inbox in non-prod |

### Documents (PDF) & misc
| Variable | Usage |
|---|---|
| `PDF_SIGNING_SECRET` | Signs PDF download links (invoice/receipt/refund) |
| `PDF_DOWNLOAD_BASE_URL` | Base URL for generated-document links |
| `PDF_STORAGE_ROOT` | Storage key prefix for generated PDFs |
| `EXCHANGE_RATES_API_KEY` | FX provider for currency conversion |
| `WEB_APP_URL` / `WEB_ADMIN_URL` | Cross-link to the webapp / admin from emails & redirects |
| `FIXTURES_{ADMIN,GUEST,HOST,OPERATOR}_{EMAIL,PASSWORD}` | Seed/bootstrap accounts (keep disposable; reset prod admin) |

> Optional (use code defaults if unset): `REDIS_DB`, `STORAGE_PRESIGN_TTL_UPLOAD`,
> `STORAGE_PRESIGN_TTL_DOWNLOAD`, `PAYMENT_WEBHOOK_PROCESSED_TTL_SEC`,
> `PAYMENT_WEBHOOK_RATE_LIMIT_MAX_ATTEMPTS`, `PAYMENT_WEBHOOK_RATE_LIMIT_WINDOW_SEC`, `WEB_MOBILE_URL`.

---

## db-01 — PostgreSQL (on-box)

| Variable | Usage |
|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Postgres superuser + app DB (on-box init) |

Consumed remotely by the backend via `DATABASE_URL`. Prod DB is `wiriri_prod`; bind to the private
VPC IP; allow `:5432` only from api-01 (`10.130.18.4/32`). `postgres_exporter` exposes `:9187`.

---

## storage-01 — MinIO + imgproxy (on-box `.env` / `imgproxy.env`)

| Variable | Usage |
|---|---|
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | MinIO root (bootstrap only; app uses the scoped service account) |
| `IMGPROXY_KEY` / `IMGPROXY_SALT` | Validate signed transform URLs (must match the backend) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | imgproxy → MinIO read-only account (`wiriri_imgproxy_ro`) |
| `IMGPROXY_BIND` / `IMGPROXY_USE_S3` / `IMGPROXY_S3_ENDPOINT` / `IMGPROXY_S3_REGION` | imgproxy ↔ MinIO wiring |
| `IMGPROXY_ALLOWED_SOURCES` | Source-lock to `s3://wiriri-prod-images/` |
| `IMGPROXY_MAX_SRC_RESOLUTION` / `IMGPROXY_STRIP_METADATA` / `IMGPROXY_ENABLE_WEBP_DETECTION` | Decompression-bomb guard · EXIF strip · WebP |

Both bind the private IP; the only public path in is `cdn.wiriri.com` via web-01 nginx.

---

## monitor-01 — Prometheus + Grafana (on-box)

| Variable | Usage |
|---|---|
| `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin login |
| `GF_SERVER_ROOT_URL` | Grafana public URL (behind monitor-01 nginx) |

Prometheus scrape targets are in `prometheus.yml` (not env): node-exporter `:9100` on every host,
`redis_exporter:9121` (api-01), `postgres_exporter:9187` (db-01).

---

## Conventions

- **Never commit values** — Infisical only; `.gitignore` blocks `.env`/certs/data.
- Keys mirror across **dev/staging/prod**; prod may add a few. `get-env.sh` writes `./*/.env`
  (chmod 600) on the box before `docker compose up`.
- After changing a secret, the consuming container must be **recreated** to pick it up.
