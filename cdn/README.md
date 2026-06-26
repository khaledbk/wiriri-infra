# cdn.wiriri.com — image CDN (MinIO + imgproxy, no Cloudflare)

Self-hosted media CDN: **nginx (web-01 edge) → imgproxy (storage-01) → MinIO (storage-01)**,
all over the private VPC. Replaces Cloudinary. Full design: `../../docs/spec/SPEC-2026-06-26-storage-minio-cdn.md`.

## Pieces in this folder
| File | What | Goes where |
|------|------|-----------|
| `nginx-cdn.conf` | the new `cdn.wiriri.com` server block (imgproxy + presigned passthrough) | replaces the cdn stub in `../web-01/nginx/default.conf` (full merged file: `../web-01/nginx/default.conf.cdn-proposed`) |
| `imgproxy.compose.yml` | imgproxy service fragment | add to storage-01 compose (merged: `../storage-01/docker-compose.cdn-proposed.yml`) |
| `.env.example` | imgproxy key/salt + read-only MinIO creds | on-box `.env` (values from Infisical) |

## What's already in place (audited 2026-06-26)
- MinIO live on storage-01 with buckets `wiriri-prod-images` / `wiriri-prod-private`, backend
  user `wiriri_backend_minio` + policy, `S3_*` env in Infisical.
- TLS cert already covers `cdn.wiriri.com` (certbot webroot, shared `wiriri.com` SAN cert).
- web-01 → MinIO `:9000` firewall already open.

## Remaining steps to go live
1. **imgproxy read-only MinIO user** — `mc admin user add` + policy `s3:GetObject,s3:ListBucket`
   on `wiriri-prod-images` only; put creds in `.env` (see `.env.example`).
2. **Deploy imgproxy** on storage-01 (`docker-compose.cdn-proposed.yml`); generate `IMGPROXY_KEY/SALT`.
3. **Firewall**: allow web-01 (`10.130.18.3`) → storage-01 `:8080`.
4. **nginx**: swap in `default.conf.cdn-proposed` (adds cache zone + new cdn block), mount
   `./nginx/cache:/var/cache/nginx`, `nginx -t` then reload.
5. **Smoke test**: `GET https://cdn.wiriri.com/img/<signed>/rs:fill:400/<src>` → 200 + `X-Cache-Status`;
   a backend presigned PUT/GET round-trips.

> All changes are **read-only-first**: validate `nginx -t` and a throwaway object before flipping app reads.
