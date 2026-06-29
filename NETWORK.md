# Wiriri production network

All five VPSs share one private VPC **`10.130.18.0/24`** (CloudAxion) and talk directly over it.
Public DNS for `cdn / api / wiriri / admin .wiriri.com` all point at **web-01** — the only box
that exposes 80/443 to the internet.

## Hosts

| VPS | Public IP | Private IP | Role | Public ports |
|-----|-----------|-----------|------|--------------|
| wiriri-prod-web-01 | 102.207.250.149 | 10.130.18.3 | nginx edge (+geoip2) + webapp + admin | 80, 443 |
| wiriri-prod-api-01 | 102.207.250.152 | 10.130.18.4 | NestJS backend :4001 + Redis + redis_exporter | 22 only |
| wiriri-prod-db-01 | 102.207.250.154 | 10.130.18.5 | PostgreSQL :5432 + postgres_exporter | 22 only |
| wiriri-prod-monitor-01 | 102.207.250.159 | 10.130.18.6 | Prometheus + Grafana | 80, 443 |
| wiriri-prod-storage-01 | 102.207.250.162 | 10.130.18.7 | MinIO :9000/:9001 + imgproxy :8080 | 22 only |

## Service flows (private VPC unless noted)

| From | To | Port | Purpose | Firewall |
|------|----|------|---------|----------|
| Internet | web-01 | 443 | all sites + cdn | public |
| web-01 (.3) | api-01 (.4) | 4001 | api.wiriri.com → backend | VPC |
| web-01 (.3) | storage-01 (.7) | 9000 | presigned S3 passthrough | ✅ already open |
| web-01 (.3) | storage-01 (.7) | 8080 | cdn `/img/` → imgproxy | ✅ live |
| api-01 (.4) | storage-01 (.7) | 9000 | presign mint · ID/KYC proxy · put/del | ✅ already open |
| api-01 (.4) | db-01 (.5) | 5432 | Postgres | VPC |
| storage-01 | storage-01 | 9000 | imgproxy → MinIO (localhost) | n/a |
| monitor-01 (.6) | api-01 (.4) | 9100/9121 | scrape node + redis exporters | VPC |
| monitor-01 (.6) | db-01 (.5) | 9100/9187 | scrape node + postgres exporters | VPC |
| monitor-01 (.6) | web-01/storage-01 | 9100 | scrape node exporters | VPC |

> **GeoIP2 (web-01)** adds no flow/port: nginx reads the local DB-IP `.mmdb` and injects
> `X-Geo-EEA` into the `wiriri.com` upstream in-process. **SSH `:22` is open to All IP on every
> firewall** — restrict to a bastion/known IPs in the security sprint.

## CDN public surface
`cdn.wiriri.com` (→ web-01:443) is the **only** way in to storage; MinIO (`:9000/:9001`) and
imgproxy (`:8080`) are bound to the private IP and never internet-exposed.

- `GET /img/<sig>/...` → imgproxy (transform, cached at nginx)
- `PUT|GET /wiriri-prod-images|wiriri-prod-private/<key>?X-Amz-...` → MinIO (presigned; sig enforced)
- everything else → 404
