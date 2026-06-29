# wiriri-infra

Infrastructure-as-config and operational runbooks for the **Wiriri production stack**.
One repository per the DevOps team holding every VPS's Docker configuration, the edge/CDN
design, the network and firewall matrix, and the per-host setup runbooks.

> **Provider:** CloudAxion · **Region:** Tunis `TUN01` · **Private VPC:** `wiriri-prod-vpc`
> `10.130.18.0/24` · **OS (all hosts):** Ubuntu 24.04 · **Admin user:** `tvacadmin`
> **Billing:** TND · Captured from a read-only audit of the live boxes (latest: 2026-06-29).

---

## Table of contents

- [1. Architecture overview](#1-architecture-overview)
- [2. Hosts](#2-hosts)
- [3. Edge layer — web-01](#3-edge-layer--web-01)
- [4. Application layer — api-01](#4-application-layer--api-01)
- [5. Data layer — db-01](#5-data-layer--db-01)
- [6. Storage & CDN — storage-01](#6-storage--cdn--storage-01)
- [7. Observability — monitor-01](#7-observability--monitor-01)
- [8. Network & firewall matrix](#8-network--firewall-matrix)
- [9. Security model](#9-security-model)
- [10. TLS & DNS](#10-tls--dns)
- [11. Secrets (Infisical)](#11-secrets-infisical)
- [12. Deploy & runbooks](#12-deploy--runbooks)
- [13. Repository layout](#13-repository-layout)

---

## 1. Architecture overview

Five single-purpose VPSs share one private VPC and talk directly over it. **`web-01` is the
only box exposed to the internet** (80/443); everything else is reachable only inside the VPC
(plus SSH). All public DNS — `wiriri.com`, `www`, `api`, `admin`, `cdn` — resolves to `web-01`,
which terminates TLS and reverse-proxies to the right upstream.

```mermaid
flowchart TB
    Internet(["Internet"])

    subgraph VPC["wiriri-prod-vpc · 10.130.18.0/24 · Tunis TUN01"]
        direction TB

        subgraph WEB["web-01 · .3 · public 80/443"]
            NGINX["nginx edge<br/>+ geoip2 module"]
            WEBAPP["webapp<br/>Next.js :3000"]
            ADMIN["admin<br/>Next.js :3000"]
        end

        subgraph API["api-01 · .4"]
            BACKEND["backend<br/>NestJS :4001"]
            REDIS["redis :6379<br/>(localhost)"]
        end

        subgraph DB["db-01 · .5"]
            PG["PostgreSQL :5432"]
        end

        subgraph STO["storage-01 · .7"]
            MINIO["MinIO :9000/:9001"]
            IMGPROXY["imgproxy :8080"]
        end

        subgraph MON["monitor-01 · .6"]
            PROM["Prometheus + Grafana"]
        end
    end

    Internet -->|"443 · wiriri/www/admin/api/cdn"| NGINX
    NGINX -->|"wiriri.com + X-Geo-EEA"| WEBAPP
    NGINX -->|"admin.wiriri.com"| ADMIN
    NGINX -->|"api.wiriri.com to :4001"| BACKEND
    NGINX -->|"cdn /img to :8080"| IMGPROXY
    NGINX -->|"cdn presigned to :9000"| MINIO
    BACKEND -->|":5432"| PG
    BACKEND -->|":6379"| REDIS
    BACKEND -->|"presign / proxy :9000"| MINIO
    IMGPROXY -->|"localhost :9000"| MINIO
    PROM -.->|"scrape :9100/:9121/:9187"| API
    PROM -.->|scrape| DB
    PROM -.->|scrape| STO
    PROM -.->|scrape| WEB
```

---

## 2. Hosts

| Host | Public IP (Floating) | Private IP | Size | Est. cost | Role |
|------|----------------------|------------|------|-----------|------|
| **wiriri-prod-web-01** | 102.207.250.149 | 10.130.18.3 | 1 vCPU · 1 GB · 30 GB | TND 37 | nginx edge (+geoip2) · webapp · admin |
| **wiriri-prod-api-01** | 102.207.250.152 | 10.130.18.4 | 1 vCPU · 1 GB · 20 GB | TND 32 | NestJS backend `:4001` · Redis · exporters |
| **wiriri-prod-db-01** | 102.207.250.154 | 10.130.18.5 | 1 vCPU · 1 GB · 20 GB | TND 32 | PostgreSQL `:5432` · postgres_exporter |
| **wiriri-prod-monitor-01** | 102.207.250.159 | 10.130.18.6 | 1 vCPU · 1 GB · 20 GB | TND 32 | Prometheus · Grafana |
| **wiriri-prod-storage-01** | 102.207.250.162 | 10.130.18.7 | 1 vCPU · 0.5 GB · 20 GB | TND 26 | MinIO `:9000/:9001` · imgproxy `:8080` |

Each host has a **dedicated cloud firewall** (`wiriri-prod-<role>-fw`) and a **Floating IP**.
Only `web-01` and `monitor-01` accept public HTTP/HTTPS; the rest expose `:22` only.

---

## 3. Edge layer — web-01

The single public door. Runs a **custom nginx image** (stock nginx + compiled
`ngx_http_geoip2_module` + baked DB-IP IP-to-Country Lite DB), the **webapp**, and the **admin**
containers. nginx terminates TLS for all five hostnames and reverse-proxies each to its upstream.

**Containers:** `wiriri-prod-nginx` (build `./nginx`), `wiriri-prod-webapp`
(`ghcr.io/khaledbk/wiriri-webapp:prod`, `127.0.0.1:3001->3000`), `wiriri-prod-admin`
(`ghcr.io/khaledbk/wiriri-admin:prod`, `127.0.0.1:3002->3000`), `node_exporter`.

### Request routing

| Hostname | Upstream | Notes |
|----------|----------|-------|
| `wiriri.com` / `www` | `webapp:3000` | injects `X-Geo-EEA` (see below) |
| `admin.wiriri.com` | `admin:3000` | |
| `api.wiriri.com` | `10.130.18.4:4001` | backend |
| `cdn.wiriri.com` `/img/` | `10.130.18.7:8080` | imgproxy, edge-cached 30d |
| `cdn.wiriri.com` `/wiriri-prod-*` | `10.130.18.7:9000` | MinIO presigned passthrough |

### GeoIP2 → consent signal

nginx resolves the visitor's country from their IP (DB-IP Lite, `auto_reload 60m`) and injects
an **`X-Geo-EEA`** header into the `wiriri.com` upstream. The webapp reads it to set the Google
**Consent Mode v2** default server-side — GDPR/ePrivacy-safe for EEA/UK, auto-grant elsewhere.

```mermaid
flowchart LR
    REQ["client request"] --> GEO{"geoip2 lookup<br/>country ISO"}
    GEO -->|"EU27 / EEA / UK / unknown"| EEA["X-Geo-EEA: 1<br/>consent required"]
    GEO -->|"confirmed non-EEA"| NEEA["X-Geo-EEA: 0<br/>auto-grant"]
    EEA --> WEBAPP["webapp · Consent Mode v2 default"]
    NEEA --> WEBAPP
```

The geo DB needs **no license key** (DB-IP Lite, CC BY 4.0 — *IP Geolocation by DB-IP*) and is
refreshed monthly via `nginx/refresh-geoip.sh`. Build/verify steps: [`web-01/nginx/README.md`](web-01/nginx/README.md).

---

## 4. Application layer — api-01

NestJS backend, reached only by `web-01` nginx for `api.wiriri.com` over the VPC on `:4001`.
Co-located **Redis** (cache/queues, published on `127.0.0.1:6379` only) and Prometheus exporters.

**Containers:** `wiriri-prod-backend` (`:4001`), `wiriri-prod-redis` (`redis:7`),
`wiriri-prod-redis-exporter` (`:9121`), `node_exporter` (`:9100`). Backend reads
`./backend/.env` (Infisical-sourced). Connects to Postgres on `10.130.18.5:5432` and to MinIO on
`10.130.18.7:9000` for presigned uploads, ID/KYC proxy, and PDF storage.

> Hardening note: `redis.conf` ships `bind 0.0.0.0` + `protected-mode no`, but the port is
> published only on loopback, so Redis is not VPC-exposed. Re-tighten the conf to `bind 127.0.0.1`
> to match the runbook.

---

## 5. Data layer — db-01

PostgreSQL primary, the system of record. Reached **only** from `api-01` (`.4`) over the VPC on
`:5432`. `postgres_exporter` (`:9187`) and `node_exporter` (`:9100`) are scraped by `monitor-01`.

- Bind Postgres to the private VPC IP; firewall allows `:5432` from `10.130.18.4/32` only.
- Backend DSN: `postgresql://wiriri_app:***@10.130.18.5:5432/wiriri_prod` (Infisical).
- Prod DB is `wiriri_prod` — **never hand-touch**; backups + a tested restore are a launch gate.

Runbook: [`runbooks/wiriri-prod-db-01-setup-updated.md`](runbooks/wiriri-prod-db-01-setup-updated.md).

---

## 6. Storage & CDN — storage-01

Self-hosted object storage and on-the-fly image transforms — replaces Cloudinary. **MinIO** holds
all platform files; **imgproxy** serves resized/WebP variants. Both bind the private IP only;
the **only** public path in is `cdn.wiriri.com` via `web-01` nginx.

**Buckets:** `wiriri-prod-images` (public-read via cdn/imgproxy) · `wiriri-prod-private`
(ID/KYC + PDFs, never on cdn). **Containers:** `wiriri-prod-minio` (`:9000` API, `:9001`
console), `wiriri-prod-imgproxy` (`:8080`, source-locked to `s3://wiriri-prod-images/`, EXIF
stripped, 30 MP bomb guard), `node_exporter`.

```mermaid
sequenceDiagram
    participant B as Browser
    participant N as web-01 nginx (cdn)
    participant I as imgproxy :8080
    participant M as MinIO :9000
    B->>N: GET /img/<sig>/resize/...
    N->>N: check edge cache (30d)
    alt cache miss
        N->>I: proxy
        I->>M: fetch s3://wiriri-prod-images/<key>
        M-->>I: original
        I-->>N: transformed WebP
        N-->>B: 200 + X-Cache MISS then HIT
    else cache hit
        N-->>B: 200 + X-Cache HIT
    end
    B->>N: PUT/GET /wiriri-prod-*/<key>?X-Amz-...
    N->>M: presigned passthrough (sig enforced by MinIO)
    M-->>B: 200 / 403
```

Compose: [`storage-01/docker-compose.yml`](storage-01/docker-compose.yml) (MinIO) +
[`storage-01/docker-compose.imgproxy.yml`](storage-01/docker-compose.imgproxy.yml) (imgproxy,
standalone so it never touches the MinIO stack). Spec: `../docs/spec/SPEC-2026-06-26-storage-minio-cdn.md`.

---

## 7. Observability — monitor-01

Prometheus + Grafana. Scrapes `node_exporter` (`:9100`) on every host, plus `redis_exporter`
(`:9121`, api-01) and `postgres_exporter` (`:9187`, db-01). Add **imgproxy** as a scrape target.
Grafana/Prometheus UI is reachable on `monitor-01` `:80/:443`.

```mermaid
flowchart LR
    PROM["Prometheus<br/>monitor-01 .6"]
    PROM -->|":9100"| W["web-01 .3"]
    PROM -->|":9100"| A["api-01 .4"]
    PROM -->|":9121 redis"| A
    PROM -->|":9100 + :9187 pg"| D["db-01 .5"]
    PROM -->|":9100"| S["storage-01 .7"]
    PROM -->|":9100"| M["monitor-01 .6"]
    PROM --> GRAF["Grafana dashboards"]
```

Runbook: [`runbooks/wiriri-prod-monitor-01-setup.md`](runbooks/wiriri-prod-monitor-01-setup.md).

---

## 8. Network & firewall matrix

Each host has a dedicated cloud firewall; default-deny inbound, allow-all outbound. Live rules:

| Firewall (host) | Inbound allowed | Source |
|-----------------|-----------------|--------|
| **web-fw** (.3) | 22, 80, 443 | All IP |
| | 9100 | 10.130.18.6/32 (monitor) |
| **api-fw** (.4) | 22 | All IP |
| | 4001 | 10.130.18.3/32 (web) |
| | 9100, 9121 | 10.130.18.6/32 (monitor) |
| **db-fw** (.5) | 22 | All IP |
| | 5432 | 10.130.18.4/32 (api) |
| | 9100, 9187 | 10.130.18.6/32 (monitor) |
| **monitor-fw** (.6) | 22, 80, 443 | All IP |
| **storage-fw** (.7) | 22 | All IP |
| | 9000 | 10.130.18.4/32 (api), 10.130.18.3/32 (web) |
| | 9100 | 10.130.18.6/32 (monitor) |
| | 8080 | 10.130.18.3/32 (web → imgproxy) |

> GeoIP2 adds **no** new firewall rule — the DB-IP `.mmdb` is local to `web-01`; nginx reads it
> from disk and resolves countries in-process.

---

## 9. Security model

- **Single public door.** Only `web-01` (and `monitor-01` for the dashboards) accept public
  80/443. Backend, Postgres, Redis, MinIO, and imgproxy are private-VPC-only.
- **Storage is never directly public.** MinIO/imgproxy bind the private IP; the sole ingress is
  `cdn.wiriri.com` via nginx. Public images flow through imgproxy; ID/KYC + PDFs live in the
  private bucket and are backend-proxied or short-TTL presigned.
- **Presigned access.** Uploads/reads to MinIO are SigV4-signed; MinIO enforces the signature.
- **Consent at the edge.** GeoIP2 → `X-Geo-EEA` drives GDPR-correct analytics consent defaults.
- **Secrets.** Never in this repo — Infisical only (see §11).
- ⚠️ **Open item (security sprint):** every firewall currently allows **SSH `:22` from All IP**.
  Restrict to a bastion / known admin IPs (and/or move SSH off `:22`). Tracked with the deferred
  security hardening.

---

## 10. TLS & DNS

- One Let's Encrypt certificate on `web-01` covers `wiriri.com`, `www`, `api`, `admin`, `cdn`.
- Renewal via **certbot webroot** (ACME challenge on `:80`, served from `/var/www/certbot`).
- All `:80` traffic 301-redirects to `https://`; `www` 301-redirects to the apex.
- HSTS is emitted by the webapp/edge over TLS.

---

## 11. Secrets (Infisical)

Source of truth for all secrets — **3 stages: dev / staging / prod**. Nothing secret is committed
(`.gitignore` blocks `.env`, certs, MinIO data, cache, `*.mmdb`). Project IDs are recorded in
`../keys/infisical-projects-ids.md`.

| Project | What it holds (examples) |
|---------|--------------------------|
| backend | `DATABASE_URL`, `S3_*`, `IMGPROXY_KEY/SALT`, `KONNECT_*`, `MAILER_*` |
| webapp | `NEXT_PUBLIC_*` (incl. `NEXT_PUBLIC_GTM_ID=GTM-TFT37X7X`), backend domain |
| admin | admin runtime config |

On-box, `get-env.sh` materializes the stage's secrets into `./*/.env` (chmod 600) before
`docker compose up`.

---

## 12. Deploy & runbooks

- **Apps** (webapp/admin/backend) ship as `ghcr.io/khaledbk/wiriri-*:prod` images via the gated
  CI/CD pipeline; the box pulls and `docker compose up -d`.
- **Edge nginx** (custom geoip2 build) is built on the box — see
  [`web-01/nginx/README.md`](web-01/nginx/README.md): `docker compose build nginx && up -d nginx`,
  then `nginx -t`.
- **Read-only-first on prod:** inspect → `nginx -t` / dry-run → apply. Changes land via PR.
- Per-host build guides live in [`runbooks/`](runbooks/).

```bash
# typical edge update on web-01 (as tvacadmin)
cd /opt/wiriri
git pull
docker compose build nginx && docker compose up -d nginx
docker exec wiriri-prod-nginx nginx -t
```

---

## 13. Repository layout

```
wiriri-infra/
├── README.md             # this document
├── NETWORK.md            # VPC map + firewall matrix (detail)
├── web-01/               # edge: nginx (+geoip2) + webapp + admin   (.3, public)
│   ├── docker-compose.yml
│   └── nginx/  Dockerfile · nginx.conf · default.conf · refresh-geoip.sh · README.md
├── api-01/               # backend :4001 + Redis + exporters        (.4)
│   ├── docker-compose.yml
│   └── redis/redis.conf
├── db-01/                # PostgreSQL                                (.5)
├── monitor-01/           # Prometheus + Grafana                      (.6)
├── storage-01/           # MinIO + imgproxy                          (.7)
│   ├── docker-compose.yml
│   └── docker-compose.imgproxy.yml
├── cdn/                  # cdn vhost + imgproxy env reference
└── runbooks/             # per-VPS setup guides
```

**Conventions:** secrets in Infisical only · `*-proposed` files are reviewable planned changes
side-by-side with captured current state · read-only-first on prod.
