# wiriri-infra

Infrastructure-as-config for the Wiriri production stack — one repo for the devops team holding
**every VPS's docker config**, the **CDN** design, and the **runbooks**. Captured from a read-only
audit of the live boxes on 2026-06-26 (see each file's header for "current" vs "proposed").

## Layout
```
wiriri-infra/
├── NETWORK.md            # VPC map, hosts, firewall matrix
├── web-01/               # nginx edge + webapp + admin   (10.130.18.3, public)
│   ├── docker-compose.yml
│   └── nginx/default.conf  (current)  +  default.conf.cdn-proposed  (with CDN)
├── api-01/               # NestJS backend :4001 + Redis  (10.130.18.4)
│   ├── docker-compose.yml
│   └── redis/redis.conf
├── db-01/                # PostgreSQL                    (10.130.18.5)
├── monitor-01/           # Prometheus + Grafana          (10.130.18.6)
├── storage-01/           # MinIO (+ imgproxy proposed)   (10.130.18.7)
│   ├── docker-compose.yml  (current)  +  docker-compose.cdn-proposed.yml
├── cdn/                  # the CDN change set: nginx vhost + imgproxy + env
└── runbooks/             # the infra-dev setup guides (per VPS)
```

## Conventions
- **Secrets never live here** — Infisical (3 stages: dev/staging/prod) is the source of truth.
  `.gitignore` blocks `.env`, certs, MinIO data, cache.
- **`*-proposed` files = planned change**, side-by-side with the captured current file, so a
  diff is reviewable before anything is applied.
- **Read-only-first on prod**: inspect → `nginx -t` / dry-run → apply. The owner opens PRs; CI/CD
  or a maintainer applies on the box.

## Current focus — CDN (cluster S)
Stand up `cdn.wiriri.com` (MinIO + imgproxy, no Cloudflare) to replace Cloudinary. Status &
steps: `cdn/README.md`. Architecture: `../docs/spec/SPEC-2026-06-26-storage-minio-cdn.md`.

## The stack at a glance
`Internet → web-01 nginx (:443, only public door) → {webapp, admin, api→api-01, cdn→imgproxy/MinIO on storage-01}`.
`api-01 backend → MinIO (private) for presign/proxy`, `→ db-01 Postgres`. Full map: `NETWORK.md`.
